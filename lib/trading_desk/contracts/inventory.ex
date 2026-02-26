defmodule TradingDesk.Contracts.Inventory do
  @moduledoc """
  Contract inventory management — ingestion, versioning, and status tracking.

  Ingests contracts from directories or network locations, computes document
  hashes for integrity verification, tracks currency (is the contract still
  valid?), and provides a unified view of the entire contract portfolio.

  Key capabilities:
    - Ingest single files or entire directories
    - Auto-detect contract family and extract contract number
    - Compute and store SHA-256 hash of every document
    - Track network path for later hash verification
    - Report contract currency (active, expired, superseded)
    - Report verification status (hash match vs mismatch)
    - Version chain tracking with previous_hash audit trail

  This module coordinates between DocumentReader (read), LLM extraction,
  HashVerifier (hash), Store (persist), and CurrencyTracker (freshness).
  """

  alias TradingDesk.Contracts.{
    Contract,
    DocumentReader,
    Store,
    HashVerifier,
    CurrencyTracker,
    TemplateRegistry,
    TemplateValidator
  }
  alias TradingDesk.LLM.{Pool, ModelRegistry}

  require Logger

  @pubsub TradingDesk.PubSub
  @topic "contracts"

  # Supported file extensions for ingestion
  @supported_extensions ~w(.pdf .docx .docm .txt)

  # ──────────────────────────────────────────────────────────
  # SINGLE FILE INGESTION
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest a single contract file with full hash tracking.

  Options:
    - :counterparty — counterparty name (required)
    - :counterparty_type — :customer | :supplier (required)
    - :product_group — :ammonia | :uan | :urea (required)
    - :network_path — original network location for verification
    - :company — :trammo_inc | :trammo_sas | :trammo_dmcc
    - :contract_date — effective date
    - :expiry_date — expiration date
    - :sap_contract_id — SAP reference

  Returns {:ok, contract} with hash computed and stored.
  """
  @spec ingest_file(String.t(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def ingest_file(file_path, opts) do
    counterparty = Keyword.fetch!(opts, :counterparty)
    counterparty_type = Keyword.fetch!(opts, :counterparty_type)
    product_group = Keyword.fetch!(opts, :product_group)

    with {:hash, {:ok, file_hash, file_size}} <- {:hash, HashVerifier.compute_file_hash(file_path)},
         {:read, {:ok, text}} <- {:read, DocumentReader.read(file_path)},
         {:llm, {:ok, clauses}} <- {:llm, extract_clauses_via_llm(text)} do

      # Auto-detect family metadata
      {family_id, family_direction, family_incoterm, family_term_type} =
        case TemplateRegistry.detect_family(text) do
          {:ok, fid, family} ->
            {fid, family.direction, List.first(family.default_incoterms), family.term_type}
          _ ->
            {nil, nil, nil, nil}
        end

      # Extract contract number from text
      contract_number = extract_contract_number(text)

      # Look up previous version to chain hashes
      previous_hash = get_previous_version_hash(counterparty, product_group)

      contract = %Contract{
        counterparty: counterparty,
        counterparty_type: counterparty_type,
        product_group: product_group,
        template_type: Keyword.get(opts, :template_type) || family_direction,
        incoterm: Keyword.get(opts, :incoterm) || family_incoterm,
        term_type: Keyword.get(opts, :term_type) || family_term_type,
        company: Keyword.get(opts, :company),
        source_file: Path.basename(file_path),
        source_format: DocumentReader.detect_format(file_path),
        clauses: clauses,
        contract_date: Keyword.get(opts, :contract_date),
        expiry_date: Keyword.get(opts, :expiry_date),
        sap_contract_id: Keyword.get(opts, :sap_contract_id),
        # New hash/inventory fields
        contract_number: contract_number,
        family_id: family_id,
        file_hash: file_hash,
        file_size: file_size,
        network_path: Keyword.get(opts, :network_path) || file_path,
        verification_status: :pending,
        previous_hash: previous_hash
      }

      case Store.ingest(contract) do
        {:ok, stored} ->
          CurrencyTracker.stamp(stored.id, :parsed_at)

          broadcast(:contract_ingested, %{
            contract_id: stored.id,
            contract_number: contract_number,
            counterparty: counterparty,
            family_id: family_id,
            file_hash: String.slice(file_hash, 0, 12) <> "...",
            clause_count: length(clauses)
          })

          Logger.info(
            "Contract ingested: #{counterparty} #{contract_number || "?"} " <>
            "(#{length(clauses)} clauses, hash=#{String.slice(file_hash, 0, 12)}...)"
          )

          # Fetch SAP open position then generate scheduled deliveries (async)
          Task.Supervisor.start_child(
            TradingDesk.Contracts.TaskSupervisor,
            fn ->
              # Try to get open position from SAP before generating schedule
              with_position = fetch_sap_position_for(stored)
              TradingDesk.Schedule.DeliveryScheduler.generate_from_contract(with_position)
            end
          )

          {:ok, stored}

        {:error, reason} ->
          {:error, {:store_failed, reason}}
      end
    else
      {:hash, {:error, reason}} -> {:error, {:hash_failed, reason}}
      {:read, {:error, reason}} -> {:error, {:read_failed, reason}}
      {:llm, {:error, reason}} -> {:error, {:llm_extraction_failed, reason}}
    end
  end

  # ── LLM clause extraction ────────────────────────────────

  defp extract_clauses_via_llm(text) do
    model = ModelRegistry.default()

    if is_nil(model) do
      {:error, :no_model_registered}
    else
      prompt = build_extraction_prompt(text)

      case Pool.generate(model.id, prompt, max_tokens: 1024) do
        {:ok, raw_text} -> parse_llm_clauses(raw_text)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp build_extraction_prompt(contract_text) do
    inventory =
      TemplateRegistry.canonical_clauses()
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map_join(", ", fn {id, _} -> id end)

    max_chars = 3000
    truncated = if String.length(contract_text) > max_chars do
      String.slice(contract_text, 0, max_chars) <> "\n[...truncated...]"
    else
      contract_text
    end

    """
    Extract structured clause data from this commodity trading contract.
    Return ONLY valid JSON with this exact structure:

    {"clauses":[{"clause_id":"PRICE","category":"commercial","source_text":"exact quote","value":340.0,"unit":"$/ton","operator":"==","confidence":"high"}]}

    Known clause IDs: #{inventory}

    For penalty clauses, include "penalty_rate" with the $/ton or $/day rate.
    For price clauses, "value" is the price in $/ton.
    For quantity clauses, "value" is the quantity in metric tons.

    CONTRACT TEXT:
    #{truncated}
    """
  end

  defp parse_llm_clauses(raw_text) do
    alias TradingDesk.Contracts.Clause
    json_str = extract_json(raw_text)
    now = DateTime.utc_now()

    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses}} when is_list(clauses) ->
        built = Enum.map(clauses, fn c ->
          base_fields = %{}
          merged_fields =
            base_fields
            |> maybe_put("parameter", c["parameter"])
            |> maybe_put("operator", c["operator"])
            |> maybe_put("value", c["value"])
            |> maybe_put("value_upper", c["value_upper"])
            |> maybe_put("unit", c["unit"])
            |> maybe_put("penalty_per_unit", c["penalty_rate"] || c["demurrage_rate"])
            |> maybe_put("period", c["period"])
            |> maybe_put("anchors_matched", c["anchors_matched"] || [])

          %Clause{
            id: Clause.generate_id(),
            clause_id: c["clause_id"],
            type: map_clause_type(c["category"]),
            category: safe_atom(c["category"]),
            description: c["source_text"] || "",
            reference_section: c["section_ref"],
            confidence: safe_atom(c["confidence"] || "high"),
            extracted_fields: merged_fields,
            extracted_at: now
          }
        end)

        {:ok, built}

      {:ok, _} -> {:error, :no_clauses_in_response}
      {:error, reason} -> {:error, {:json_parse_failed, reason}}
    end
  end

  defp extract_json(text) do
    cond do
      String.contains?(text, "```json") ->
        text |> String.split("```json") |> Enum.at(1, "") |> String.split("```") |> List.first("") |> String.trim()
      String.contains?(text, "```") ->
        text |> String.split("```") |> Enum.at(1, "") |> String.trim()
      true ->
        String.trim(text)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put_new(map, key, value)

  defp map_clause_type(cat) when is_binary(cat) do
    case String.downcase(cat) do
      "commercial" -> :price_term
      "core_terms" -> :obligation
      "logistics" -> :delivery
      "logistics_cost" -> :penalty
      "credit_legal" -> :penalty
      "compliance" -> :compliance
      "legal" -> :legal
      "operational" -> :operational
      "metadata" -> :metadata
      _ -> :condition
    end
  end
  defp map_clause_type(_), do: :condition

  defp safe_atom(nil), do: nil
  defp safe_atom(a) when is_atom(a), do: a
  defp safe_atom(s) when is_binary(s), do: String.to_atom(String.downcase(s))

  # ──────────────────────────────────────────────────────────
  # DIRECTORY INGESTION
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest all supported contract files from a directory.

  Each file needs a manifest entry mapping the filename to counterparty info.
  If no manifest is provided, files are ingested with counterparty derived
  from filename conventions or set to "Unknown".

  manifest format:
    %{
      "TRAMMO-SP-2026-0001.docx" => %{
        counterparty: "Yara International",
        counterparty_type: :supplier,
        product_group: :ammonia
      },
      ...
    }

  Returns a summary of ingestion results.
  """
  @spec ingest_directory(String.t(), map(), keyword()) :: {:ok, map()}
  def ingest_directory(dir_path, manifest \\ %{}, opts \\ []) do
    unless File.dir?(dir_path) do
      {:error, :directory_not_found}
    else
      files =
        File.ls!(dir_path)
        |> Enum.filter(fn f -> Path.extname(f) in @supported_extensions end)
        |> Enum.sort()

      broadcast(:directory_ingestion_started, %{
        directory: dir_path,
        file_count: length(files)
      })

      default_product_group = Keyword.get(opts, :product_group, :ammonia)
      default_type = Keyword.get(opts, :counterparty_type, :customer)

      results =
        files
        |> Enum.map(fn filename ->
          file_path = Path.join(dir_path, filename)
          file_opts = build_file_opts(filename, file_path, manifest, default_product_group, default_type)

          result = ingest_file(file_path, file_opts)
          {filename, result}
        end)

      succeeded = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
      failed = Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)

      failures =
        results
        |> Enum.filter(fn {_, r} -> not match?({:ok, _}, r) end)
        |> Enum.map(fn {f, {:error, reason}} -> {f, reason} end)

      broadcast(:directory_ingestion_complete, %{
        directory: dir_path,
        total: length(files),
        succeeded: succeeded,
        failed: failed
      })

      {:ok, %{
        directory: dir_path,
        total: length(files),
        succeeded: succeeded,
        failed: failed,
        failures: failures,
        ingested_at: DateTime.utc_now()
      }}
    end
  end

  # ──────────────────────────────────────────────────────────
  # INVENTORY LISTING
  # ──────────────────────────────────────────────────────────

  @doc """
  List all contracts with their current status, currency, and verification state.
  This is the main inventory view for the UI.
  """
  @spec list_inventory(atom()) :: [map()]
  def list_inventory(product_group) do
    Store.list_by_product_group(product_group)
    |> Enum.map(fn contract ->
      currency = CurrencyTracker.currency_report(contract.id)
      stale_events = CurrencyTracker.stale_events(contract.id)

      %{
        contract_id: contract.id,
        contract_number: contract.contract_number,
        counterparty: contract.counterparty,
        counterparty_type: contract.counterparty_type,
        company: contract.company,
        family_id: contract.family_id,
        template_type: contract.template_type,
        incoterm: contract.incoterm,
        term_type: contract.term_type,
        version: contract.version,
        status: contract.status,
        # Currency
        is_current: CurrencyTracker.current?(contract.id),
        stale_events: stale_events,
        currency_detail: currency,
        # Validity
        expired: Contract.expired?(contract),
        contract_date: contract.contract_date,
        expiry_date: contract.expiry_date,
        # Document integrity
        file_hash: contract.file_hash,
        file_size: contract.file_size,
        network_path: contract.network_path,
        verification_status: contract.verification_status || :pending,
        last_verified_at: contract.last_verified_at,
        # Extraction
        clause_count: length(contract.clauses || []),
        source_file: contract.source_file,
        source_format: contract.source_format,
        scan_date: contract.scan_date,
        # Timestamps
        created_at: contract.created_at,
        updated_at: contract.updated_at
      }
    end)
    |> Enum.sort_by(& &1.counterparty)
  end

  @doc """
  Get a summary of the entire inventory across all product groups.
  """
  @spec inventory_summary() :: map()
  def inventory_summary do
    product_groups = [:ammonia, :uan, :urea]

    summaries =
      Enum.map(product_groups, fn pg ->
        contracts = Store.list_by_product_group(pg)

        summary = %{
          total: length(contracts),
          by_status: Enum.frequencies_by(contracts, & &1.status),
          active: Enum.count(contracts, &(&1.status == :approved)),
          expired: Enum.count(contracts, &Contract.expired?/1),
          verified: Enum.count(contracts, &(&1.verification_status == :verified)),
          mismatches: Enum.count(contracts, &(&1.verification_status == :mismatch)),
          pending_verification: Enum.count(contracts, fn c ->
            c.verification_status in [:pending, nil]
          end),
          families: contracts |> Enum.map(& &1.family_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
          counterparties: contracts |> Enum.map(& &1.counterparty) |> Enum.uniq() |> length()
        }

        {pg, summary}
      end)

    %{
      by_product_group: Map.new(summaries),
      generated_at: DateTime.utc_now()
    }
  end

  # ──────────────────────────────────────────────────────────
  # CURRENCY AND VALIDITY REPORT
  # ──────────────────────────────────────────────────────────

  @doc """
  Generate a full currency report for a product group showing which
  contracts are current, stale, expired, or have hash mismatches.
  """
  @spec currency_report(atom()) :: map()
  def currency_report(product_group) do
    contracts = Store.list_by_product_group(product_group)

    items =
      Enum.map(contracts, fn c ->
        %{
          contract_id: c.id,
          contract_number: c.contract_number,
          counterparty: c.counterparty,
          version: c.version,
          status: c.status,
          expired: Contract.expired?(c),
          is_current: CurrencyTracker.current?(c.id),
          stale_events: CurrencyTracker.stale_events(c.id),
          verification_status: c.verification_status || :pending,
          last_verified_at: c.last_verified_at,
          needs_attention: needs_attention?(c)
        }
      end)

    attention_needed = Enum.filter(items, & &1.needs_attention)

    %{
      product_group: product_group,
      total_contracts: length(items),
      contracts: items,
      attention_needed: length(attention_needed),
      attention_items: attention_needed,
      all_current: Enum.all?(items, & &1.is_current),
      generated_at: DateTime.utc_now()
    }
  end

  # ──────────────────────────────────────────────────────────
  # RE-INGESTION (new version from same or updated file)
  # ──────────────────────────────────────────────────────────

  @doc """
  Re-ingest a contract from its network_path. Creates a new version
  with updated hash. Used when a contract file has been modified
  (detected via hash mismatch) and the change is legitimate.
  """
  @spec reingest(String.t()) :: {:ok, Contract.t()} | {:error, term()}
  def reingest(contract_id) do
    with {:ok, contract} <- Store.get(contract_id),
         {:ok, path} <- resolve_path(contract) do
      ingest_file(path, [
        counterparty: contract.counterparty,
        counterparty_type: contract.counterparty_type,
        product_group: contract.product_group,
        template_type: contract.template_type,
        incoterm: contract.incoterm,
        term_type: contract.term_type,
        company: contract.company,
        contract_date: contract.contract_date,
        expiry_date: contract.expiry_date,
        sap_contract_id: contract.sap_contract_id,
        network_path: contract.network_path
      ])
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE HELPERS
  # ──────────────────────────────────────────────────────────

  # Extract contract number from text (e.g., "TRAMMO-LTP-2026-0001")
  defp extract_contract_number(text) do
    patterns = [
      ~r/Contract\s+No\.?\s*:?\s*([A-Z]+-[A-Z0-9]+-\d{4}-\d+)/i,
      ~r/Contract\s+(?:Number|Ref)\.?\s*:?\s*([A-Z0-9][A-Z0-9-]+)/i
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, text) do
        [_, number] -> String.trim(number)
        _ -> nil
      end
    end)
  end

  # Get the hash of the most recent version for this counterparty/product_group
  defp get_previous_version_hash(counterparty, product_group) do
    case Store.list_versions(counterparty, product_group) do
      [latest | _] -> latest.file_hash
      [] -> nil
    end
  end

  # Build opts for a file from manifest or filename conventions
  defp build_file_opts(filename, file_path, manifest, default_pg, default_type) do
    case Map.get(manifest, filename) do
      %{} = entry ->
        [
          counterparty: entry[:counterparty] || derive_counterparty(filename),
          counterparty_type: entry[:counterparty_type] || default_type,
          product_group: entry[:product_group] || default_pg,
          network_path: file_path,
          company: entry[:company],
          contract_date: entry[:contract_date],
          expiry_date: entry[:expiry_date],
          sap_contract_id: entry[:sap_contract_id]
        ]

      nil ->
        [
          counterparty: derive_counterparty(filename),
          counterparty_type: default_type,
          product_group: default_pg,
          network_path: file_path
        ]
    end
  end

  @doc """
  Derive counterparty name from filename convention.
  e.g., "Koch_Fertilizer_purchase_2026.docx" → "Koch Fertilizer"
  """
  def derive_counterparty_from_filename(filename), do: derive_counterparty(filename)

  defp derive_counterparty(filename) do
    filename
    |> Path.rootname()
    |> String.replace(~r/[_-]/, " ")
    |> String.replace(~r/\b(purchase|sale|spot|fob|cfr|cif|dap|cpt|\d{4})\b/i, "")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
    |> case do
      "" -> "Unknown"
      name -> name
    end
  end

  defp needs_attention?(contract) do
    Contract.expired?(contract) or
    contract.verification_status == :mismatch or
    contract.verification_status == :file_not_found or
    (contract.status == :approved and not CurrencyTracker.current?(contract.id))
  end

  defp resolve_path(%Contract{network_path: nil}), do: {:error, :no_network_path}
  defp resolve_path(%Contract{network_path: ""}), do: {:error, :no_network_path}
  defp resolve_path(%Contract{network_path: path}) do
    if File.exists?(path), do: {:ok, path}, else: {:error, :file_not_found}
  end

  # Try to fetch the SAP open position for this contract and update the Store.
  # If SAP is unavailable, returns the contract as-is (open_position may be nil).
  defp fetch_sap_position_for(contract) do
    case TradingDesk.Contracts.SapPositions.fetch_position(contract.counterparty) do
      {:ok, pos} when is_map(pos) ->
        open_qty = pos.open_qty_mt || pos[:open_quantity] || 0.0
        Store.update_open_position(contract.counterparty, contract.product_group, open_qty)
        %{contract | open_position: open_qty}

      _ ->
        Logger.debug("Inventory: SAP position unavailable for #{contract.counterparty}, using existing open_position")
        contract
    end
  rescue
    _ -> contract
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
