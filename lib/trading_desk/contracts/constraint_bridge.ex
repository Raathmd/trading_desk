defmodule TradingDesk.Contracts.ConstraintBridge do
  @moduledoc """
  Bridges approved contract clauses into solver variable bounds.

  Takes the active set of approved contracts for a product group and
  translates their clauses into modifications to the Variables struct
  that gets passed to the Zig solver via Port.

  Only approved, SAP-validated, non-expired contracts with loaded
  open positions are used. The Readiness gate must pass first.

  Contract clauses modify solver inputs in two paths:

    1. **Direct bounds** — clauses where the LLM mapped a solver variable
       + operator + value. These tighten variable bounds (floor, ceiling,
       fixed, or range). A clause is "applicable" when it has both a
       non-nil parameter and a non-nil operator.

    2. **Penalty margin adjustment** — clauses with a penalty_per_unit rate
       (demurrage, volume shortfall, late delivery, take-or-pay, etc.).
       These reduce effective sell prices by the weighted-average penalty
       exposure per ton, capped at 10% of current sell price. Any clause
       the LLM sets penalty_per_unit on flows through this path — no
       hardcoded clause_id list.

  This module never loosens constraints — it only tightens them.
  If a contract says minimum 5,000 tons and the trader set 3,000,
  the contract wins (floor is raised to 5,000).
  """

  alias TradingDesk.Contracts.{Store, Readiness, Contract, Clause}
  alias TradingDesk.Variables

  require Logger

  @doc """
  Apply active contract constraints to a Variables struct.

  Returns {:ok, modified_vars, applied_clauses} if readiness passes.
  Returns {:not_ready, issues, report} if the product group isn't ready.
  """
  def apply_constraints(%Variables{} = vars, product_group) do
    case Readiness.check(product_group) do
      {:ready, _report} ->
        active = Store.get_active_set(product_group)
        {modified_vars, applied} = apply_active_contracts(vars, active)

        if length(applied) > 0 do
          Logger.info(
            "Applied #{length(applied)} contract constraint(s) for #{product_group}"
          )
        end

        {:ok, modified_vars, applied}

      {:not_ready, issues, report} ->
        {:not_ready, issues, report}
    end
  end

  @doc """
  Same as apply_constraints/2 but does not enforce readiness gate.
  Use only for what-if analysis, never for live trading decisions.
  """
  def apply_constraints_unchecked(%Variables{} = vars, product_group) do
    active = Store.get_active_set(product_group)
    {modified_vars, applied} = apply_active_contracts(vars, active)
    {:ok, modified_vars, applied}
  end

  @doc """
  Show what constraints would be applied without actually applying them.
  Useful for the UI to preview contract impact.
  """
  def preview_constraints(%Variables{} = vars, product_group) do
    active = Store.get_active_set(product_group)

    Enum.flat_map(active, fn contract ->
      (contract.clauses || [])
      |> Enum.filter(&applicable?/1)
      |> Enum.map(fn clause ->
        param = Clause.parameter(clause)
        current = get_variable(vars, param)
        proposed = compute_bound(clause, current)

        %{
          counterparty: contract.counterparty,
          clause_type: clause.type,
          parameter: param,
          operator: Clause.operator(clause),
          clause_value: Clause.value(clause),
          current_value: current,
          proposed_value: proposed,
          would_change: current != proposed,
          penalty_exposure: Clause.penalty_per_unit(clause)
        }
      end)
    end)
  end

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Build the penalty schedule: per-counterparty penalty exposure from
  all active contracts. The solver uses this to reduce effective margin
  on routes that risk triggering penalties.

  Returns a list of:
    %{counterparty, penalty_type, rate_per_ton, open_qty, max_exposure,
      incoterm, direction}
  """
  def penalty_schedule(product_group) do
    active = Store.get_active_set(product_group)

    Enum.flat_map(active, fn contract ->
      penalties = extract_penalty_clauses(contract)
      incoterm = extract_incoterm(contract)
      open_qty = contract.open_position || 0

      Enum.map(penalties, fn {penalty_type, rate} ->
        %{
          counterparty: contract.counterparty,
          counterparty_type: contract.counterparty_type,
          penalty_type: penalty_type,
          rate_per_ton: rate,
          open_qty: open_qty,
          max_exposure: rate * open_qty,
          incoterm: incoterm,
          direction: contract.template_type,
          family_id: contract.family_id
        }
      end)
    end)
  end

  @doc """
  Compute the aggregate open book for Trammo across all active contracts.

  Returns:
    %{
      total_purchase_obligation: float,  # MT still owed to Trammo by suppliers
      total_sale_obligation: float,      # MT Trammo still owes to customers
      net_open_position: float,          # purchase - sale (positive = long)
      by_counterparty: [%{counterparty, direction, incoterm, contract_qty,
                          open_qty, penalty_exposure}],
      total_penalty_exposure: float      # worst-case penalty across all contracts
    }
  """
  def aggregate_open_book(product_group) do
    active = Store.get_active_set(product_group)

    by_counterparty =
      Enum.map(active, fn contract ->
        incoterm = extract_incoterm(contract)
        contract_qty = extract_contract_qty(contract)
        open_qty = contract.open_position || 0
        penalties = extract_penalty_clauses(contract)
        penalty_exposure = Enum.reduce(penalties, 0.0, fn {_type, rate}, acc ->
          acc + rate * abs(open_qty)
        end)

        direction = case contract.counterparty_type do
          :supplier -> :purchase
          :customer -> :sale
          _ -> contract.template_type
        end

        %{
          counterparty: contract.counterparty,
          direction: direction,
          incoterm: incoterm,
          term_type: contract.term_type,
          contract_qty: contract_qty,
          open_qty: open_qty,
          penalty_exposure: penalty_exposure,
          family_id: contract.family_id
        }
      end)

    purchases = Enum.filter(by_counterparty, &(&1.direction == :purchase))
    sales = Enum.filter(by_counterparty, &(&1.direction == :sale))

    total_purchase = Enum.reduce(purchases, 0.0, &(&1.open_qty + &2))
    total_sale = Enum.reduce(sales, 0.0, &(&1.open_qty + &2))
    total_penalty = Enum.reduce(by_counterparty, 0.0, &(&1.penalty_exposure + &2))

    %{
      total_purchase_obligation: total_purchase,
      total_sale_obligation: total_sale,
      net_open_position: total_purchase - total_sale,
      by_counterparty: by_counterparty,
      total_penalty_exposure: total_penalty
    }
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: apply all active contracts
  # ──────────────────────────────────────────────────────────

  # --- Private: apply all active contracts ---

  defp apply_active_contracts(vars, contracts) do
    {vars_after_clauses, applied} =
      Enum.reduce(contracts, {vars, []}, fn contract, {v, acc} ->
        apply_contract(v, contract, acc)
      end)

    {vars_after_penalty, penalty_applied} =
      apply_penalty_margin_adjustment(vars_after_clauses, contracts)

    {vars_after_penalty, applied ++ penalty_applied}
  end

  # Reduce effective sell prices by the weighted-average penalty exposure per ton.
  # For each active sale contract with volume-shortfall or late-delivery penalties:
  #   reduction_$/ton = sum(open_qty * rate) / sum(open_qty)
  # This bakes contract risk into the LP margin so the solver avoids routes
  # that would trigger penalties.
  defp apply_penalty_margin_adjustment(vars, contracts) do
    {stl_num, stl_den, mem_num, mem_den} =
      Enum.reduce(contracts, {0.0, 0.0, 0.0, 0.0}, fn contract, acc ->
        if contract.counterparty_type == :customer do
          penalties = extract_penalty_clauses(contract)
          rate = Enum.reduce(penalties, 0.0, fn {_type, r}, a -> a + r end)
          open = max(contract.open_position || 0, 0) / 1.0

          if rate > 0 and open > 0 do
            dest = penalty_destination(contract)
            {sn, sd, mn, md} = acc

            case dest do
              :stl -> {sn + open * rate, sd + open, mn, md}
              :mem -> {sn, sd, mn + open * rate, md + open}
              _ ->
                # Unknown destination — split equally
                half = open / 2.0
                {sn + half * rate, sd + half, mn + half * rate, md + half}
            end
          else
            acc
          end
        else
          acc
        end
      end)

    stl_reduction = if stl_den > 0, do: Float.round(stl_num / stl_den, 2), else: 0.0
    mem_reduction = if mem_den > 0, do: Float.round(mem_num / mem_den, 2), else: 0.0

    # Cap reductions at 10% of current sell price to avoid over-penalising
    sell_stl = get_variable(vars, :sell_stl)
    sell_mem = get_variable(vars, :sell_mem)
    stl_adj = if is_number(sell_stl), do: min(stl_reduction, sell_stl * 0.10), else: 0.0
    mem_adj = if is_number(sell_mem), do: min(mem_reduction, sell_mem * 0.10), else: 0.0

    {vars_out, applied} =
      Enum.reduce(
        [{:sell_stl, stl_adj}, {:sell_mem, mem_adj}],
        {vars, []},
        fn {param, adj}, {v, acc} ->
          current = get_variable(v, param)

          if is_number(current) and adj > 0 do
            new_val = Float.round(current - adj, 2)
            {set_variable(v, param, new_val),
             [%{
               counterparty: "penalty_adjustment",
               clause_id: "PENALTY_MARGIN",
               parameter: param,
               original: current,
               applied: new_val
             } | acc]}
          else
            {v, acc}
          end
        end
      )

    Logger.debug(
      "ConstraintBridge: penalty margin — sell_stl -#{stl_adj}/t, sell_mem -#{mem_adj}/t"
    )

    {vars_out, applied}
  end

  # Guess delivery destination for a customer contract from name/family_id
  defp penalty_destination(%{counterparty: name, family_id: fid}) do
    n = String.downcase(name || "")
    f = to_string(fid || "")

    cond do
      String.contains?(n, "stl") or String.contains?(n, "st. louis") or
        String.contains?(n, "nutrien") or String.contains?(f, "stl") or
        String.contains?(f, "st_louis") -> :stl
      String.contains?(n, "mem") or String.contains?(n, "memphis") or
        String.contains?(n, "koch") or String.contains?(f, "mem") -> :mem
      true -> :unknown
    end
  end

  defp apply_contract(vars, %Contract{} = contract, applied) do
    (contract.clauses || [])
    |> Enum.filter(&applicable?/1)
    |> Enum.reduce({vars, applied}, fn clause, {v, acc} ->
      param = Clause.parameter(clause)

      case apply_clause(v, clause) do
        {:changed, new_vars} ->
          {new_vars, [%{
            counterparty: contract.counterparty,
            clause_id: clause.id,
            parameter: param,
            original: get_variable(v, param),
            applied: get_variable(new_vars, param)
          } | acc]}

        :unchanged ->
          {v, acc}
      end
    end)
  end

  # --- Clause application logic ---
  # Reads solver fields from Clause accessor helpers (which read from extracted_fields).

  defp apply_clause(vars, clause) do
    param = Clause.parameter(clause)
    current = get_variable(vars, param)

    if is_nil(current) do
      :unchanged
    else
      new_value = compute_bound(clause, current)

      if new_value != current do
        {:changed, set_variable(vars, param, new_value)}
      else
        :unchanged
      end
    end
  end

  # Contract constraints only tighten, never loosen.
  # Reads operator/value from Clause accessor helpers.
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

  # A clause is applicable for direct variable binding when the LLM
  # provided both a solver parameter and an operator in extracted_fields.
  defp applicable?(clause) do
    Clause.parameter(clause) != nil and Clause.operator(clause) != nil
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS — extract structured data from contracts
  # ──────────────────────────────────────────────────────────

  defp extract_incoterm(%Contract{incoterm: incoterm}) when not is_nil(incoterm), do: incoterm
  defp extract_incoterm(%Contract{clauses: clauses}) when is_list(clauses) do
    case Enum.find(clauses, &(&1.clause_id == "INCOTERMS")) do
      %{extracted_fields: %{"incoterm_rule" => rule}} when is_binary(rule) ->
        rule |> String.downcase() |> String.to_atom()
      _ -> nil
    end
  end
  defp extract_incoterm(_), do: nil

  defp extract_contract_qty(%Contract{clauses: clauses}) when is_list(clauses) do
    case Enum.find(clauses, &(&1.clause_id == "QUANTITY_TOLERANCE")) do
      clause when not is_nil(clause) ->
        case Clause.value(clause) do
          qty when is_number(qty) -> qty
          _ -> 0.0
        end
      _ -> 0.0
    end
  end
  defp extract_contract_qty(_), do: 0.0

  # Extract all penalty clauses by matching on penalty_per_unit field.
  # The LLM sets penalty_per_unit on any clause with a penalty/demurrage rate.
  # No hardcoded clause_id list — works with any clause type the LLM identifies.
  defp extract_penalty_clauses(%Contract{clauses: clauses}) when is_list(clauses) do
    clauses
    |> Enum.filter(fn clause ->
      rate = Clause.penalty_per_unit(clause)
      is_number(rate) and rate > 0
    end)
    |> Enum.map(fn clause ->
      penalty_type = clause_id_to_penalty_type(clause.clause_id)
      {penalty_type, Clause.penalty_per_unit(clause)}
    end)
  end
  defp extract_penalty_clauses(_), do: []

  # Best-effort penalty type classification from clause_id.
  # Falls back to :general_penalty for clause types the LLM discovers
  # that we don't have a specific category for.
  defp clause_id_to_penalty_type(nil), do: :general_penalty
  defp clause_id_to_penalty_type(clause_id) when is_binary(clause_id) do
    id = String.upcase(clause_id)
    cond do
      String.contains?(id, "TAKE_OR_PAY") -> :take_or_pay
      String.contains?(id, "VOLUME_SHORTFALL") -> :volume_shortfall
      String.contains?(id, "LATE_DELIVERY") -> :late_delivery
      String.contains?(id, "DEMURRAGE") or String.contains?(id, "LAYTIME") -> :demurrage
      String.contains?(id, "DELAY") -> :delay_penalty
      true -> :general_penalty
    end
  end

  # --- Variable access helpers ---

  # Solver variables come from the product group frame config.
  # For backward compatibility, also accept the ammonia_domestic hardcoded list.
  @legacy_solver_variables [
    :river_stage, :lock_hrs, :temp_f, :wind_mph, :vis_mi, :precip_in,
    :inv_mer, :inv_nio, :mer_outage, :nio_outage, :barge_count,
    # contract-derived supply floor (not in legacy binary, but readable for bridge logic)
    :committed_lift_mer,
    :nola_buy, :sell_stl, :sell_mem, :fr_mer_stl, :fr_mer_mem,
    :fr_nio_stl, :fr_nio_mem, :nat_gas, :working_cap
  ]

  defp get_variable(%Variables{} = vars, param) when param in @legacy_solver_variables do
    Map.get(vars, param)
  end
  # Dynamic variable maps (any product group)
  defp get_variable(vars, param) when is_map(vars) and is_atom(param) do
    Map.get(vars, param)
  end
  defp get_variable(_, _), do: nil

  defp set_variable(%Variables{} = vars, param, value) when param in @legacy_solver_variables do
    Map.put(vars, param, value)
  end
  # Dynamic variable maps (any product group)
  defp set_variable(vars, param, value) when is_map(vars) and is_atom(param) do
    Map.put(vars, param, value)
  end
  defp set_variable(vars, _, _), do: vars
end
