defmodule TradingDesk.Seeds.NH3ContractSeedTest do
  @moduledoc """
  Tests the 5 NH3 seed contracts against the default ammonia solver variables.

  Two layers of validation:

    1. **Structure** — each contract has correct metadata, family ID, clause counts,
       and every LP-relevant clause is wired with a parameter, operator, and value.

    2. **Constraint satisfaction** — each LP clause is evaluated against the
       default `%Variables{}` seed values, answering: "given today's market and
       operational defaults, which contract constraints are met?"

  ## Operator semantics used by this test

    :<=       variable_value <= clause.value       (price ceiling, delay ceiling)
    :>=       variable_value >= clause.value       (price floor, inventory floor, stage floor)
    :between  variable_value >= clause.value       (inventory can cover minimum shipment)
    :==       variable_value == clause.value (float) or boolean match (trigger condition)

  FORCE_MAJEURE clauses use :== with value 1.0 — a satisfied constraint means
  FM IS triggered (bad for operations). Not satisfied = normal operations (desired).

  PRODUCT_AND_SPECS maps to :temp_f (<= -27.0). In normal operations the ambient
  temperature is always above -27°F, so this constraint is always "not met" in the
  solver sense. It flags that refrigeration is always required (expected behaviour).
  """

  use ExUnit.Case, async: true

  alias TradingDesk.Seeds.NH3ContractSeed
  alias TradingDesk.Variables

  # Default ammonia seed variables (mirrors Variables defstruct defaults)
  @vars %Variables{}

  # ────────────────────────────────────────────────────────────
  # SETUP
  # ────────────────────────────────────────────────────────────

  setup_all do
    contracts = NH3ContractSeed.seed_contracts()
    %{contracts: contracts}
  end

  # ────────────────────────────────────────────────────────────
  # 1. PORTFOLIO STRUCTURE
  # ────────────────────────────────────────────────────────────

  describe "portfolio structure" do
    test "returns exactly 5 contracts", %{contracts: contracts} do
      assert length(contracts) == 5
    end

    test "all contracts are for product_group :ammonia", %{contracts: contracts} do
      assert Enum.all?(contracts, fn c -> c.product_group == :ammonia end)
    end

    test "2 suppliers and 3 customers", %{contracts: contracts} do
      suppliers = Enum.count(contracts, fn c -> c.counterparty_type == :supplier end)
      customers = Enum.count(contracts, fn c -> c.counterparty_type == :customer end)
      assert suppliers == 2
      assert customers == 3
    end

    test "each contract has a family_id", %{contracts: contracts} do
      assert Enum.all?(contracts, fn c -> is_binary(c.family_id) and c.family_id != "" end)
    end

    test "expected family IDs are present", %{contracts: contracts} do
      family_ids = Enum.map(contracts, & &1.family_id) |> MapSet.new()

      assert MapSet.member?(family_ids, "LONG_TERM_PURCHASE_FOB")
      assert MapSet.member?(family_ids, "VESSEL_SPOT_PURCHASE")
      assert MapSet.member?(family_ids, "DOMESTIC_MULTIMODAL_SALE")
    end

    test "each contract has at least one LP-relevant clause", %{contracts: contracts} do
      Enum.each(contracts, fn contract ->
        lp_clauses = lp_clauses(contract)
        assert length(lp_clauses) > 0,
               "#{contract.counterparty} has no LP-relevant clauses"
      end)
    end

    test "LP clause solver variables cover all commercial variables", %{contracts: contracts} do
      all_params =
        contracts
        |> Enum.flat_map(&lp_clauses/1)
        |> Enum.map(& &1.parameter)
        |> MapSet.new()

      # Every commercial variable should appear as a constraint in at least one contract
      assert MapSet.member?(all_params, :nola_buy),    "nola_buy not covered"
      assert MapSet.member?(all_params, :sell_stl),    "sell_stl not covered"
      assert MapSet.member?(all_params, :sell_mem),    "sell_mem not covered"
      assert MapSet.member?(all_params, :working_cap), "working_cap not covered"
      assert MapSet.member?(all_params, :inv_mer),     "inv_mer not covered"
      assert MapSet.member?(all_params, :inv_nio),    "inv_nio not covered"
      assert MapSet.member?(all_params, :lock_hrs),    "lock_hrs not covered"
      assert MapSet.member?(all_params, :river_stage), "river_stage not covered"
      assert MapSet.member?(all_params, :barge_count), "barge_count not covered"
      assert MapSet.member?(all_params, :temp_f),      "temp_f not covered"
      assert MapSet.member?(all_params, :mer_outage),  "mer_outage not covered"
    end
  end

  # ────────────────────────────────────────────────────────────
  # 2. CF INDUSTRIES — LONG_TERM_PURCHASE_FOB
  # ────────────────────────────────────────────────────────────

  describe "CF Industries Holdings — LONG_TERM_PURCHASE_FOB" do
    setup %{contracts: contracts} do
      c = find_contract(contracts, "CF Industries Holdings, Inc.")
      %{contract: c}
    end

    test "metadata", %{contract: c} do
      assert c.counterparty_type == :supplier
      assert c.template_type     == :purchase
      assert c.incoterm          == :fob
      assert c.term_type         == :long_term
      assert c.family_id         == "LONG_TERM_PURCHASE_FOB"
      assert c.contract_number   == "TRAMMO-LTP-2026-0001"
      assert c.sap_contract_id   == "4700001001"
      assert c.open_position     == 42_000.0
      assert c.sap_validated     == true
    end

    test "template validation is 100% complete", %{contract: c} do
      assert c.template_validation["completeness_pct"] == 100.0
      assert c.template_validation["missing"] == []
    end

    # LP clause mappings
    test "PRICE → :nola_buy :<= 365.0", %{contract: c} do
      cl = find_clause(c, "PRICE")
      assert cl.parameter == :nola_buy
      assert cl.operator  == :<=
      assert cl.value     == 365.0
      assert cl.unit      == "$/MT"
    end

    test "QUANTITY_TOLERANCE → :inv_mer :between 10000 and 12000", %{contract: c} do
      cl = find_clause(c, "QUANTITY_TOLERANCE")
      assert cl.parameter  == :inv_mer
      assert cl.operator   == :between
      assert cl.value      == 10_000.0
      assert cl.value_upper == 12_000.0
      assert cl.unit       == "MT"
    end

    test "LAYTIME_DEMURRAGE → :lock_hrs :<= 24.0, penalty $937.50/hr", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert cl.parameter       == :lock_hrs
      assert cl.operator        == :<=
      assert cl.value           == 24.0
      assert cl.penalty_per_unit == 937.50
      assert cl.penalty_cap     == 112_500.0
    end

    test "PORTS_AND_SAFE_BERTH → :river_stage :>= 9.0 ft", %{contract: c} do
      cl = find_clause(c, "PORTS_AND_SAFE_BERTH")
      assert cl.parameter == :river_stage
      assert cl.operator  == :>=
      assert cl.value     == 9.0
    end

    test "PAYMENT → :working_cap :>= 4_015_000", %{contract: c} do
      cl = find_clause(c, "PAYMENT")
      assert cl.parameter == :working_cap
      assert cl.operator  == :>=
      assert cl.value     == 4_015_000.0
    end

    test "DATES_WINDOWS_NOMINATIONS → :barge_count :>= 3", %{contract: c} do
      cl = find_clause(c, "DATES_WINDOWS_NOMINATIONS")
      assert cl.parameter == :barge_count
      assert cl.operator  == :>=
      assert cl.value     == 3.0
    end

    # Constraint satisfaction with default variables
    test "constraint: PRICE — nola_buy 320.0 <= cap 365.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "PRICE")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: QUANTITY_TOLERANCE — inv_mer 12000 covers minimum 10000 [PASS]", %{contract: c} do
      cl = find_clause(c, "QUANTITY_TOLERANCE")
      # :between check: inventory can cover minimum shipment
      assert @vars.inv_mer >= cl.value,
             "inv_mer #{@vars.inv_mer} < minimum shipment #{cl.value}"
    end

    test "constraint: LAYTIME_DEMURRAGE — lock_hrs 12.0 <= free 24.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PORTS_AND_SAFE_BERTH — river_stage 18.0 >= min 9.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "PORTS_AND_SAFE_BERTH")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PAYMENT — working_cap 4_200_000 >= LC 4_015_000 [PASS]", %{contract: c} do
      cl = find_clause(c, "PAYMENT")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PRODUCT_AND_SPECS — ambient temp 45°F does not meet storage requirement -27°F [refrigeration required]", %{contract: c} do
      cl = find_clause(c, "PRODUCT_AND_SPECS")
      # In normal operations ambient temp is always > -27°F.
      # This constraint is intentionally not satisfied — it flags that
      # refrigerated storage is always required for NH3. Not a violation.
      refute satisfies?(cl, @vars),
             "Expected ambient temp to exceed NH3 storage threshold (refrigeration always required)"
    end

    test "constraint: FORCE_MAJEURE — mer_outage false means FM not triggered [normal ops]", %{contract: c} do
      cl = find_clause(c, "FORCE_MAJEURE")
      # FM is NOT triggered (mer_outage = 0.0 != 1.0). Desired state.
      refute satisfies?(cl, @vars),
             "FM should not be triggered under default variables"
    end
  end

  # ────────────────────────────────────────────────────────────
  # 3. KOCH NITROGEN — VESSEL_SPOT_PURCHASE
  # ────────────────────────────────────────────────────────────

  describe "Koch Nitrogen Company — VESSEL_SPOT_PURCHASE" do
    setup %{contracts: contracts} do
      c = find_contract(contracts, "Koch Nitrogen Company, LLC")
      %{contract: c}
    end

    test "metadata", %{contract: c} do
      assert c.counterparty_type == :supplier
      assert c.template_type     == :spot_purchase
      assert c.incoterm          == :fob
      assert c.term_type         == :spot
      assert c.family_id         == "VESSEL_SPOT_PURCHASE"
      assert c.sap_contract_id   == "4700001012"
      assert c.open_position     == 3_000.0
    end

    test "PRICE → :nola_buy :<= 342.0", %{contract: c} do
      cl = find_clause(c, "PRICE")
      assert cl.parameter == :nola_buy
      assert cl.operator  == :<=
      assert cl.value     == 342.0
    end

    test "QUANTITY_TOLERANCE → :inv_nio :between 2850 and 3150", %{contract: c} do
      cl = find_clause(c, "QUANTITY_TOLERANCE")
      assert cl.parameter   == :inv_nio
      assert cl.operator    == :between
      assert cl.value       == 2_850.0
      assert cl.value_upper == 3_150.0
    end

    test "LAYTIME_DEMURRAGE → :lock_hrs :<= 8.0, penalty $750/hr", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert cl.parameter        == :lock_hrs
      assert cl.operator         == :<=
      assert cl.value            == 8.0
      assert cl.penalty_per_unit == 750.00
    end

    test "PORTS_AND_SAFE_BERTH → :river_stage :>= 8.0 ft (Geismar)", %{contract: c} do
      cl = find_clause(c, "PORTS_AND_SAFE_BERTH")
      assert cl.value == 8.0
    end

    # Constraint satisfaction
    test "constraint: PRICE — nola_buy 320.0 <= Koch cap 342.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "PRICE")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: QUANTITY_TOLERANCE — inv_nio 8000 covers minimum 2850 [PASS]", %{contract: c} do
      cl = find_clause(c, "QUANTITY_TOLERANCE")
      assert @vars.inv_nio >= cl.value,
             "inv_nio #{@vars.inv_nio} < minimum shipment #{cl.value}"
    end

    test "constraint: LAYTIME_DEMURRAGE — lock_hrs 12.0 EXCEEDS Koch free 8.0 [FAIL — demurrage accrues]", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      # Default lock_hrs = 12.0 hours; Koch allows only 8.0 free hours.
      # Demurrage accrues at $750/hr for 4 excess hours = $3,000 exposure.
      refute satisfies?(cl, @vars),
             "Expected lock_hrs 12.0 to exceed Koch free laytime 8.0"
      # Quantify the demurrage exposure
      excess_hrs = @vars.lock_hrs - cl.value
      demurrage = excess_hrs * cl.penalty_per_unit
      assert excess_hrs == 4.0
      assert demurrage == 3_000.0
    end

    test "constraint: PORTS_AND_SAFE_BERTH — river_stage 18.0 >= Geismar min 8.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "PORTS_AND_SAFE_BERTH")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PAYMENT — working_cap 4_200_000 >= TT 1_026_000 [PASS]", %{contract: c} do
      cl = find_clause(c, "PAYMENT")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 4. THE MOSAIC COMPANY — DOMESTIC_MULTIMODAL_SALE (St. Louis)
  # ────────────────────────────────────────────────────────────

  describe "The Mosaic Company — DOMESTIC_MULTIMODAL_SALE (StL)" do
    setup %{contracts: contracts} do
      c = find_contract(contracts, "The Mosaic Company")
      %{contract: c}
    end

    test "metadata", %{contract: c} do
      assert c.counterparty_type == :customer
      assert c.template_type     == :spot_sale
      assert c.incoterm          == :dap
      assert c.family_id         == "DOMESTIC_MULTIMODAL_SALE"
      assert c.open_position     == 5_000.0
    end

    test "PRICE → :sell_stl :>= 415.0", %{contract: c} do
      cl = find_clause(c, "PRICE")
      assert cl.parameter == :sell_stl
      assert cl.operator  == :>=
      assert cl.value     == 415.0
    end

    test "QUANTITY_TOLERANCE → :inv_mer :between 4750 and 5250", %{contract: c} do
      cl = find_clause(c, "QUANTITY_TOLERANCE")
      assert cl.parameter   == :inv_mer
      assert cl.value       == 4_750.0
      assert cl.value_upper == 5_250.0
    end

    test "LAYTIME_DEMURRAGE → :lock_hrs :<= 48.0, penalty $208.33/hr", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert cl.value            == 48.0
      assert cl.penalty_per_unit == 208.33
    end

    test "FORCE_MAJEURE → :mer_outage :== 1.0 (StL dock directly)", %{contract: c} do
      cl = find_clause(c, "FORCE_MAJEURE")
      assert cl.parameter == :mer_outage
      assert cl.value     == 1.0
    end

    # Constraint satisfaction
    test "constraint: PRICE — sell_stl 410.0 BELOW Mosaic floor 415.0 [FAIL — contract underwater]", %{contract: c} do
      cl = find_clause(c, "PRICE")
      # Default sell_stl = $410/MT; Mosaic requires >= $415/MT.
      # The contract is currently unprofitable at default market prices by $5/MT.
      refute satisfies?(cl, @vars),
             "Expected sell_stl 410.0 to be below Mosaic price floor 415.0"
      shortfall = cl.value - @vars.sell_stl
      assert shortfall == 5.0
    end

    test "constraint: LAYTIME_DEMURRAGE — lock_hrs 12.0 << free 48.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PAYMENT — working_cap 4_200_000 >= 2_075_000 [PASS]", %{contract: c} do
      cl = find_clause(c, "PAYMENT")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 5. NUTRIEN LTD — DOMESTIC_MULTIMODAL_SALE (Memphis)
  # ────────────────────────────────────────────────────────────

  describe "Nutrien Ltd — DOMESTIC_MULTIMODAL_SALE (Memphis)" do
    setup %{contracts: contracts} do
      c = find_contract(contracts, "Nutrien Ltd.")
      %{contract: c}
    end

    test "metadata", %{contract: c} do
      assert c.counterparty_type == :customer
      assert c.incoterm          == :dap
      assert c.family_id         == "DOMESTIC_MULTIMODAL_SALE"
      assert c.open_position     == 4_000.0
    end

    test "PRICE → :sell_mem :>= 388.0", %{contract: c} do
      cl = find_clause(c, "PRICE")
      assert cl.parameter == :sell_mem
      assert cl.operator  == :>=
      assert cl.value     == 388.0
    end

    test "FORCE_MAJEURE → :nio_outage :== 1.0 (Memphis dock)", %{contract: c} do
      cl = find_clause(c, "FORCE_MAJEURE")
      assert cl.parameter == :nio_outage
      assert cl.value     == 1.0
    end

    # Constraint satisfaction
    test "constraint: PRICE — sell_mem 385.0 BELOW Nutrien floor 388.0 [FAIL — $3/MT shortfall]", %{contract: c} do
      cl = find_clause(c, "PRICE")
      refute satisfies?(cl, @vars),
             "Expected sell_mem 385.0 to be below Nutrien floor 388.0"
      shortfall = cl.value - @vars.sell_mem
      assert shortfall == 3.0
    end

    test "constraint: FORCE_MAJEURE — nio_outage false means FM not triggered [normal ops]", %{contract: c} do
      cl = find_clause(c, "FORCE_MAJEURE")
      refute satisfies?(cl, @vars),
             "FM should not be triggered under default variables"
    end
  end

  # ────────────────────────────────────────────────────────────
  # 6. J.R. SIMPLOT — ANNUAL SUPPLY (multi-point StL + Mem)
  # ────────────────────────────────────────────────────────────

  describe "J.R. Simplot Company — annual supply (StL + Mem)" do
    setup %{contracts: contracts} do
      c = find_contract(contracts, "J.R. Simplot Company")
      %{contract: c}
    end

    test "metadata", %{contract: c} do
      assert c.counterparty_type == :customer
      assert c.incoterm          == :dap
      assert c.term_type         == :long_term
      assert c.open_position     == 25_000.0
    end

    test "has both sell_stl and sell_mem price constraints", %{contract: c} do
      params = c.clauses |> Enum.map(& &1.parameter) |> Enum.uniq()
      assert :sell_stl in params
      assert :sell_mem in params
    end

    test "PRICE StL → :sell_stl :>= 400.0", %{contract: c} do
      cl = find_clause_by(c, fn cl -> cl.clause_id == "PRICE" and cl.parameter == :sell_stl end)
      assert cl.value == 400.0
    end

    test "PRICE Mem → :sell_mem :>= 375.0", %{contract: c} do
      cl = find_clause_by(c, fn cl -> cl.clause_id == "PRICE" and cl.parameter == :sell_mem end)
      assert cl.value == 375.0
    end

    test "LAYTIME_DEMURRAGE → :lock_hrs :<= 48.0 (StL primary), penalty $208.33/hr", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert cl.value            == 48.0
      assert cl.penalty_per_unit == 208.33
    end

    test "working_cap >= 3_000_000 (annual supply requires higher capital)", %{contract: c} do
      cl = find_clause(c, "PAYMENT")
      assert cl.value == 3_000_000.0
    end

    # Constraint satisfaction
    test "constraint: PRICE StL — sell_stl 410.0 >= Simplot floor 400.0 [PASS]", %{contract: c} do
      cl = find_clause_by(c, fn cl -> cl.clause_id == "PRICE" and cl.parameter == :sell_stl end)
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PRICE Mem — sell_mem 385.0 >= Simplot floor 375.0 [PASS]", %{contract: c} do
      cl = find_clause_by(c, fn cl -> cl.clause_id == "PRICE" and cl.parameter == :sell_mem end)
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: LAYTIME_DEMURRAGE — lock_hrs 12.0 <= free 48.0 [PASS]", %{contract: c} do
      cl = find_clause(c, "LAYTIME_DEMURRAGE")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end

    test "constraint: PAYMENT — working_cap 4_200_000 >= 3_000_000 [PASS]", %{contract: c} do
      cl = find_clause(c, "PAYMENT")
      assert satisfies?(cl, @vars), constraint_msg(cl, @vars)
    end
  end

  # ────────────────────────────────────────────────────────────
  # 7. PORTFOLIO CONSTRAINT SUMMARY
  # ────────────────────────────────────────────────────────────

  describe "portfolio constraint summary at default variables" do
    @tag :summary
    test "identifies all violated and satisfied constraints", %{contracts: contracts} do
      vars = @vars

      results =
        contracts
        |> Enum.flat_map(fn contract ->
          lp_clauses(contract)
          |> Enum.map(fn cl ->
            var_val = Map.get(vars, cl.parameter)
            satisfied = satisfies?(cl, vars)

            %{
              counterparty: short_name(contract.counterparty),
              clause_id:    cl.clause_id,
              parameter:    cl.parameter,
              operator:     cl.operator,
              clause_value: cl.value,
              var_value:    var_val,
              satisfied:    satisfied
            }
          end)
        end)

      violated = Enum.reject(results, & &1.satisfied)
      passed   = Enum.filter(results, & &1.satisfied)

      # Identify violated clauses by {clause_id, parameter} — counterparty-agnostic
      # so the check works regardless of how short_name formats the name.
      violated_pairs =
        violated
        |> Enum.map(fn r -> {r.clause_id, r.parameter} end)
        |> MapSet.new()

      # Expected violations at default variable values:
      # 1. Koch LAYTIME_DEMURRAGE: lock_hrs 12 > 8 free hrs → $3,000 demurrage
      # 2. Mosaic PRICE: sell_stl 410 < floor 415 → $5/MT below minimum
      # 3. Nutrien PRICE: sell_mem 385 < floor 388 → $3/MT below minimum
      # 4. Both supplier PRODUCT_AND_SPECS: ambient temp 45°F > -27°F (refrigeration always required)
      # 5. All FORCE_MAJEURE: FM not triggered (desired — outage == 0.0 != 1.0)

      # Verify the three actionable commercial violations are present
      assert MapSet.member?(violated_pairs, {"LAYTIME_DEMURRAGE", :lock_hrs}),
             "Expected Koch demurrage violation not found in violated set: #{inspect(MapSet.to_list(violated_pairs))}"
      assert MapSet.member?(violated_pairs, {"PRICE", :sell_stl}),
             "Expected Mosaic sell_stl price violation not found"
      assert MapSet.member?(violated_pairs, {"PRICE", :sell_mem}),
             "Expected Nutrien sell_mem price violation not found"

      # At least as many pass as there are non-trigger-condition clauses
      assert length(passed) >= 10,
             "Expected at least 10 passed constraints, got #{length(passed)}"
    end
  end

  # ────────────────────────────────────────────────────────────
  # HELPERS
  # ────────────────────────────────────────────────────────────

  # Find contract by partial name match
  defp find_contract(contracts, name) do
    result = Enum.find(contracts, fn c ->
      String.contains?(String.downcase(c.counterparty), String.downcase(String.split(name, " ") |> List.first()))
    end)
    assert result != nil, "Contract not found for '#{name}'"
    result
  end

  # Find clause by clause_id
  defp find_clause(%{clauses: clauses}, clause_id) do
    Enum.find(clauses, fn c -> c.clause_id == clause_id end)
  end

  # Find clause by arbitrary predicate
  defp find_clause_by(%{clauses: clauses}, pred) do
    Enum.find(clauses, pred)
  end

  # Filter LP-relevant clauses (those with a parameter assigned)
  defp lp_clauses(%{clauses: clauses}) do
    Enum.filter(clauses, fn c -> not is_nil(c.parameter) end)
  end

  # Evaluate whether the current variable value satisfies the clause constraint
  @spec satisfies?(map(), Variables.t()) :: boolean()
  defp satisfies?(%{parameter: nil}, _vars), do: true

  defp satisfies?(%{operator: :<=, parameter: param, value: bound}, vars) do
    var_val = resolve_var(vars, param)
    var_val <= bound
  end

  defp satisfies?(%{operator: :>=, parameter: param, value: bound}, vars) do
    var_val = resolve_var(vars, param)
    var_val >= bound
  end

  defp satisfies?(%{operator: :==, parameter: param, value: target}, vars) do
    var_val = resolve_var(vars, param)
    var_val == target
  end

  defp satisfies?(%{operator: :between, parameter: param, value: lower}, vars) do
    # The :between clause expresses a shipment window (min..max cargo size).
    # "Satisfied" means the current inventory can cover the minimum shipment.
    # Having more inventory than the window maximum is fine operationally.
    var_val = resolve_var(vars, param)
    var_val >= lower
  end

  # Resolve variable value — booleans become 0.0/1.0 for :== comparisons
  defp resolve_var(vars, :mer_outage), do: if(vars.mer_outage, do: 1.0, else: 0.0)
  defp resolve_var(vars, :nio_outage), do: if(vars.nio_outage, do: 1.0, else: 0.0)
  defp resolve_var(vars, key), do: Map.fetch!(vars, key)

  # Human-readable constraint failure message
  defp constraint_msg(%{parameter: p, operator: op, value: v}, vars) do
    var_val = resolve_var(vars, p)
    "#{p} = #{var_val} does not satisfy #{op} #{v}"
  end

  defp short_name(name) do
    name
    |> String.split([" ", ","])
    |> Enum.take(2)
    |> Enum.join(" ")
  end
end
