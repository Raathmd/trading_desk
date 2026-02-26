defmodule TradingDesk.Contracts.FolderScanner do
  @moduledoc """
  Monitors a local server folder for contract files and syncs with the database.

  ## The Flow

  1. Scan configured folder for supported files (.pdf, .docx, .docm, .txt)
  2. Compute SHA-256 hash for each file on disk
  3. Compare against contracts in the database:
     - **New file** (hash not in DB)        → extract clauses via local LLM
     - **Changed file** (same name, new hash) → re-extract clauses, delete old schedules
     - **Missing file** (in DB, not on disk)  → soft-delete (set deleted_at)
  4. Store contract with clauses directly into Store (contracts table)
  5. Generate scheduled deliveries for each ingested contract
  6. SAP-closed contracts are also soft-deleted

  ## Clause extraction

  Contract text is read via DocumentReader, then sent to the **local LLM**
  (Mistral 7B via Bumblebee/Nx.Serving) for structured clause extraction.
  The LLM returns JSON with clause data that maps directly to Clause structs
  used by the solver's ConstraintBridge. Falls back to the deterministic
  Parser if the local LLM is unavailable.

  ## Contract key

  The `file_hash` (SHA-256) acts as the version key linking contracts to their
  scheduled deliveries. When a file is reimported with a new hash, new schedule
  records are created and old ones physically deleted.

  ## Configuration

  Set `CONTRACT_WATCH_DIR` env var to the folder path. Defaults to
  `priv/contracts` in dev.
  """

  alias TradingDesk.Contracts.{
    Clause,
    Contract,
    DocumentReader,
    HashVerifier,
    Parser,
    SapPositions,
    Store,
    TemplateRegistry
  }

  alias TradingDesk.DB.ScheduledDelivery
  alias TradingDesk.LLM.{Pool, ModelRegistry}
  alias TradingDesk.Schedule.DeliveryScheduler
  alias TradingDesk.Repo

  import Ecto.Query

  require Logger

  @supported_extensions ~w(.pdf .docx .docm .txt)
  @pubsub TradingDesk.PubSub
  @topic "contracts"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Run a full folder scan for the given product group.

  Scans the configured watch directory, compares file hashes against
  the database, ingests new/changed files, and soft-deletes missing ones.

  Returns {:ok, summary} with counts of new, changed, removed, unchanged.
  """
  @spec scan(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def scan(product_group \\ :ammonia, opts \\ []) do
    dir = Keyword.get(opts, :directory) || watch_dir()

    unless File.dir?(dir) do
      {:error, {:directory_not_found, dir}}
    else
      Logger.info("FolderScanner: scanning #{dir} for #{product_group}")
      broadcast(:folder_scan_started, %{directory: dir, product_group: product_group})

      disk_files = list_files(dir)
      db_contracts = active_contracts(product_group)

      {new_files, changed_files, unchanged_files, missing_contracts} =
        classify(disk_files, db_contracts)

      # Ingest new files
      new_results = Enum.map(new_files, fn {path, _hash} ->
        ingest_new(path, product_group)
      end)

      # Re-ingest changed files (delete old schedules, re-extract clauses)
      changed_results = Enum.map(changed_files, fn {path, _new_hash, contract} ->
        reingest_changed(path, contract, product_group)
      end)

      # Soft-delete contracts whose files are missing from disk
      removed_count = soft_delete_missing(missing_contracts, :file_removed)

      summary = %{
        directory: dir,
        product_group: product_group,
        new_ingested: Enum.count(new_results, &match?({:ok, _}, &1)),
        new_failed: Enum.count(new_results, &match?({:error, _}, &1)),
        re_ingested: Enum.count(changed_results, &match?({:ok, _}, &1)),
        re_ingest_failed: Enum.count(changed_results, &match?({:error, _}, &1)),
        removed: removed_count,
        unchanged: length(unchanged_files),
        scanned_at: DateTime.utc_now()
      }

      broadcast(:folder_scan_complete, summary)
      Logger.info(
        "FolderScanner: #{summary.new_ingested} new, #{summary.re_ingested} updated, " <>
        "#{summary.removed} removed, #{summary.unchanged} unchanged"
      )

      {:ok, summary}
    end
  end

  @doc """
  Reimport all files from the watch folder.

  Clears ALL scheduled deliveries for the product group, then re-scans
  and re-ingests every file as if starting fresh.
  """
  @spec reimport_all(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def reimport_all(product_group \\ :ammonia, opts \\ []) do
    Logger.info("FolderScanner: REIMPORT ALL for #{product_group}")
    broadcast(:reimport_started, %{product_group: product_group})

    deleted_count = clear_schedules(product_group)
    Logger.info("FolderScanner: cleared #{deleted_count} scheduled deliveries")

    result = scan(product_group, opts)

    case result do
      {:ok, summary} ->
        summary = Map.put(summary, :schedules_cleared, deleted_count)
        broadcast(:reimport_complete, summary)
        {:ok, summary}

      error ->
        error
    end
  end

  @doc "Run scan in background."
  def scan_async(product_group \\ :ammonia, opts \\ []) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> scan(product_group, opts) end
    )
  end

  @doc "Run reimport in background."
  def reimport_all_async(product_group \\ :ammonia, opts \\ []) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> reimport_all(product_group, opts) end
    )
  end

  @doc """
  Soft-delete contracts that SAP reports as closed.

  Takes a list of SAP contract IDs that are closed and marks the
  corresponding contracts as logically deleted.
  """
  @spec mark_sap_closed([String.t()]) :: non_neg_integer()
  def mark_sap_closed(closed_sap_ids) when is_list(closed_sap_ids) do
    contracts =
      Store.list_all()
      |> Enum.filter(fn c ->
        c.sap_contract_id in closed_sap_ids and is_nil(Map.get(c, :deleted_at))
      end)

    soft_delete_missing(contracts, :sap_closed)
  end

  @doc "Get the configured watch directory."
  @spec watch_dir() :: String.t()
  def watch_dir do
    System.get_env("CONTRACT_WATCH_DIR") ||
      Path.join(:code.priv_dir(:trading_desk) |> to_string(), "contracts")
  end

  @doc """
  Derive counterparty name from filename convention.
  e.g., "Koch_Fertilizer_purchase_2026.docx" -> "Koch Fertilizer"
  """
  def derive_counterparty(filename) do
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

  # ──────────────────────────────────────────────────────────
  # SCHEDULE MANAGEMENT
  # ──────────────────────────────────────────────────────────

  @doc """
  Delete all scheduled deliveries for a product group.
  Returns the number of deleted records.
  """
  @spec clear_schedules(atom()) :: non_neg_integer()
  def clear_schedules(product_group) do
    pg = to_string(product_group)

    {count, _} =
      from(sd in ScheduledDelivery, where: sd.product_group == ^pg)
      |> Repo.delete_all()

    count
  end

  @doc """
  Delete scheduled deliveries linked to a specific contract hash.
  Used when a contract file is reimported with a new hash.
  """
  @spec clear_schedules_for_hash(String.t()) :: non_neg_integer()
  def clear_schedules_for_hash(contract_hash) do
    {count, _} =
      from(sd in ScheduledDelivery, where: sd.contract_hash == ^contract_hash)
      |> Repo.delete_all()

    count
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: FILE LISTING
  # ──────────────────────────────────────────────────────────

  defp list_files(dir) do
    File.ls!(dir)
    |> Enum.filter(fn f ->
      path = Path.join(dir, f)
      not File.dir?(path) and (Path.extname(f) |> String.downcase()) in @supported_extensions
    end)
    |> Enum.sort()
    |> Enum.map(fn filename ->
      path = Path.join(dir, filename)

      case HashVerifier.compute_file_hash(path) do
        {:ok, hash, _size} -> {path, hash}
        {:error, reason} ->
          Logger.warning("FolderScanner: cannot hash #{filename}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: CLASSIFICATION
  # ──────────────────────────────────────────────────────────

  defp classify(disk_files, db_contracts) do
    by_hash = Map.new(db_contracts, fn c -> {c.file_hash, c} end)
    by_source = Map.new(db_contracts, fn c -> {c.source_file, c} end)
    matched_ids = MapSet.new()

    {new, changed, unchanged, matched_ids} =
      Enum.reduce(disk_files, {[], [], [], matched_ids}, fn {path, disk_hash}, {n, ch, unch, matched} ->
        filename = Path.basename(path)

        cond do
          Map.has_key?(by_hash, disk_hash) ->
            contract = by_hash[disk_hash]
            {n, ch, [{path, disk_hash, contract} | unch], MapSet.put(matched, contract.id)}

          Map.has_key?(by_source, filename) ->
            contract = by_source[filename]
            {n, [{path, disk_hash, contract} | ch], unch, MapSet.put(matched, contract.id)}

          true ->
            {[{path, disk_hash} | n], ch, unch, matched}
        end
      end)

    missing =
      db_contracts
      |> Enum.reject(fn c -> MapSet.member?(matched_ids, c.id) end)

    {Enum.reverse(new), Enum.reverse(changed), Enum.reverse(unchanged), missing}
  end

  defp active_contracts(product_group) do
    Store.list_by_product_group(product_group)
    |> Enum.reject(fn c -> Map.get(c, :deleted_at) != nil end)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: INGESTION
  #
  # Both new and changed files go through extract_and_store/3
  # which reads the file, extracts clauses via local LLM,
  # builds a %Contract{}, and stores it directly in the
  # contracts table.
  # ──────────────────────────────────────────────────────────

  defp ingest_new(path, product_group) do
    filename = Path.basename(path)
    Logger.info("FolderScanner: ingesting new file #{filename}")

    result = extract_and_store(path, product_group, %{
      counterparty: derive_counterparty(filename),
      counterparty_type: :customer
    })

    case result do
      {:ok, contract} ->
        broadcast(:clauses_changed, %{
          contract_id: contract.id,
          counterparty: contract.counterparty,
          product_group: product_group,
          reason: :new_file,
          clause_count: length(contract.clauses || [])
        })
        {:ok, contract}

      error ->
        error
    end
  end

  defp reingest_changed(path, old_contract, product_group) do
    filename = Path.basename(path)
    Logger.info("FolderScanner: re-ingesting changed file #{filename} (was v#{old_contract.version})")

    # Delete old scheduled deliveries for the previous hash
    if old_contract.file_hash do
      cleared = clear_schedules_for_hash(old_contract.file_hash)
      Logger.info("FolderScanner: cleared #{cleared} old schedule records for hash #{String.slice(old_contract.file_hash, 0, 12)}...")
    end

    result = extract_and_store(path, product_group, %{
      counterparty: old_contract.counterparty,
      counterparty_type: old_contract.counterparty_type,
      template_type: old_contract.template_type,
      incoterm: old_contract.incoterm,
      term_type: old_contract.term_type,
      company: old_contract.company,
      contract_date: old_contract.contract_date,
      expiry_date: old_contract.expiry_date,
      sap_contract_id: old_contract.sap_contract_id
    })

    case result do
      {:ok, contract} ->
        broadcast(:clauses_changed, %{
          contract_id: contract.id,
          counterparty: contract.counterparty,
          product_group: product_group,
          reason: :file_changed,
          previous_version: old_contract.version,
          clause_count: length(contract.clauses || [])
        })
        {:ok, contract}

      error ->
        error
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: LOCAL LLM EXTRACTION → CONTRACT → STORE
  #
  # 1. Read file text via DocumentReader
  # 2. Send to local LLM (Mistral 7B) for clause extraction
  # 3. Parse JSON response into %Clause{} structs
  # 4. Build %Contract{} with clauses attached
  # 5. Store.ingest → contracts table (ETS + Postgres async)
  # 6. Generate scheduled deliveries async
  #
  # Falls back to deterministic Parser if LLM unavailable.
  # ──────────────────────────────────────────────────────────

  defp extract_and_store(path, product_group, meta) do
    filename = Path.basename(path)

    with {:hash, {:ok, file_hash, file_size}} <- {:hash, HashVerifier.compute_file_hash(path)},
         {:read, {:ok, text}} <- {:read, DocumentReader.read(path)} do

      # Try local LLM extraction, fall back to deterministic parser
      clauses = case extract_clauses_via_llm(text, product_group) do
        {:ok, llm_clauses} ->
          Logger.info("FolderScanner: local LLM extracted #{length(llm_clauses)} clauses from #{filename}")
          llm_clauses

        {:error, reason} ->
          Logger.info("FolderScanner: LLM unavailable (#{inspect(reason)}), using deterministic parser for #{filename}")
          {parser_clauses, _warnings, _family} = Parser.parse(text)
          parser_clauses
      end

      # Detect contract family from text
      {family_id, family_direction, family_incoterm, family_term_type} =
        case TemplateRegistry.detect_family(text) do
          {:ok, fid, family} ->
            {fid, family.direction, List.first(family.default_incoterms), family.term_type}
          _ ->
            {nil, nil, nil, nil}
        end

      contract_number = extract_contract_number(text)
      counterparty = meta[:counterparty]
      previous_hash = get_previous_hash(counterparty, product_group)

      contract = %Contract{
        counterparty: counterparty,
        counterparty_type: meta[:counterparty_type] || :customer,
        product_group: product_group,
        template_type: meta[:template_type] || family_direction,
        incoterm: meta[:incoterm] || family_incoterm,
        term_type: meta[:term_type] || family_term_type,
        company: meta[:company],
        source_file: filename,
        source_format: detect_format(path),
        clauses: clauses,
        contract_date: meta[:contract_date],
        expiry_date: meta[:expiry_date],
        sap_contract_id: meta[:sap_contract_id],
        contract_number: contract_number,
        family_id: family_id,
        file_hash: file_hash,
        file_size: file_size,
        network_path: path,
        verification_status: :pending,
        previous_hash: previous_hash
      }

      case Store.ingest(contract) do
        {:ok, stored} ->
          Logger.info(
            "FolderScanner: stored #{counterparty} #{contract_number || "?"} " <>
            "(#{length(clauses)} clauses, hash=#{String.slice(file_hash, 0, 12)}...)"
          )
          schedule_deliveries_async(stored)
          {:ok, stored}

        {:error, reason} ->
          {:error, {:store_failed, reason}}
      end
    else
      {:hash, {:error, reason}} -> {:error, {:hash_failed, reason}}
      {:read, {:error, reason}} -> {:error, {:read_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: LOCAL LLM CLAUSE EXTRACTION
  #
  # Sends contract text to the local Mistral 7B model via
  # LLM.Pool with a structured extraction prompt. Parses
  # the JSON response into %Clause{} structs.
  # ──────────────────────────────────────────────────────────

  defp extract_clauses_via_llm(text, _product_group) do
    model = ModelRegistry.default()

    if is_nil(model) do
      {:error, :no_model_registered}
    else
      prompt = build_extraction_prompt(text)

      case Pool.generate(model.id, prompt, max_tokens: 1024) do
        {:ok, raw_text} ->
          parse_llm_clauses(raw_text)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_extraction_prompt(contract_text) do
    inventory = clause_inventory_text()

    # Truncate to fit within Mistral's context window
    max_chars = 3000
    truncated = if String.length(contract_text) > max_chars do
      String.slice(contract_text, 0, max_chars) <> "\n[...truncated...]"
    else
      contract_text
    end

    """
    Extract structured clause data from this commodity trading contract.
    Return ONLY valid JSON with this exact structure:

    {"clauses":[{"clause_id":"PRICE","category":"commercial","source_text":"exact quote","value":340.0,"unit":"$/ton","operator":"==","confidence":"high"},{"clause_id":"QUANTITY_TOLERANCE","category":"core_terms","source_text":"exact quote","value":25000,"unit":"tons","operator":">=","confidence":"high"}]}

    Known clause IDs: #{inventory}

    For penalty clauses (PENALTY_VOLUME_SHORTFALL, PENALTY_LATE_DELIVERY, LAYTIME_DEMURRAGE), include "penalty_rate" with the $/ton or $/day rate.
    For price clauses, "value" is the price in $/ton.
    For quantity clauses, "value" is the quantity in metric tons.
    For delivery date clauses, use "source_text" for the window description.
    For tolerance clauses, "value" and "value_upper" for the range.

    CONTRACT TEXT:
    #{truncated}
    """
  end

  defp clause_inventory_text do
    TemplateRegistry.canonical_clauses()
    |> Enum.sort_by(fn {id, _} -> id end)
    |> Enum.map_join(", ", fn {id, _} -> id end)
  end

  # Parse LLM JSON response into %Clause{} structs
  defp parse_llm_clauses(raw_text) do
    json_str = extract_json(raw_text)
    now = DateTime.utc_now()

    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses}} when is_list(clauses) ->
        built = Enum.map(clauses, fn c ->
          clause_id = get_str(c, "clause_id")

          %Clause{
            id: Clause.generate_id(),
            clause_id: clause_id,
            type: map_clause_type(get_str(c, "category")),
            category: safe_atom(get_str(c, "category")),
            description: get_str(c, "source_text") || "",
            reference_section: get_str(c, "section_ref"),
            confidence: safe_atom(get_str(c, "confidence") || "high"),
            anchors_matched: [],
            extracted_fields: %{},
            extracted_at: now,
            parameter: lp_parameter_for(clause_id),
            operator: parse_operator(get_str(c, "operator")),
            value: get_num(c, "value"),
            value_upper: get_num(c, "value_upper"),
            unit: get_str(c, "unit"),
            penalty_per_unit: get_num(c, "penalty_rate") || get_num(c, "demurrage_rate"),
            period: safe_atom(get_str(c, "period"))
          }
        end)

        {:ok, built}

      {:ok, _} ->
        {:error, :no_clauses_in_response}

      {:error, reason} ->
        {:error, {:json_parse_failed, reason}}
    end
  end

  # Extract the first JSON object from LLM output (handles markdown fences etc.)
  defp extract_json(text) do
    cond do
      String.contains?(text, "```json") ->
        text
        |> String.split("```json")
        |> Enum.at(1, "")
        |> String.split("```")
        |> List.first("")
        |> String.trim()

      String.contains?(text, "{") ->
        case :binary.match(text, "{") do
          {pos, _} ->
            String.slice(text, pos..-1//1) |> find_balanced_json()
          :nomatch ->
            text
        end

      true ->
        text
    end
  end

  defp find_balanced_json(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, []}, fn char, {depth, acc} ->
      new_depth = case char do
        "{" -> depth + 1
        "}" -> depth - 1
        _ -> depth
      end

      new_acc = [char | acc]

      if new_depth == 0 and depth > 0 do
        {:halt, {0, new_acc}}
      else
        {:cont, {new_depth, new_acc}}
      end
    end)
    |> case do
      {_, chars} -> chars |> Enum.reverse() |> Enum.join()
      _ -> text
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: CLAUSE MAPPING HELPERS
  # ──────────────────────────────────────────────────────────

  defp map_clause_type("commercial"), do: :price_term
  defp map_clause_type("core_terms"), do: :obligation
  defp map_clause_type("logistics"), do: :delivery
  defp map_clause_type("logistics_cost"), do: :penalty
  defp map_clause_type("risk_events"), do: :condition
  defp map_clause_type("credit_legal"), do: :condition
  defp map_clause_type("legal"), do: :legal
  defp map_clause_type("compliance"), do: :compliance
  defp map_clause_type("operational"), do: :operational
  defp map_clause_type("metadata"), do: :metadata
  defp map_clause_type("determination"), do: :condition
  defp map_clause_type("documentation"), do: :metadata
  defp map_clause_type("risk_allocation"), do: :condition
  defp map_clause_type("risk_costs"), do: :condition
  defp map_clause_type("incorporation"), do: :metadata
  defp map_clause_type(nil), do: :condition
  defp map_clause_type(_), do: :condition

  # Look up LP parameter from the canonical clause's lp_mapping
  defp lp_parameter_for(clause_id) when is_binary(clause_id) do
    case TemplateRegistry.get_clause(clause_id) do
      %{lp_mapping: [first | _]} -> first
      _ -> nil
    end
  end
  defp lp_parameter_for(_), do: nil

  defp parse_operator(">="), do: :>=
  defp parse_operator("<="), do: :<=
  defp parse_operator("=="), do: :==
  defp parse_operator("between"), do: :between
  defp parse_operator(_), do: nil

  # ──────────────────────────────────────────────────────────
  # PRIVATE: SCHEDULE GENERATION
  # ──────────────────────────────────────────────────────────

  defp schedule_deliveries_async(contract) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn ->
        with_position = fetch_sap_position(contract)
        DeliveryScheduler.generate_from_contract(with_position)
      end
    )
  end

  defp fetch_sap_position(contract) do
    case SapPositions.fetch_position(contract.counterparty) do
      {:ok, pos} when is_map(pos) ->
        open_qty = pos.open_qty_mt || pos[:open_quantity] || 0.0
        Store.update_open_position(contract.counterparty, contract.product_group, open_qty)
        %{contract | open_position: open_qty}

      _ ->
        Logger.debug("FolderScanner: SAP position unavailable for #{contract.counterparty}")
        contract
    end
  rescue
    _ -> contract
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: SOFT-DELETE
  # ──────────────────────────────────────────────────────────

  defp soft_delete_missing(contracts, reason) do
    now = DateTime.utc_now()

    Enum.each(contracts, fn contract ->
      updated = %{contract |
        deleted_at: now,
        deletion_reason: reason,
        updated_at: now
      }

      Store.soft_delete(contract.id, reason)
      TradingDesk.DB.Writer.persist_contract(updated)

      Logger.info("FolderScanner: soft-deleted #{contract.counterparty} v#{contract.version} (#{reason})")
    end)

    length(contracts)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: HELPERS
  # ──────────────────────────────────────────────────────────

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

  defp get_previous_hash(counterparty, product_group) do
    case Store.list_versions(counterparty, product_group) do
      [latest | _] -> latest.file_hash
      [] -> nil
    end
  end

  defp detect_format(path) do
    case Path.extname(path) |> String.downcase() do
      ".pdf" -> :pdf
      ".docx" -> :docx
      ".docm" -> :docm
      ".txt" -> :txt
      _ -> nil
    end
  end

  defp get_str(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end
  defp get_str(_, _), do: nil

  defp get_num(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      val when is_number(val) -> val
      val when is_binary(val) ->
        case Float.parse(val) do
          {n, _} -> n
          :error -> nil
        end
      _ -> nil
    end
  end
  defp get_num(_, _), do: nil

  defp safe_atom(nil), do: nil
  defp safe_atom(""), do: nil
  defp safe_atom(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.to_atom()
  end
  defp safe_atom(atom) when is_atom(atom), do: atom

  # ──────────────────────────────────────────────────────────
  # PRIVATE: PUBSUB
  # ──────────────────────────────────────────────────────────

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
