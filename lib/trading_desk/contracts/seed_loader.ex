defmodule TradingDesk.Contracts.SeedLoader do
  @moduledoc """
  Loads seed contract files, parses them, and ingests them into the Store
  with realistic open positions for solver testing.

  Each seed contract represents an open commitment in Trammo's ammonia book.
  The open position is the quantity still outstanding (not yet delivered/lifted)
  as of the current date. The solver needs this to compute:
    - How much product must still flow through each route
    - What penalties are at risk if volumes fall short
    - Where Trammo is long (excess supply) vs short (excess obligations)

  Usage:
    SeedLoader.load_all()           # parse + ingest all seed contracts
    SeedLoader.open_book_summary()  # aggregate open positions
  """

  alias TradingDesk.Contracts.{Contract, Store, ConstraintBridge, TemplateRegistry}
  alias TradingDesk.Contracts.Clause
  alias TradingDesk.LLM.{Pool, ModelRegistry}

  require Logger

  @seed_dir "priv/contracts/seed"

  # Open positions per contract as of Feb 2026.
  # These represent the remaining obligation for the current contract year.
  # Format: {filename_prefix, counterparty, counterparty_type, open_position_mt}
  @seed_positions [
    {"01_purchase_lt_fob_trinidad",  "NGC Trinidad",     :supplier, 150_000},
    {"02_purchase_lt_fob_mideast",   "SABIC Agri-Nutrients", :supplier, 112_500},
    {"03_purchase_spot_fob_yuzhnyy", "Ameropa AG",       :supplier,  23_000},
    {"04_purchase_domestic_barge",   "LSB Industries",   :supplier,  24_000},
    {"05_sale_lt_cfr_tampa",         "Mosaic Company",   :customer,  75_000},
    {"06_sale_lt_cfr_india",         "IFFCO",            :customer, 100_000},
    {"07_sale_spot_cfr_morocco",     "OCP Group",        :customer,  20_000},
    {"08_sale_domestic_barge_stl",   "Nutrien StL",      :customer,  15_000},
    {"09_sale_domestic_barge_memphis", "Koch Fertilizer", :customer,  12_000},
    {"10_sale_spot_dap_nwe",         "BASF SE",          :customer,  15_000}
  ]

  @doc """
  Load all seed contracts from priv/contracts/seed/.

  Parses each file, detects family and incoterm, sets open position,
  and ingests into the Store. Returns list of ingested contracts.
  """
  def load_all do
    seed_path = Application.app_dir(:trading_desk, @seed_dir)

    results =
      @seed_positions
      |> Enum.map(fn {prefix, counterparty, cp_type, open_qty} ->
        case find_seed_file(seed_path, prefix) do
          {:ok, file_path} ->
            load_one(file_path, counterparty, cp_type, open_qty, skip_llm: true)

          :not_found ->
            Logger.warning("Seed file not found for prefix: #{prefix}")
            {:error, {:file_not_found, prefix}}
        end
      end)

    loaded = Enum.filter(results, &match?({:ok, _}, &1)) |> Enum.map(&elem(&1, 1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if length(errors) > 0 do
      Logger.warning("#{length(errors)} seed contract(s) failed to load")
    end

    Logger.info(
      "Loaded #{length(loaded)} seed contracts: " <>
      "#{length(Enum.filter(loaded, &(&1.counterparty_type == :supplier)))} purchases, " <>
      "#{length(Enum.filter(loaded, &(&1.counterparty_type == :customer)))} sales"
    )

    loaded
  end

  @doc """
  Load seed contracts from a custom directory (for testing).
  """
  def load_all(seed_path) when is_binary(seed_path) do
    @seed_positions
    |> Enum.map(fn {prefix, counterparty, cp_type, open_qty} ->
      case find_seed_file(seed_path, prefix) do
        {:ok, file_path} -> load_one(file_path, counterparty, cp_type, open_qty, skip_llm: true)
        :not_found -> {:error, {:file_not_found, prefix}}
      end
    end)
    |> Enum.filter(&match?({:ok, _}, &1))
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Get a summary of the open book after seed contracts are loaded.

  Delegates to ConstraintBridge.aggregate_open_book/1.
  """
  def open_book_summary(product_group \\ :ammonia) do
    ConstraintBridge.aggregate_open_book(product_group)
  end

  @doc """
  Get the penalty schedule for all loaded seed contracts.
  """
  def penalty_summary(product_group \\ :ammonia) do
    ConstraintBridge.penalty_schedule(product_group)
  end

  @doc """
  Force re-ingest all seed contracts and return a detailed ingestion summary.

  Unlike load_all/0, this always creates a new contract version, superseding
  any existing ones. Returns a summary map suitable for the UI to display.

  Returns:
    %{
      loaded: count,
      errors: count,
      contracts: [%{counterparty, file, clauses, penalties, incoterm, ...}],
      available_files: [...],
      total_purchase_open: MT,
      total_sale_open: MT,
      net_position: MT,
      total_clauses: count,
      total_penalty_clauses: count
    }
  """
  def reload_all, do: reload_all([])

  @doc """
  Force re-ingest all seed contracts with optional progress reporting.

  Options:
    - `:caller_pid` — if set, sends progress messages per contract:
        `{:extraction_progress, index, total, counterparty, status, detail}`
      where status is `:extracting`, `:done`, or `:error`
      and after each success sends `{:contract_loaded, counterparty, n_clauses}`
      so the UI can refresh its table immediately.
  """
  def reload_all(opts) when is_list(opts) do
    seed_path = Application.app_dir(:trading_desk, @seed_dir)
    available = list_seed_files_in(seed_path)
    caller = Keyword.get(opts, :caller_pid)
    total = length(@seed_positions)

    # Notify all as extracting, then fire LLM calls in parallel
    indexed = Enum.with_index(@seed_positions, 1)
    for {{_prefix, counterparty, _cp_type, _open_qty}, idx} <- indexed do
      notify(caller, {:extraction_progress, idx, total, counterparty, :extracting, "Sending to LLM..."})
    end

    results =
      indexed
      |> Task.async_stream(
        fn {{prefix, counterparty, cp_type, open_qty}, idx} ->
          case find_seed_file(seed_path, prefix) do
            {:ok, file_path} ->
              result = load_one(file_path, counterparty, cp_type, open_qty, caller_pid: caller)

              case result do
                {:ok, c} ->
                  n_clauses = length(c.clauses || [])
                  n_penalties = count_penalties(c.clauses || [])
                  notify(caller, {:extraction_progress, idx, total, counterparty, :done,
                    "#{n_clauses} clauses (#{n_penalties} penalties)"})
                  notify(caller, {:contract_loaded, counterparty, n_clauses})

                {:error, reason} ->
                  notify(caller, {:extraction_progress, idx, total, counterparty, :error, inspect(reason)})
              end

              {prefix, counterparty, cp_type, open_qty, file_path, result}

            :not_found ->
              Logger.warning("Seed file not found for prefix: #{prefix}")
              notify(caller, {:extraction_progress, idx, total, counterparty, :error, "File not found"})
              {prefix, counterparty, cp_type, open_qty, nil, {:error, :file_not_found}}
          end
        end,
        max_concurrency: 2,
        timeout: 300_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    loaded_tuples = Enum.filter(results, fn {_, _, _, _, _, r} -> match?({:ok, _}, r) end)
    error_tuples  = Enum.filter(results, fn {_, _, _, _, _, r} -> match?({:error, _}, r) end)

    contract_summaries =
      Enum.map(loaded_tuples, fn {_prefix, counterparty, cp_type, open_qty, file_path, {:ok, c}} ->
        n_clauses  = length(c.clauses || [])
        n_penalties = count_penalties(c.clauses || [])
        %{
          counterparty:      counterparty,
          counterparty_type: cp_type,
          open_qty:          open_qty,
          file:              if(file_path, do: Path.basename(file_path), else: ""),
          clauses:           n_clauses,
          penalties:         n_penalties,
          incoterm:          c.incoterm,
          family_id:         c.family_id,
          contract_number:   c.contract_number
        }
      end)

    purchases        = Enum.filter(contract_summaries, & &1.counterparty_type == :supplier)
    sales            = Enum.filter(contract_summaries, & &1.counterparty_type == :customer)
    total_purchase   = Enum.reduce(purchases, 0, & &1.open_qty + &2)
    total_sale       = Enum.reduce(sales,     0, & &1.open_qty + &2)
    total_penalties  = Enum.reduce(contract_summaries, 0, & &1.penalties + &2)
    total_clauses    = Enum.reduce(contract_summaries, 0, & &1.clauses + &2)

    %{
      loaded:                length(loaded_tuples),
      errors:                length(error_tuples),
      contracts:             contract_summaries,
      available_files:       available,
      total_purchase_open:   total_purchase,
      total_sale_open:       total_sale,
      net_position:          total_purchase - total_sale,
      total_clauses:         total_clauses,
      total_penalty_clauses: total_penalties
    }
  end

  defp notify(nil, _msg), do: :ok
  defp notify(pid, msg), do: send(pid, msg)

  @doc """
  List available seed contract files without loading them.
  Useful for the UI to preview what will be ingested.
  """
  def list_seed_files do
    seed_path = Application.app_dir(:trading_desk, @seed_dir)
    list_seed_files_in(seed_path)
  end

  @doc """
  Return the seed position data without loading (for testing/inspection).
  """
  def seed_positions, do: @seed_positions

  # ── Private ──────────────────────────────────────────────

  defp load_one(file_path, counterparty, cp_type, open_qty, opts \\ []) do
    text = File.read!(file_path)
    skip_llm = Keyword.get(opts, :skip_llm, false)
    caller = Keyword.get(opts, :caller_pid)

    clauses =
      if skip_llm do
        []
      else
        case extract_clauses_via_llm(text, caller) do
          {:ok, llm_clauses} -> llm_clauses
          {:error, reason} ->
            Logger.warning("SeedLoader: LLM extraction failed for #{counterparty}: #{inspect(reason)}, using empty clauses")
            []
        end
      end

    {family_id, family} =
      case TemplateRegistry.detect_family(text) do
        {:ok, fid, fam} -> {fid, fam}
        _ -> {nil, nil}
      end

    incoterm =
      case Enum.find(clauses, &(&1.clause_id == "INCOTERMS")) do
        %{extracted_fields: %{incoterm_rule: rule}} when is_binary(rule) ->
          rule |> String.downcase() |> String.to_existing_atom()
        _ ->
          if family, do: List.first(family.default_incoterms), else: nil
      end

    template_type =
      case {family && family.direction, family && family.term_type} do
        {:purchase, :long_term} -> :purchase
        {:purchase, :spot}      -> :spot_purchase
        {:sale, :long_term}     -> :sale
        {:sale, :spot}          -> :spot_sale
        _                       -> if(cp_type == :supplier, do: :purchase, else: :sale)
      end

    term_type = if(family, do: family.term_type, else: :spot)
    transport = if(family, do: family.transport, else: :vessel)

    company =
      cond do
        String.contains?(text, "Trammo SAS") -> :trammo_sas
        String.contains?(text, "Trammo DMCC") -> :trammo_dmcc
        true -> :trammo_inc
      end

    contract_number = extract_contract_number(text)

    contract = %Contract{
      counterparty: counterparty,
      counterparty_type: cp_type,
      product_group: :ammonia,
      template_type: template_type,
      incoterm: incoterm,
      term_type: term_type,
      company: company,
      source_file: Path.basename(file_path),
      source_format: :txt,
      clauses: clauses,
      family_id: family_id,
      contract_number: contract_number,
      open_position: open_qty
    }

    case Store.ingest(contract) do
      {:ok, ingested} ->
        # Auto-approve for seed data (skip legal review workflow)
        Store.update_status(ingested.id, :pending_review)
        Store.update_status(ingested.id, :approved,
          reviewed_by: "seed_loader",
          notes: "Auto-approved seed contract for solver testing"
        )

        Logger.info(
          "Seed: #{counterparty} (#{cp_type}) #{incoterm} | " <>
          "family=#{family_id} | open=#{open_qty} MT | " <>
          "clauses=#{length(clauses)} | penalties=#{count_penalties(clauses)}"
        )

        {:ok, ingested}

      error ->
        Logger.error("Failed to ingest seed contract #{counterparty}: #{inspect(error)}")
        error
    end
  end

  defp list_seed_files_in(seed_path) do
    Enum.map(@seed_positions, fn {prefix, counterparty, cp_type, open_qty} ->
      file_path =
        case Path.wildcard(Path.join(seed_path, "#{prefix}*.txt")) do
          [f | _] -> f
          []      -> nil
        end

      %{
        prefix:            prefix,
        counterparty:      counterparty,
        counterparty_type: cp_type,
        open_qty:          open_qty,
        file:              if(file_path, do: Path.basename(file_path), else: nil),
        found:             not is_nil(file_path)
      }
    end)
  end

  defp find_seed_file(seed_path, prefix) do
    case Path.wildcard(Path.join(seed_path, "#{prefix}*.txt")) do
      [file | _] -> {:ok, file}
      [] -> :not_found
    end
  end

  defp extract_contract_number(text) do
    case Regex.run(~r/Contract\s+No\.?\s*:?\s*(TRAMMO-[A-Z0-9-]+)/i, text) do
      [_, number] -> number
      _ -> nil
    end
  end

  defp count_penalties(clauses) do
    Enum.count(clauses, fn c ->
      c.category in [:penalty, :demurrage, :take_or_pay] or
        String.contains?(to_string(c.clause_id), "PENALTY") or
        String.contains?(to_string(c.clause_id), "DEMURRAGE") or
        not is_nil(Map.get(c.extracted_fields || %{}, "penalty_per_unit"))
    end)
  end

  # ── Two-stage LLM clause extraction ──────────────────────

  defp extract_clauses_via_llm(text), do: extract_clauses_via_llm(text, nil)

  defp extract_clauses_via_llm(text, caller) do
    extractor = ModelRegistry.extractor()
    reasoner = ModelRegistry.reasoner()

    cond do
      is_nil(extractor) and is_nil(reasoner) ->
        {:error, :no_model_registered}

      is_nil(extractor) ->
        # Fallback: single-stage with reasoner only
        prompt = build_stage2_prompt(text)
        case Pool.generate(reasoner.id, prompt, max_tokens: 4096) do
          {:ok, raw} -> parse_llm_clauses(raw)
          {:error, reason} -> {:error, reason}
        end

      true ->
        # Two-stage pipeline: Haiku extract → Opus formulate
        notify(caller, {:extraction_stage, 1, "Extracting data (#{extractor.name})..."})

        case extract_structured_data(text, extractor) do
          {:ok, structured_json} ->
            notify(caller, {:extraction_stage, 2, "LP formulation (#{(reasoner || extractor).name})..."})
            formulate_lp_constraints(structured_json, reasoner || extractor)

          {:error, reason} ->
            {:error, {:stage1_failed, reason}}
        end
    end
  end

  # Stage 1: Haiku — pure data extraction (cheap, fast)
  defp extract_structured_data(contract_text, model) do
    max_chars = 50_000
    truncated = if String.length(contract_text) > max_chars do
      String.slice(contract_text, 0, max_chars) <> "\n[...truncated...]"
    else
      contract_text
    end

    prompt = """
    You are a contract data extraction system. Read this ammonia trading contract
    and extract ALL structured data into the JSON format below.

    Do NOT interpret, reason about, or formulate constraints. Simply read and structure
    what is written in the contract.

    Return ONLY valid JSON:
    {"contract_data": {
      "quantities": { "annual_qty_mt": null, "tolerance_pct": null, "min_cargoes": null, "cargo_size_mt": null, "cargo_tolerance_pct": null },
      "pricing": { "base_price_usd_per_mt": null, "price_floor": null, "price_ceiling": null, "escalation": null, "benchmark": null },
      "delivery_schedule": { "start_date": null, "end_date": null, "frequency": null, "nomination_days": null, "laycan_window_days": null, "max_liftings_per_month": null },
      "logistics": { "loading_rate_mt_per_day": null, "discharge_rate": null, "laytime_hours": null, "demurrage_usd_per_day": null, "despatch_usd_per_day": null },
      "payment": { "terms_days": null, "instrument": null, "late_penalty_pct": null },
      "quality": { "purity_min_pct": null, "water_max_pct": null, "oil_max_ppm": null, "temp_max": null },
      "penalties": [{ "type": null, "trigger": null, "rate": null, "rate_unit": null, "cap_usd": null }],
      "take_or_pay": { "minimum_pct": null, "shortfall_penalty_usd_per_mt": null },
      "force_majeure": { "triggers": [], "notice_days": null, "suspension_rights": null },
      "insurance": { "required": null, "type": null },
      "legal": { "governing_law": null, "arbitration_venue": null },
      "optionality": { "extension_option": null, "volume_flex_pct": null, "price_reopener": null },
      "parties": { "seller": null, "buyer": null, "incoterm": null }
    }}

    Omit any section not found in the contract. Use null for unknown values.
    Extract exact numbers and dates as written.

    CONTRACT TEXT:
    #{truncated}
    """

    case Pool.generate(model.id, prompt, max_tokens: 8192) do
      {:ok, raw_text} ->
        json_str = extract_json(raw_text)
        case Jason.decode(json_str) do
          {:ok, %{"contract_data" => _} = data} -> {:ok, data}
          {:ok, data} when is_map(data) -> {:ok, %{"contract_data" => data}}
          {:error, reason} -> {:error, {:stage1_json_parse_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stage 2: Opus — LP constraint formulation (smart, expensive)
  # Prompt is built dynamically from what stage 1 actually extracted.
  defp formulate_lp_constraints(structured_json, model) do
    data = structured_json["contract_data"] || %{}
    directives = build_formulation_directives(data)

    if directives == "" do
      Logger.warning("SeedLoader: Stage 1 extracted no usable data, skipping LP formulation")
      {:ok, []}
    else
      json_text = Jason.encode!(structured_json, pretty: true)

      prompt = """
      You are an expert LP (Linear Programming) formulation analyst for commodity trading.

      Below is structured data extracted from an ammonia trading contract.
      Formulate LP constraints ONLY for the data present. Do not invent values.

      EXTRACTED CONTRACT DATA:
      #{json_text}

      FORMULATION DIRECTIVES (based on what was extracted):
      #{directives}

      Return ONLY valid JSON: {"clauses": [...]}

      Each clause must have:
      - "clause_id": SHORT_UPPERCASE_ID describing the constraint
      - "category": one of "quantity", "delivery_schedule", "pricing", "payment", "logistics", "quality_spec", "penalty", "take_or_pay", "demurrage", "force_majeure", "insurance", "legal", "operational"
      - "description": plain-English operational meaning
      - "parameter": solver variable name (e.g. "annual_qty", "cargo_size", "nola_buy")
      - "operator": ">=", "<=", "==", "between"
      - "value": numeric value (lower bound for "between")
      - "value_upper": upper bound (only for "between")
      - "unit": "$/ton", "tons", "days", etc.
      - "penalty_rate": $/ton or $/day penalty for violation (if applicable)
      - "penalty_cap": maximum penalty exposure in $ (if applicable)
      - "period": "monthly"/"quarterly"/"annual"/"per_cargo"
      - "confidence": "high"/"medium"/"low"
      - "source_text": the extracted data point this constraint is derived from

      IMPORTANT:
      - Be concise. One clause per obligation — do NOT create redundant clauses.
      - For a bounded range, use a SINGLE "between" clause (not separate >= and <= clauses).
      - Keep descriptions short (one sentence).
      """

      case Pool.generate(model.id, prompt, max_tokens: 8192) do
        {:ok, raw_text} ->
          parse_llm_clauses(raw_text)

        {:error, reason} ->
          Logger.warning("SeedLoader: Stage 2 (LP formulation) failed: #{inspect(reason)}, falling back to basic clause mapping")
          build_basic_clauses_from_structured(structured_json)
      end
    end
  end

  # Build dynamic formulation directives from the actual stage 1 data.
  # Only includes instructions for sections that have real values.
  defp build_formulation_directives(data) do
    sections = [
      &quantities_directive/1,
      &pricing_directive/1,
      &delivery_directive/1,
      &logistics_directive/1,
      &payment_directive/1,
      &quality_directive/1,
      &penalties_directive/1,
      &take_or_pay_directive/1,
      &force_majeure_directive/1,
      &insurance_directive/1,
      &legal_directive/1,
      &optionality_directive/1
    ]

    sections
    |> Enum.map(fn f -> f.(data) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp quantities_directive(data) do
    q = data["quantities"]
    if has_values?(q) do
      vals = format_kv(q)
      """
      QUANTITIES: #{vals}
      → Formulate: annual volume bound (>= min with tolerance, <= max with tolerance), per-cargo size bounds, minimum cargoes constraint.
      """
    end
  end

  defp pricing_directive(data) do
    p = data["pricing"]
    if has_values?(p) do
      vals = format_kv(p)
      """
      PRICING: #{vals}
      → Formulate: price equality or bounds (floor/ceiling as >= / <=), escalation as a per-period adjustment coefficient if present.
      """
    end
  end

  defp delivery_directive(data) do
    d = data["delivery_schedule"]
    if has_values?(d) do
      vals = format_kv(d)
      """
      DELIVERY SCHEDULE: #{vals}
      → Formulate: delivery frequency constraint, nomination lead-time, laycan window bounds, max liftings per period.
      """
    end
  end

  defp logistics_directive(data) do
    l = data["logistics"]
    if has_values?(l) do
      vals = format_kv(l)
      """
      LOGISTICS: #{vals}
      → Formulate: loading/discharge rate constraints, laytime bound, demurrage rate as penalty coefficient ($/day), despatch credit if present.
      """
    end
  end

  defp payment_directive(data) do
    p = data["payment"]
    if has_values?(p) do
      vals = format_kv(p)
      """
      PAYMENT: #{vals}
      → Formulate: payment days as working-capital constraint, late penalty as a penalty rate coefficient.
      """
    end
  end

  defp quality_directive(data) do
    q = data["quality"]
    if has_values?(q) do
      vals = format_kv(q)
      """
      QUALITY: #{vals}
      → Formulate: quality bounds (purity >= min, water <= max, oil <= max, temp <= max).
      """
    end
  end

  defp penalties_directive(data) do
    p = data["penalties"]
    if is_list(p) and length(p) > 0 and Enum.any?(p, &has_values?/1) do
      items = Enum.map_join(p, "; ", &format_kv/1)
      """
      PENALTIES: #{items}
      → Formulate: each penalty as a constraint violation cost — penalty_rate and penalty_cap per trigger.
      """
    end
  end

  defp take_or_pay_directive(data) do
    t = data["take_or_pay"]
    if has_values?(t) do
      vals = format_kv(t)
      """
      TAKE-OR-PAY: #{vals}
      → Formulate: minimum volume as >= constraint (minimum_pct × annual_qty), shortfall penalty as penalty_rate per ton below minimum.
      """
    end
  end

  defp force_majeure_directive(data) do
    f = data["force_majeure"]
    if has_values?(f) do
      vals = format_kv(f)
      """
      FORCE MAJEURE: #{vals}
      → Formulate: informational flag with triggers and notice period. Set parameter=null (no direct solver variable).
      """
    end
  end

  defp insurance_directive(data) do
    i = data["insurance"]
    if has_values?(i) do
      vals = format_kv(i)
      "INSURANCE: #{vals}\n→ Formulate: informational/compliance clause."
    end
  end

  defp legal_directive(data) do
    l = data["legal"]
    if has_values?(l) do
      vals = format_kv(l)
      "LEGAL: #{vals}\n→ Formulate: informational clause (governing law, arbitration)."
    end
  end

  defp optionality_directive(data) do
    o = data["optionality"]
    if has_values?(o) do
      vals = format_kv(o)
      """
      OPTIONALITY: #{vals}
      → Formulate: extension option and volume flex as solver flags / bound adjustments, price reopener as informational.
      """
    end
  end

  defp has_values?(nil), do: false
  defp has_values?(m) when is_map(m) do
    Enum.any?(m, fn {_k, v} -> not is_nil(v) and v != "" and v != [] end)
  end
  defp has_values?(_), do: false

  defp format_kv(nil), do: ""
  defp format_kv(m) when is_map(m) do
    m
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" or v == [] end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)
  end
  defp format_kv(_), do: ""

  # Fallback: convert structured data to basic clauses without LP reasoning
  defp build_basic_clauses_from_structured(%{"contract_data" => data}) do
    now = DateTime.utc_now()

    clauses =
      []
      |> maybe_add_basic_clause(data["quantities"], "annual_qty_mt", "ANNUAL_QUANTITY", :quantity, "annual_qty", "tons", now)
      |> maybe_add_basic_clause(data["quantities"], "cargo_size_mt", "LIFTING_SIZE", :quantity, "cargo_size", "tons", now)
      |> maybe_add_basic_clause(data["pricing"], "base_price_usd_per_mt", "BASE_PRICE", :pricing, "base_price", "$/ton", now)
      |> maybe_add_basic_clause(data["logistics"], "demurrage_usd_per_day", "DEMURRAGE_RATE", :demurrage, "demurrage_rate", "$/day", now)
      |> maybe_add_basic_clause(data["logistics"], "laytime_hours", "LAYTIME", :logistics, "laytime", "hours", now)
      |> maybe_add_basic_clause(data["take_or_pay"], "minimum_pct", "TAKE_OR_PAY", :take_or_pay, "top_min_pct", "%", now)
      |> maybe_add_basic_clause(data["quality"], "purity_min_pct", "QUALITY_PURITY", :quality_spec, "purity_min", "%", now)

    {:ok, clauses}
  end

  defp build_basic_clauses_from_structured(_), do: {:ok, []}

  defp maybe_add_basic_clause(clauses, nil, _, _, _, _, _), do: clauses
  defp maybe_add_basic_clause(clauses, section, key, clause_id, category, parameter, unit, now) do
    case Map.get(section, key) do
      nil -> clauses
      val when is_number(val) ->
        [%Clause{
          id: Clause.generate_id(),
          clause_id: to_string(clause_id),
          type: map_clause_type(to_string(category)),
          category: category,
          description: "#{clause_id}: #{val} #{unit} (basic extraction fallback)",
          confidence: :low,
          extracted_fields: %{
            "parameter" => parameter,
            "operator" => "==",
            "value" => val,
            "unit" => unit,
            "source_text" => "Extracted from structured data: #{key} = #{val}"
          },
          extracted_at: now
        } | clauses]
      _ -> clauses
    end
  end

  defp build_stage2_prompt(contract_text) do
    inventory =
      TemplateRegistry.canonical_clauses()
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map_join(", ", fn {id, _} -> id end)

    max_chars = 12000
    truncated = if String.length(contract_text) > max_chars do
      String.slice(contract_text, 0, max_chars) <> "\n[...truncated...]"
    else
      contract_text
    end

    """
    You are an expert LP (Linear Programming) formulation analyst for commodity trading.

    Extract ALL structured data from this ammonia trading contract and formulate
    LP constraints for a solver. For each obligation, produce a formal constraint
    with solver variable names, operators, and bounds.

    Return ONLY valid JSON: {"clauses": [...]}

    Each clause must have:
    - "clause_id": identifier (use known IDs where possible: #{inventory}, or create descriptive ones)
    - "category": one of "quantity", "delivery_schedule", "pricing", "payment", "logistics", "quality_spec", "penalty", "take_or_pay", "demurrage", "force_majeure", "insurance", "legal", "operational"
    - "source_text": exact quote from the contract
    - "description": plain-English operational meaning
    - "parameter": solver variable name if applicable
    - "operator": ">=", "<=", "==", "between"
    - "value": numeric value (lower bound for "between")
    - "value_upper": upper bound (only for "between")
    - "unit": "$/ton", "tons", "days", etc.
    - "penalty_rate": $/ton or $/day penalty for violation
    - "penalty_cap": maximum penalty exposure in $
    - "period": "monthly"/"quarterly"/"annual"/"per_cargo"
    - "confidence": "high"/"medium"/"low"

    CONTRACT TEXT:
    #{truncated}
    """
  end

  defp parse_llm_clauses(raw_text) do
    json_str = extract_json(raw_text)
    now = DateTime.utc_now()

    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses}} when is_list(clauses) ->
        built = Enum.map(clauses, fn c ->
          merged_fields =
            %{}
            |> maybe_put("parameter", c["parameter"])
            |> maybe_put("operator", c["operator"])
            |> maybe_put("value", c["value"])
            |> maybe_put("value_upper", c["value_upper"])
            |> maybe_put("unit", c["unit"])
            |> maybe_put("penalty_per_unit", c["penalty_rate"] || c["demurrage_rate"])
            |> maybe_put("penalty_cap", c["penalty_cap"])
            |> maybe_put("period", c["period"])
            |> maybe_put("anchors_matched", c["anchors_matched"] || [])

          %Clause{
            id: Clause.generate_id(),
            clause_id: c["clause_id"],
            type: map_clause_type(c["category"]),
            category: safe_atom(c["category"]),
            description: c["description"] || c["source_text"] || "",
            reference_section: c["section_ref"],
            confidence: safe_atom(c["confidence"] || "high"),
            extracted_fields: Map.put(merged_fields, "source_text", c["source_text"] || ""),
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
      "quantity" -> :obligation
      "delivery_schedule" -> :delivery
      "pricing" -> :price_term
      "payment" -> :payment
      "logistics" -> :delivery
      "quality_spec" -> :compliance
      "penalty" -> :penalty
      "take_or_pay" -> :penalty
      "demurrage" -> :penalty
      "force_majeure" -> :legal
      "insurance" -> :legal
      "legal" -> :legal
      "operational" -> :operational
      "commercial" -> :price_term
      "core_terms" -> :obligation
      "logistics_cost" -> :penalty
      "credit_legal" -> :penalty
      "compliance" -> :compliance
      "metadata" -> :metadata
      _ -> :condition
    end
  end
  defp map_clause_type(_), do: :condition

  defp safe_atom(nil), do: nil
  defp safe_atom(a) when is_atom(a), do: a
  defp safe_atom(s) when is_binary(s), do: String.to_atom(String.downcase(s))

  # ── Delivery schedule generation ─────────────────────────

  @doc """
  Generate delivery schedules from extracted contract clauses.

  Reads all contracts from Postgres, extracts quantity/schedule clauses,
  and creates ScheduledDelivery rows that represent the open delivery
  obligations for each contract.

  Returns `{:ok, %{generated: n, contracts: n}}`.
  """
  def generate_schedules(caller \\ nil) do
    import Ecto.Query
    alias TradingDesk.DB.{ContractRecord, ScheduledDelivery}
    alias TradingDesk.Repo

    notify(caller, {:schedule_progress, :started, "Generating delivery schedules from extracted clauses..."})

    # Clear existing schedules
    Repo.delete_all(ScheduledDelivery)

    # Get all contracts with clauses
    contracts =
      ContractRecord
      |> where([c], is_nil(c.deleted_at))
      |> Repo.all()
      |> Enum.group_by(& &1.counterparty)
      |> Enum.map(fn {_cp, versions} ->
        # Pick version with most clauses
        Enum.max_by(versions, fn v ->
          case v.clauses_data do
            %{"clauses" => cl} when is_list(cl) -> length(cl)
            _ -> 0
          end
        end)
      end)

    today = Date.utc_today()
    total_generated = Enum.reduce(contracts, 0, fn contract, acc ->
      clauses = case contract.clauses_data do
        %{"clauses" => cl} when is_list(cl) -> cl
        _ -> []
      end

      # Extract schedule-relevant data from clauses
      open_qty = contract.open_position || 0
      direction = contract.counterparty_type || "unknown"

      # Find delivery-related clauses
      annual_qty = find_clause_value(clauses, ["ANNUAL_QUANTITY", "QUANTITY", "ACQ"])
      cargo_size = find_clause_value(clauses, ["LIFTING_SIZE", "CARGO_SIZE", "SHIPMENT_SIZE"])
      min_cargoes = find_clause_value(clauses, ["MIN_CARGOES", "MIN_LIFTINGS", "MINIMUM_LIFTINGS"])
      contract_end = find_clause_date(clauses, ["CONTRACT_TERM", "TERM", "EXPIRY"])

      # Determine delivery parameters
      qty_per_delivery = cond do
        cargo_size && cargo_size > 0 -> cargo_size
        annual_qty && annual_qty > 0 and min_cargoes && min_cargoes > 0 ->
          annual_qty / min_cargoes
        open_qty > 50_000 -> 30_000.0  # large contracts: ~30k per cargo
        open_qty > 10_000 -> 5_000.0   # medium: ~5k per delivery
        true -> open_qty / 1.0         # small: single delivery
      end

      qty_per_delivery = if qty_per_delivery == 0, do: open_qty, else: qty_per_delivery

      n_deliveries = if qty_per_delivery > 0,
        do: max(1, round(open_qty / qty_per_delivery)),
        else: 0

      end_date = contract_end || Date.add(today, 365)
      remaining_days = max(Date.diff(end_date, today), 30)
      interval_days = if n_deliveries > 1, do: div(remaining_days, n_deliveries), else: remaining_days

      deliveries = for i <- 1..n_deliveries do
        delivery_qty = if i == n_deliveries do
          # Last delivery gets the remainder
          open_qty - qty_per_delivery * (n_deliveries - 1)
        else
          qty_per_delivery
        end

        required_date = Date.add(today, interval_days * i)

        %{
          contract_id: contract.id,
          contract_hash: contract.id,
          counterparty: contract.counterparty,
          contract_number: contract.contract_number,
          direction: direction,
          product_group: contract.product_group || "ammonia",
          incoterm: contract.incoterm,
          quantity_mt: Float.round(delivery_qty * 1.0, 1),
          required_date: required_date,
          estimated_date: required_date,
          delay_days: 0,
          status: "on_track",
          delivery_index: i,
          total_deliveries: n_deliveries,
          destination: infer_destination(contract),
          notes: "Auto-generated from extracted clauses",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end

      for d <- deliveries do
        %ScheduledDelivery{}
        |> ScheduledDelivery.changeset(d)
        |> Repo.insert()
      end

      notify(caller, {:schedule_progress, :contract_done,
        "#{contract.counterparty}: #{n_deliveries} deliveries, #{format_qty(open_qty)} MT open"})

      acc + length(deliveries)
    end)

    notify(caller, {:schedule_progress, :done,
      "Schedule complete: #{total_generated} deliveries across #{length(contracts)} contracts"})

    {:ok, %{generated: total_generated, contracts: length(contracts)}}
  end

  defp find_clause_value(clauses, ids) do
    clause = Enum.find(clauses, fn c ->
      (c["clause_id"] || "") in ids
    end)

    case clause do
      %{"extracted_fields" => %{"value" => v}} when is_number(v) -> v
      %{"value" => v} when is_number(v) -> v
      _ -> nil
    end
  end

  defp find_clause_date(clauses, ids) do
    clause = Enum.find(clauses, fn c ->
      (c["clause_id"] || "") in ids
    end)

    case clause do
      %{"extracted_fields" => %{"value" => v}} when is_binary(v) ->
        case Date.from_iso8601(v) do
          {:ok, d} -> d
          _ -> nil
        end
      _ -> nil
    end
  end

  defp infer_destination(contract) do
    case contract.incoterm do
      "cfr" -> "Destination port"
      "CFR" -> "Destination port"
      "fob" -> "Loading port"
      "FOB" -> "Loading port"
      "dap" -> "Delivery point"
      "DAP" -> "Delivery point"
      _ -> contract.counterparty
    end
  end

  defp format_qty(n) when is_number(n) do
    n |> round() |> Integer.to_string() |> add_commas()
  end
  defp format_qty(_), do: "0"

  defp add_commas(str) do
    str |> String.reverse() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") |> String.reverse()
  end
end
