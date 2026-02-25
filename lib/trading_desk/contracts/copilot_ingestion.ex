defmodule TradingDesk.Contracts.CopilotIngestion do
  @moduledoc """
  Accepts pre-extracted clause data from the LLM extraction service
  and ingests it into the contract system.

  This is the sole extraction path. The LLM reads the actual contract
  document, extracts ALL clauses it can identify, maps them directly to
  solver variables with operator/value/unit, and returns structured JSON.
  This module accepts that output and creates a fully tracked contract
  in the Store.

  The LLM is not constrained to a fixed clause inventory — it extracts
  every provision, term, or obligation from the contract. Clauses that
  map to solver variables include solver-ready fields (parameter, operator,
  value) so the constraint bridge can apply them directly.

  ## LLM extraction payload format

  The LLM returns a map (or JSON) with this structure:

      %{
        "contract_number" => "TRAMMO-LTP-2026-0001",
        "counterparty" => "Ma'aden Wa'ad Al Shamal Phosphate Company",
        "counterparty_type" => "supplier",
        "direction" => "purchase",
        "incoterm" => "FOB",
        "term_type" => "long_term",
        "company" => "trammo_inc",
        "effective_date" => "2026-01-01",
        "expiry_date" => "2028-12-31",
        "family_id" => "LONG_TERM_PURCHASE_FOB",
        "clauses" => [
          %{
            "clause_id" => "PRICE",
            "category" => "commercial",
            "extracted_fields" => %{
              "price_value" => 340.00,
              "price_uom" => "$/ton",
              "pricing_mechanism" => "fixed"
            },
            "source_text" => "Purchase Price: US $340.00 per metric ton...",
            "section_ref" => "Section 5",
            "confidence" => "high",
            "parameter" => "nola_buy",
            "operator" => "==",
            "value" => 340.00,
            "value_upper" => nil,
            "unit" => "$/ton",
            "penalty_per_unit" => nil,
            "penalty_cap" => nil,
            "period" => nil
          },
          ...
        ]
      }
  """

  alias TradingDesk.Contracts.{
    Clause,
    Contract,
    Store,
    HashVerifier,
    CurrencyTracker
  }

  require Logger

  @pubsub TradingDesk.PubSub
  @topic "contracts"

  # ──────────────────────────────────────────────────────────
  # PRIMARY INGESTION — Copilot provides extraction
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest a contract from the LLM's extraction output.

  `file_path` is the path to the original document (for hashing).
  `extraction` is the structured map from the LLM (see moduledoc).
  `opts` are overrides for product_group, network_path, sap_contract_id.

  Returns {:ok, contract} with:
    - All clauses stored as solver-ready %Clause{} structs
    - Document hash computed and stored
  """
  @spec ingest(String.t(), map(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def ingest(file_path, extraction, opts \\ []) do
    with {:hash, {:ok, file_hash, file_size}} <- {:hash, HashVerifier.compute_file_hash(file_path)},
         {:extract, {:ok, clauses}} <- {:extract, build_clauses(extraction)} do

      contract = build_contract(extraction, clauses, file_path, file_hash, file_size, opts)

      case Store.ingest(contract) do
        {:ok, stored} ->
          CurrencyTracker.stamp(stored.id, :parsed_at)

          broadcast(:ingestion_complete, %{
            contract_id: stored.id,
            contract_number: stored.contract_number,
            counterparty: stored.counterparty,
            clause_count: length(clauses)
          })

          Logger.info(
            "Contract ingestion: #{stored.counterparty} #{stored.contract_number || "?"} " <>
            "(#{length(clauses)} clauses, hash=#{String.slice(file_hash, 0, 12)}...)"
          )

          {:ok, stored}

        {:error, reason} ->
          {:error, {:store_failed, reason}}
      end
    else
      {:hash, {:error, reason}} -> {:error, {:hash_failed, reason}}
      {:extract, {:error, reason}} -> {:error, {:extraction_failed, reason}}
    end
  end

  @doc """
  Ingest from LLM output when we already have the file hash
  (e.g., LLM service computed it). Skips re-reading the file for hashing.
  """
  @spec ingest_with_hash(map(), keyword()) :: {:ok, Contract.t()} | {:error, term()}
  def ingest_with_hash(extraction, opts \\ []) do
    with {:extract, {:ok, clauses}} <- {:extract, build_clauses(extraction)} do
      file_hash = get_string(extraction, "file_hash")
      file_size = get_number(extraction, "file_size")

      contract = build_contract(
        extraction, clauses, nil, file_hash, file_size, opts
      )

      case Store.ingest(contract) do
        {:ok, stored} ->
          CurrencyTracker.stamp(stored.id, :parsed_at)

          broadcast(:ingestion_complete, %{
            contract_id: stored.id,
            contract_number: stored.contract_number,
            counterparty: stored.counterparty,
            clause_count: length(clauses)
          })

          {:ok, stored}

        {:error, reason} ->
          {:error, {:store_failed, reason}}
      end
    else
      {:extract, {:error, reason}} -> {:error, {:extraction_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # BATCH INGESTION — multiple contracts from Copilot
  # ──────────────────────────────────────────────────────────

  @doc """
  Ingest multiple contracts from a batch Copilot extraction.

  `batch` is a list of {file_path, extraction_map} tuples.
  Returns a summary of results.
  """
  @spec ingest_batch([{String.t(), map()}], keyword()) :: {:ok, map()}
  def ingest_batch(batch, opts \\ []) do
    results =
      Enum.map(batch, fn {file_path, extraction} ->
        result = ingest(file_path, extraction, opts)
        {file_path, result}
      end)

    succeeded = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn {_, r} -> not match?({:ok, _}, r) end)

    {:ok, %{
      total: length(batch),
      succeeded: succeeded,
      failed: failed,
      details: results,
      ingested_at: DateTime.utc_now()
    }}
  end

  # ──────────────────────────────────────────────────────────
  # CLAUSE BUILDING — convert LLM JSON to %Clause{} structs
  #
  # The LLM returns solver-ready fields directly: parameter,
  # operator, value, unit, penalty_per_unit. No intermediate
  # mapping through a template registry or contract_term_map.
  # ──────────────────────────────────────────────────────────

  defp build_clauses(%{"clauses" => clauses}) when is_list(clauses) do
    now = DateTime.utc_now()

    built =
      Enum.map(clauses, fn clause_data ->
        %Clause{
          id: Clause.generate_id(),
          clause_id: get_string(clause_data, "clause_id"),
          type: map_clause_type(clause_data),
          category: safe_atom(get_string(clause_data, "category")),
          description: get_string(clause_data, "source_text") || "",
          reference_section: get_string(clause_data, "section_ref"),
          confidence: safe_atom(get_string(clause_data, "confidence") || "high"),
          anchors_matched: get_list(clause_data, "anchors_matched") || [],
          extracted_fields: get_map(clause_data, "extracted_fields") || %{},
          extracted_at: now,
          # Solver-ready fields — provided directly by the LLM
          parameter: safe_atom(get_string(clause_data, "parameter")),
          operator: safe_operator(get_string(clause_data, "operator")),
          value: get_number(clause_data, "value") || get_nested_number(clause_data, "extracted_fields", "price_value"),
          value_upper: get_number(clause_data, "value_upper"),
          unit: get_string(clause_data, "unit") || get_nested_string(clause_data, "extracted_fields", "price_uom"),
          penalty_per_unit: get_number(clause_data, "penalty_per_unit") || get_nested_number(clause_data, "extracted_fields", "demurrage_rate"),
          penalty_cap: get_number(clause_data, "penalty_cap"),
          period: safe_atom(get_string(clause_data, "period"))
        }
      end)

    {:ok, built}
  end

  defp build_clauses(_), do: {:error, :no_clauses_in_extraction}

  # ──────────────────────────────────────────────────────────
  # CONTRACT BUILDING
  # ──────────────────────────────────────────────────────────

  defp build_contract(extraction, clauses, file_path, file_hash, file_size, opts) do
    counterparty = get_string(extraction, "counterparty") || "Unknown"
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    %Contract{
      counterparty: counterparty,
      counterparty_type: safe_atom(get_string(extraction, "counterparty_type")) || :customer,
      product_group: product_group,
      template_type: safe_atom(get_string(extraction, "direction")),
      incoterm: safe_atom(String.downcase(get_string(extraction, "incoterm") || "")),
      term_type: safe_atom(get_string(extraction, "term_type")),
      company: safe_atom(get_string(extraction, "company")),
      source_file: if(file_path, do: Path.basename(file_path), else: get_string(extraction, "source_file")),
      source_format: if(file_path, do: detect_format(file_path), else: safe_atom(get_string(extraction, "source_format"))),
      clauses: clauses,
      contract_date: parse_date(get_string(extraction, "effective_date")),
      expiry_date: parse_date(get_string(extraction, "expiry_date")),
      sap_contract_id: Keyword.get(opts, :sap_contract_id) || get_string(extraction, "sap_contract_id"),
      # Copilot-provided metadata
      contract_number: get_string(extraction, "contract_number"),
      family_id: get_string(extraction, "family_id"),
      file_hash: file_hash,
      file_size: file_size,
      network_path: Keyword.get(opts, :network_path) || get_string(extraction, "network_path") || file_path,
      verification_status: :pending,
      previous_hash: get_previous_hash(counterparty, product_group)
    }
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE HELPERS
  # ──────────────────────────────────────────────────────────

  defp map_clause_type(%{"category" => cat}) do
    case cat do
      "commercial" -> :price_term
      "core_terms" -> :obligation
      "logistics" -> :delivery
      "logistics_cost" -> :penalty
      "risk_events" -> :condition
      "credit_legal" -> :condition
      "legal" -> :legal
      "compliance" -> :compliance
      "operational" -> :operational
      "metadata" -> :metadata
      _ -> :condition
    end
  end
  defp map_clause_type(_), do: :condition

  # Convert LLM operator string to atom
  defp safe_operator(nil), do: nil
  defp safe_operator("=="), do: :==
  defp safe_operator(">="), do: :>=
  defp safe_operator("<="), do: :<=
  defp safe_operator("between"), do: :between
  defp safe_operator(_), do: nil

  # --- Data access helpers (handle string keys from JSON) ---

  defp get_string(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      nil -> nil
      val when is_binary(val) -> val
      val -> to_string(val)
    end
  end
  defp get_string(_, _), do: nil

  defp get_number(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
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
  defp get_number(_, _), do: nil

  defp get_nested_number(map, outer_key, inner_key) do
    case get_map(map, outer_key) do
      nil -> nil
      inner -> get_number(inner, inner_key)
    end
  end

  defp get_nested_string(map, outer_key, inner_key) do
    case get_map(map, outer_key) do
      nil -> nil
      inner -> get_string(inner, inner_key)
    end
  end

  defp get_map(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      val when is_map(val) -> val
      _ -> nil
    end
  end
  defp get_map(_, _), do: nil

  defp get_list(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      val when is_list(val) -> val
      _ -> nil
    end
  end
  defp get_list(_, _), do: nil

  defp safe_atom(nil), do: nil
  defp safe_atom(""), do: nil
  defp safe_atom(str) when is_binary(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.to_atom()
  end
  defp safe_atom(atom) when is_atom(atom), do: atom

  defp parse_date(nil), do: nil
  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp detect_format(path) do
    TradingDesk.Contracts.DocumentReader.detect_format(path)
  end

  defp get_previous_hash(counterparty, product_group) do
    case Store.list_versions(counterparty, product_group) do
      [latest | _] -> latest.file_hash
      [] -> nil
    end
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
