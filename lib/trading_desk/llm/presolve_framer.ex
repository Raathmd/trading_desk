defmodule TradingDesk.LLM.PresolveFramer do
  @moduledoc """
  LLM-driven presolve framing: translates contract clauses + live data +
  trader free-text into concrete solver variable adjustments.

  The ConstraintBridge handled two mechanical paths (direct bounds and
  penalty margin). This module replaces that with a local LLM call that
  can reason about:

    - Formula-based pricing ("NOLA spot + $15 premium")
    - Conditional triggers ("if river stage < 5ft, price escalates")
    - Cross-clause interactions (volume + penalty + delivery window)
    - User free-text instructions ("be conservative on Memphis")
    - Time-dependent terms (Q1 vs Q2 pricing)
    - Soft vs hard constraints
    - Market context visible in current variable values

  ## Flow

      active contracts + current variables + trader notes
        │
        ▼
      LLM prompt (system + user)
        │
        ▼
      JSON response: {adjustments: [...], warnings: [...]}
        │
        ▼
      Apply adjustments to variable map → return framed variables

  Falls back to mechanical ConstraintBridge if LLM is unavailable.
  """

  require Logger

  alias TradingDesk.LLM.Pool
  alias TradingDesk.Contracts.{Store, Clause}
  alias TradingDesk.ProductGroup

  @default_model :mistral_7b

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Frame solver variables using LLM reasoning over contracts and trader notes.

  Takes current variable values and returns adjusted values with a framing
  report. The LLM sees all active contract clauses, current variable values,
  the solver frame definition, and any trader free-text instructions.

  Options:
    :product_group  — which contracts to load (default: :ammonia_domestic)
    :trader_notes   — free-text instructions from the trader (default: nil)
    :model_id       — which LLM model to use (default: :mistral_7b)

  Returns:
    {:ok, %{variables: adjusted_map, adjustments: [...], warnings: [...], framing_notes: string}}
    {:error, reason}
  """
  @spec frame(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def frame(variables, opts \\ []) when is_map(variables) do
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)
    trader_notes = Keyword.get(opts, :trader_notes)
    model_id = Keyword.get(opts, :model_id, @default_model)

    active_contracts = Store.get_active_set(product_group)
    clauses = extract_all_clauses(active_contracts)

    if length(clauses) == 0 and is_nil(trader_notes) do
      Logger.info("PresolveFramer: no active clauses or trader notes — skipping framing")
      {:ok, %{variables: variables, adjustments: [], warnings: [], framing_notes: "No contracts or trader notes to frame."}}
    else
      prompt = build_prompt(variables, clauses, active_contracts, product_group, trader_notes)

      case call_llm(model_id, prompt) do
        {:ok, response} ->
          apply_framing(variables, response, product_group)

        {:error, reason} ->
          Logger.warning("PresolveFramer: LLM unavailable (#{inspect(reason)}), falling back to ConstraintBridge")
          fallback_mechanical(variables, product_group)
      end
    end
  end

  @doc """
  Preview what the framer would do without actually applying changes.
  Returns the raw LLM framing response.
  """
  @spec preview(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview(variables, opts \\ []) when is_map(variables) do
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)
    trader_notes = Keyword.get(opts, :trader_notes)
    model_id = Keyword.get(opts, :model_id, @default_model)

    active_contracts = Store.get_active_set(product_group)
    clauses = extract_all_clauses(active_contracts)
    prompt = build_prompt(variables, clauses, active_contracts, product_group, trader_notes)

    call_llm(model_id, prompt)
  end

  # ──────────────────────────────────────────────────────────
  # LLM CALL
  # ──────────────────────────────────────────────────────────

  defp call_llm(model_id, prompt) do
    case Pool.generate(model_id, prompt, max_tokens: 1024) do
      {:ok, text} -> parse_llm_response(text)
      {:error, _} = err -> err
    end
  end

  defp parse_llm_response(text) do
    # Extract JSON from the response (LLM may wrap it in markdown fences)
    json_str = extract_json(text)

    case Jason.decode(json_str) do
      {:ok, %{"adjustments" => adjustments} = parsed} when is_list(adjustments) ->
        {:ok, parsed}

      {:ok, _} ->
        Logger.warning("PresolveFramer: LLM response missing 'adjustments' key")
        {:error, :invalid_response_format}

      {:error, reason} ->
        Logger.warning("PresolveFramer: failed to parse LLM JSON: #{inspect(reason)}")
        {:error, {:json_parse_failed, reason}}
    end
  end

  defp extract_json(text) do
    # Try to find JSON object in the response
    case Regex.run(~r/\{[\s\S]*\}/, text) do
      [json] -> json
      _ -> text
    end
  end

  # ──────────────────────────────────────────────────────────
  # PROMPT CONSTRUCTION
  # ──────────────────────────────────────────────────────────

  defp build_prompt(variables, clauses, contracts, product_group, trader_notes) do
    frame_desc = frame_description(product_group)
    vars_desc = variables_description(variables, product_group)
    clauses_desc = clauses_description(clauses, contracts)
    notes_section = if trader_notes, do: "\n## Trader Instructions\n#{trader_notes}\n", else: ""

    """
    You are a presolve framing engine for Trammo's commodity trading LP solver.
    Your job is to read active contract clauses, current market data, and trader
    instructions, then produce concrete variable adjustments for the solver.

    ## Solver Frame
    #{frame_desc}

    ## Current Variable Values
    #{vars_desc}

    ## Active Contract Clauses
    #{clauses_desc}
    #{notes_section}
    ## Rules

    1. Output ONLY a JSON object — no explanation text before or after.
    2. Each adjustment sets a solver variable to a specific numeric value.
    3. Adjustments can only TIGHTEN constraints (raise floors, lower ceilings).
       Never loosen a variable beyond its current value unless the trader
       explicitly instructs otherwise.
    4. For penalty clauses: reduce the relevant sell price by the weighted-average
       penalty exposure per ton. Cap the reduction at 10% of the current sell price.
    5. For price-fixing clauses: set the variable to the contract price.
    6. For volume constraints: raise the floor or lower the ceiling as specified.
    7. For formula-based pricing: compute the value using current variable values.
    8. If trader instructions conflict with contract terms, note the conflict
       in warnings but follow the contract (contracts are legally binding).
    9. Include a brief reason for each adjustment.

    ## Output Format

    {
      "adjustments": [
        {
          "variable": "nola_buy",
          "value": 340.00,
          "reason": "Koch purchase contract fixes NOLA buy at $340/ton (clause PRICE_TERM)"
        }
      ],
      "warnings": [
        "string warnings about conflicts, expiring contracts, or risks"
      ],
      "framing_notes": "Brief summary of overall framing rationale"
    }

    If no adjustments are needed, return {"adjustments": [], "warnings": [], "framing_notes": "No adjustments needed."}.
    """
  end

  defp frame_description(product_group) do
    vars = ProductGroup.variables(product_group)
    routes = ProductGroup.routes(product_group)
    constraints = ProductGroup.constraints(product_group)

    var_lines = Enum.map(vars, fn v ->
      "  #{v[:key]} (#{v[:label]}): #{v[:unit]}, range [#{v[:min]}..#{v[:max]}], source: #{v[:source]}"
    end)

    route_lines = Enum.map(routes, fn r ->
      "  #{r[:key]}: #{r[:name]} — buy=#{r[:buy_variable]}, sell=#{r[:sell_variable]}, freight=#{r[:freight_variable]}"
    end)

    constraint_lines = Enum.map(constraints, fn c ->
      "  #{c[:key]}: #{c[:name]} (#{c[:type]})"
    end)

    """
    Variables:
    #{Enum.join(var_lines, "\n")}

    Routes:
    #{Enum.join(route_lines, "\n")}

    Constraints:
    #{Enum.join(constraint_lines, "\n")}
    """
  end

  defp variables_description(variables, product_group) do
    keys = ProductGroup.variable_keys(product_group)

    keys
    |> Enum.map(fn key ->
      val = Map.get(variables, key)
      "  #{key} = #{inspect(val)}"
    end)
    |> Enum.join("\n")
  end

  defp clauses_description(clauses, contracts) do
    if length(clauses) == 0 do
      "No active contract clauses."
    else
      # Group clauses by counterparty for readability
      counterparty_map = Map.new(contracts, fn c -> {c.id, c.counterparty} end)

      clauses
      |> Enum.map(fn {contract_id, clause} ->
        cp = Map.get(counterparty_map, contract_id, "Unknown")
        ef = clause.extracted_fields || %{}

        fields_str = ef
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
          |> Enum.join(", ")

        "  [#{cp}] #{clause.clause_id || clause.type}: #{truncate(clause.description, 120)} | #{fields_str}"
      end)
      |> Enum.join("\n")
    end
  end

  # ──────────────────────────────────────────────────────────
  # APPLY FRAMING
  # ──────────────────────────────────────────────────────────

  defp apply_framing(variables, %{"adjustments" => adjustments} = response, product_group) do
    valid_keys = ProductGroup.variable_keys(product_group) |> MapSet.new()

    {adjusted_vars, applied} =
      Enum.reduce(adjustments, {variables, []}, fn adj, {vars, acc} ->
        key_str = adj["variable"]
        value = adj["value"]
        reason = adj["reason"]

        key = safe_to_atom(key_str)

        cond do
          is_nil(key) or not MapSet.member?(valid_keys, key) ->
            Logger.warning("PresolveFramer: ignoring unknown variable '#{key_str}'")
            {vars, acc}

          not is_number(value) ->
            Logger.warning("PresolveFramer: ignoring non-numeric value for #{key_str}: #{inspect(value)}")
            {vars, acc}

          true ->
            current = Map.get(vars, key)
            rounded = if is_float(value), do: Float.round(value, 2), else: value

            applied_entry = %{
              variable: key,
              original: current,
              adjusted: rounded,
              reason: reason
            }

            {Map.put(vars, key, rounded), [applied_entry | acc]}
        end
      end)

    warnings = Map.get(response, "warnings", [])
    framing_notes = Map.get(response, "framing_notes", "")

    Logger.info("PresolveFramer: applied #{length(applied)} adjustment(s), #{length(warnings)} warning(s)")

    {:ok, %{
      variables: adjusted_vars,
      adjustments: Enum.reverse(applied),
      warnings: warnings,
      framing_notes: framing_notes
    }}
  end

  # ──────────────────────────────────────────────────────────
  # FALLBACK: MECHANICAL CONSTRAINT BRIDGE
  # ──────────────────────────────────────────────────────────

  defp fallback_mechanical(variables, product_group) do
    active = Store.get_active_set(product_group)

    {adjusted_vars, applied} =
      Enum.reduce(active, {variables, []}, fn contract, {vars, acc} ->
        apply_contract_mechanical(vars, contract, acc)
      end)

    {adjusted_vars, penalty_applied} =
      apply_penalty_mechanical(adjusted_vars, active)

    all_applied = applied ++ penalty_applied

    if length(all_applied) > 0 do
      Logger.info("PresolveFramer fallback: applied #{length(all_applied)} mechanical constraint(s)")
    end

    {:ok, %{
      variables: adjusted_vars,
      adjustments: Enum.map(all_applied, fn a ->
        %{variable: a[:parameter], original: a[:original], adjusted: a[:applied], reason: "mechanical fallback"}
      end),
      warnings: ["LLM unavailable — using mechanical constraint application only"],
      framing_notes: "Fallback: mechanical ConstraintBridge logic (direct bounds + penalty margin)"
    }}
  end

  defp apply_contract_mechanical(vars, contract, applied) do
    (contract.clauses || [])
    |> Enum.filter(fn clause ->
      Clause.parameter(clause) != nil and Clause.operator(clause) != nil
    end)
    |> Enum.reduce({vars, applied}, fn clause, {v, acc} ->
      param = Clause.parameter(clause)
      current = Map.get(v, param)

      if is_nil(current) do
        {v, acc}
      else
        new_value = compute_bound(clause, current)

        if new_value != current do
          {Map.put(v, param, new_value),
           [%{parameter: param, original: current, applied: new_value,
              counterparty: contract.counterparty, clause_id: clause.clause_id} | acc]}
        else
          {v, acc}
        end
      end
    end)
  end

  defp compute_bound(clause, current) do
    op = Clause.operator(clause)
    val = Clause.value(clause)

    case op do
      :>= when is_number(val) -> max(current, val)
      :<= when is_number(val) -> min(current, val)
      :== when is_number(val) -> val
      :between ->
        upper = Clause.value_upper(clause)
        if is_number(val) and is_number(upper) do
          current |> max(val) |> min(upper)
        else
          current
        end
      _ -> current
    end
  end

  defp apply_penalty_mechanical(vars, contracts) do
    # Weighted-average penalty reduction on sell prices
    {stl_num, stl_den, mem_num, mem_den} =
      Enum.reduce(contracts, {0.0, 0.0, 0.0, 0.0}, fn contract, acc ->
        if contract.counterparty_type == :customer do
          penalties = extract_penalties(contract)
          rate = Enum.reduce(penalties, 0.0, fn {_type, r}, a -> a + r end)
          open = max(contract.open_position || 0, 0) / 1.0

          if rate > 0 and open > 0 do
            {sn, sd, mn, md} = acc
            # Split equally when destination unknown
            half = open / 2.0
            {sn + half * rate, sd + half, mn + half * rate, md + half}
          else
            acc
          end
        else
          acc
        end
      end)

    stl_reduction = if stl_den > 0, do: Float.round(stl_num / stl_den, 2), else: 0.0
    mem_reduction = if mem_den > 0, do: Float.round(mem_num / mem_den, 2), else: 0.0

    sell_stl = Map.get(vars, :sell_stl)
    sell_mem = Map.get(vars, :sell_mem)
    stl_adj = if is_number(sell_stl), do: min(stl_reduction, sell_stl * 0.10), else: 0.0
    mem_adj = if is_number(sell_mem), do: min(mem_reduction, sell_mem * 0.10), else: 0.0

    Enum.reduce(
      [{:sell_stl, stl_adj}, {:sell_mem, mem_adj}],
      {vars, []},
      fn {param, adj}, {v, acc} ->
        current = Map.get(v, param)
        if is_number(current) and adj > 0 do
          new_val = Float.round(current - adj, 2)
          {Map.put(v, param, new_val),
           [%{parameter: param, original: current, applied: new_val,
              counterparty: "penalty_adjustment", clause_id: "PENALTY_MARGIN"} | acc]}
        else
          {v, acc}
        end
      end
    )
  end

  defp extract_penalties(contract) do
    (contract.clauses || [])
    |> Enum.filter(fn clause ->
      rate = Clause.penalty_per_unit(clause)
      is_number(rate) and rate > 0
    end)
    |> Enum.map(fn clause ->
      {clause.clause_id || "general_penalty", Clause.penalty_per_unit(clause)}
    end)
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp extract_all_clauses(contracts) do
    Enum.flat_map(contracts, fn contract ->
      (contract.clauses || [])
      |> Enum.map(fn clause -> {contract.id, clause} end)
    end)
  end

  defp truncate(nil, _), do: ""
  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str
  defp truncate(str, max_len), do: String.slice(str, 0, max_len) <> "..."

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> nil
    end
  end
  defp safe_to_atom(a) when is_atom(a), do: a
end
