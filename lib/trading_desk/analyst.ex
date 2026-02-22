defmodule TradingDesk.Analyst do
  @moduledoc """
  Claude-powered analyst that explains trading scenarios, Monte Carlo results,
  and agent decisions in plain English. Works with any product group.

  Counterparty names and vessel names are anonymized before being sent to
  the Claude API. The response is de-anonymized before returning to the caller.
  """

  require Logger

  alias TradingDesk.ProductGroup
  alias TradingDesk.Anonymizer

  @model "claude-sonnet-4-5-20250929"

  @doc """
  Explain a solve result for the trader.

  Accepts variables as a `%Variables{}` struct or a plain map.
  Product group is read from `result.product_group`.
  """
  def explain_solve(variables, result) do
    pg = Map.get(result, :product_group) || :ammonia_domestic
    vars = to_var_map(variables)
    frame = ProductGroup.frame(pg)

    vars_text = format_variables(vars, frame)
    routes_text = format_routes(result, frame)

    roi = Map.get(result, :roi) || 0.0

    prompt = """
    You are a #{frame[:product]} trading analyst at a global commodities firm.
    Product group: #{frame[:name]} (#{frame[:geography]}).
    Transport: #{frame[:transport_mode]}.

    A trader just ran an optimization with these inputs:

    #{vars_text}

    ROUTES:
    #{routes_text}

    RESULT:
    - Gross profit: $#{format_number(Map.get(result, :profit))}
    - Total tons: #{format_number(Map.get(result, :tons))}
    - #{vessel_label(frame)}: #{format_vessels(result, frame)}
    - ROI: #{Float.round(roi / 1, 1)}%
    - Capital deployed: $#{format_number(Map.get(result, :cost))}

    Write a 2-3 sentence analyst note explaining WHY this result makes sense given the inputs.
    Focus on the key drivers (margins, constraints, or risks). Be concise and tactical.
    """

    call_claude(prompt)
  end

  @doc """
  Explain a solve result WITH position impact analysis and detailed market commentary.

  Produces a comprehensive explanation covering:
  - What the solver optimized and why
  - Which routes/constraints were binding
  - Position and contract impact
  - Weather and operational conditions
  - Risk flags and recommended actions

  Counterparty names are anonymized before sending to Claude API and
  de-anonymized in the returned text.

  Returns {:ok, explanation_text, impact_map} or {:ok, text} or {:error, reason}.
  """
  def explain_solve_with_impact(variables, result, intent, trader_action, objective \\ :max_profit) do
    pg = Map.get(result, :product_group) || :ammonia_domestic
    vars = to_var_map(variables)
    frame = ProductGroup.frame(pg)
    book = TradingDesk.Contracts.SapPositions.book_summary()
    impact = build_position_impact(result, book, intent, trader_action)

    # Collect sensitive names for anonymization
    counterparty_names = Anonymizer.counterparty_names(book)
    positions_text = format_positions_for_explanation(book)
    {anon_positions, anon_map} = Anonymizer.anonymize(positions_text, counterparty_names)

    # Anonymize trader action if it contains counterparty names
    {anon_action, _} = Anonymizer.anonymize(trader_action || "", counterparty_names)

    vars_text = format_variables(vars, frame)
    routes_text = format_routes(result, frame)
    shadow_text = format_shadow_prices(result, frame)
    roi = Map.get(result, :roi) || 0.0

    # Include weather forecast context if available
    forecast = safe_get_forecast()
    forecast_text = format_forecast_for_prompt(forecast)

    # Include contract penalty obligations and delivery schedule
    store_key = if pg == :ammonia_domestic, do: :ammonia, else: pg
    {anon_penalty_text, penalty_anon_map} =
      format_penalty_obligations_for_prompt(store_key, counterparty_names)

    # Merge anon maps so de-anonymization covers both position and penalty entities
    merged_anon_map = Map.merge(anon_map, penalty_anon_map)

    obj_label    = objective_label_for_prompt(objective)
    obj_framing  = objective_framing_for_prompt(objective)
    obj_metric   = objective_primary_metric(objective)

    prompt = """
    You are a senior #{frame[:product]} trading analyst at a global commodities firm.
    Product: #{frame[:name]} | Geography: #{frame[:geography]} | Transport: #{frame[:transport_mode]}.

    The trader ran this optimization with objective: #{obj_label}.
    #{obj_framing}

    Explain WHY the solver chose this allocation through the lens of that objective —
    how contract obligations, penalty risk, and the objective function itself drove
    the route selection and tonnage split.

    #{if anon_action != "", do: "TRADER SCENARIO: \"#{anon_action}\"\n\n", else: ""}SOLVER INPUTS:
    #{vars_text}

    #{if forecast_text != "", do: "WEATHER FORECAST (D+3):\n#{forecast_text}\n\n", else: ""}SOLVER RESULT:
    - Objective: #{obj_label}
    - Status: OPTIMAL
    - Gross profit: $#{format_number(Map.get(result, :profit))}
    - Total tons shipped: #{format_number(Map.get(result, :tons))}
    - #{vessel_label(frame)}: #{format_vessels(result, frame)}
    - ROI: #{Float.round(roi / 1, 1)}%
    - Capital deployed: $#{format_number(Map.get(result, :cost))}

    ROUTE ALLOCATION:
    #{routes_text}

    #{if shadow_text != "", do: "BINDING CONSTRAINTS (shadow prices):\n#{shadow_text}\n\n", else: ""}OPEN BOOK POSITIONS (entity names anonymized):
    #{anon_positions}
    Net position: #{book.net_position} MT

    #{if anon_penalty_text != "", do: "CONTRACT OBLIGATIONS & PENALTY RISK:\n#{anon_penalty_text}", else: ""}

    Write a comprehensive analyst note (5-8 sentences) framed entirely around #{obj_label}:
    1. Why this allocation was the solver's optimal choice for #{obj_label} — what
       trade-offs it made versus alternative allocations, and which route or contract
       drove the result on the #{obj_metric} axis
    2. How penalty clauses (volume shortfall / late delivery / demurrage) shifted the
       effective margins and how the #{obj_label} objective weighted that penalty risk
       in the allocation decision
    3. Which delivery obligations are most exposed given this allocation and what the
       daily penalty cost would be if they slip past their grace periods
    4. Which constraints are binding (shadow prices) and whether relaxing any of them
       would improve #{obj_metric} further
    5. Any weather, river, or operational risks that could erode the #{obj_metric}
       outcome or trigger penalty obligations
    6. Recommended follow-up actions consistent with #{obj_label} — contracts to
       prioritize, hedges to consider, and what to watch in the next 24-48 hours

    Be analytical and tactical. Use anonymized entity codes as-is (e.g., ENTITY_01).
    Plain prose, no bullet lists.
    """

    case call_claude(prompt, max_tokens: 1000) do
      {:ok, raw_text} ->
        final_text = Anonymizer.deanonymize(raw_text, merged_anon_map)
        {:ok, final_text, impact}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Explain a Monte Carlo distribution for the trader.

  Accepts variables as a `%Variables{}` struct or a plain map.
  Product group is read from `distribution.product_group`.
  """
  def explain_distribution(variables, distribution) do
    pg = Map.get(distribution, :product_group) || :ammonia_domestic
    vars = to_var_map(variables)
    frame = ProductGroup.frame(pg)

    vars_summary = format_variables_compact(vars, frame)
    sensitivity_text = format_sensitivity(Map.get(distribution, :sensitivity))

    prompt = """
    You are a #{frame[:product]} trading analyst. Product: #{frame[:name]} (#{frame[:geography]}).

    A trader just ran #{Map.get(distribution, :n_scenarios)} Monte Carlo scenarios with these center values:

    #{vars_summary}

    DISTRIBUTION:
    - #{Map.get(distribution, :n_feasible)}/#{Map.get(distribution, :n_scenarios)} scenarios feasible
    - Mean: $#{format_number(Map.get(distribution, :mean))}
    - VaR 5%: $#{format_number(Map.get(distribution, :p5))}
    - P95: $#{format_number(Map.get(distribution, :p95))}
    - Std dev: $#{format_number(Map.get(distribution, :stddev))}
    - Signal: #{Map.get(distribution, :signal)}#{sensitivity_text}

    Write a 2-3 sentence analyst note interpreting this distribution and signal.
    What does the VaR/upside spread tell us? Should the trader proceed?
    """

    call_claude(prompt)
  end

  @doc """
  Explain an AutoRunner agent decision.

  `result` must have `.center` (variable map), `.distribution`, `.triggers`,
  and `.product_group`.
  """
  def explain_agent(result) do
    dist = Map.get(result, :distribution) || %{}
    pg = result[:product_group] || Map.get(dist, :product_group) || :ammonia_domestic
    center = to_var_map(Map.get(result, :center) || %{})
    frame = ProductGroup.frame(pg)

    trigger_text = format_triggers(Map.get(result, :triggers))
    vars_summary = format_variables_compact(center, frame)
    sensitivity_text = format_sensitivity(Map.get(dist, :sensitivity))

    prompt = """
    You are an autonomous #{frame[:product]} trading agent analyst.
    Product: #{frame[:name]} (#{frame[:geography]}).

    The agent just ran Monte Carlo on live market data:

    #{trigger_text}

    CURRENT CONDITIONS:
    #{vars_summary}

    AGENT RESULT:
    - Signal: #{Map.get(dist, :signal)}
    - Mean: $#{format_number(Map.get(dist, :mean))}
    - VaR 5%: $#{format_number(Map.get(dist, :p5))}
    - #{Map.get(dist, :n_feasible)}/#{Map.get(dist, :n_scenarios)} feasible#{sensitivity_text}

    Write 2-3 sentences explaining what the agent sees and why it gave this signal.
    What changed? What's the agent watching?
    """

    call_claude(prompt)
  end

  # ── Variable formatting ─────────────────────────────────────

  defp format_variables(vars, frame) do
    (frame[:variables] || [])
    |> Enum.group_by(& &1[:group])
    |> Enum.map_join("\n\n", fn {group, var_defs} ->
      header = group |> to_string() |> String.upcase()
      lines = Enum.map_join(var_defs, "\n", fn v ->
        val = Map.get(vars, v[:key])
        "- #{v[:label]}: #{format_var_value(val, v)}"
      end)
      "#{header}:\n#{lines}"
    end)
  end

  defp format_variables_compact(vars, frame) do
    (frame[:variables] || [])
    |> Enum.group_by(& &1[:group])
    |> Enum.map_join("\n", fn {group, var_defs} ->
      header = group |> to_string() |> String.upcase()
      items = Enum.map_join(var_defs, ", ", fn v ->
        val = Map.get(vars, v[:key])
        "#{v[:label]} #{format_var_value_short(val, v)}"
      end)
      "#{header}: #{items}"
    end)
  end

  defp format_var_value(val, %{type: :boolean}) do
    if val in [true, 1, 1.0], do: "YES", else: "NO"
  end

  defp format_var_value(val, v) when is_float(val) do
    unit = if v[:unit] && v[:unit] != "", do: " #{v[:unit]}", else: ""
    if abs(val) >= 1000, do: "#{format_number(val)}#{unit}", else: "#{Float.round(val, 1)}#{unit}"
  end

  defp format_var_value(val, v) when is_number(val) do
    unit = if v[:unit] && v[:unit] != "", do: " #{v[:unit]}", else: ""
    "#{val}#{unit}"
  end

  defp format_var_value(val, _v), do: "#{inspect(val)}"

  defp format_var_value_short(val, %{type: :boolean}) do
    if val in [true, 1, 1.0], do: "YES", else: "NO"
  end

  defp format_var_value_short(val, v) when is_number(val) do
    unit = if v[:unit] && v[:unit] != "", do: v[:unit], else: ""

    formatted =
      cond do
        abs(val) >= 1_000_000 -> "#{Float.round(val / 1_000_000, 1)}M"
        abs(val) >= 1000 -> "#{format_number(val)}"
        is_float(val) -> "#{Float.round(val, 1)}"
        true -> "#{val}"
      end

    if unit != "", do: "#{formatted} #{unit}", else: formatted
  end

  defp format_var_value_short(val, _v), do: "#{inspect(val)}"

  # ── Route formatting ────────────────────────────────────────

  defp format_routes(result, frame) do
    routes = frame[:routes] || []
    route_tons = Map.get(result, :route_tons) || []
    margins = Map.get(result, :margins) || []

    routes
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {route, i} ->
      tons = Enum.at(route_tons, i, 0.0)
      margin = Enum.at(margins, i, 0.0)
      "- #{route[:name] || "Route #{i + 1}"}: #{format_number(tons)} tons, margin $#{Float.round(margin / 1, 1)}/t"
    end)
  end

  # ── Result formatting ───────────────────────────────────────

  defp vessel_label(frame) do
    case frame[:transport_mode] do
      :barge -> "Barges used"
      :ocean_vessel -> "Vessels used"
      _ -> "Units used"
    end
  end

  defp format_vessels(result, _frame) do
    case Map.get(result, :barges) do
      nil -> "N/A"
      b when is_float(b) -> Float.round(b, 1)
      b -> b
    end
  end

  # ── Sensitivity & triggers ──────────────────────────────────

  defp format_sensitivity(sensitivity) when is_list(sensitivity) and length(sensitivity) > 0 do
    top =
      sensitivity
      |> Enum.take(3)
      |> Enum.map_join(", ", fn {key, corr} ->
        sign = if corr > 0, do: "+", else: ""
        "#{key} (#{sign}#{Float.round(corr, 2)})"
      end)

    "\n- Top risk drivers: #{top}"
  end

  defp format_sensitivity(_), do: ""

  defp format_triggers(triggers) when is_list(triggers) and length(triggers) > 0 do
    changes =
      triggers
      |> Enum.map_join(", ", fn %{key: key, old: old, new: new} ->
        delta = new - old
        "#{key} #{if delta > 0, do: "+", else: ""}#{Float.round(delta, 1)}"
      end)

    "Triggered by: #{changes}."
  end

  defp format_triggers(_), do: "Scheduled run."

  # ── Variable map conversion ─────────────────────────────────

  defp to_var_map(%TradingDesk.Variables{} = v), do: Map.from_struct(v)
  defp to_var_map(map) when is_map(map), do: Map.drop(map, [:__struct__])

  # ── Position/forecast formatters ───────────────────────────

  defp format_positions_for_explanation(book) do
    book.positions
    |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
    |> Enum.map_join("\n", fn {name, pos} ->
      dir = if pos.direction == :purchase, do: "BUY", else: "SELL"
      "#{name}: #{dir} #{pos.incoterm |> to_string() |> String.upcase()} | open=#{pos.open_qty_mt} MT"
    end)
  end

  defp format_shadow_prices(result, frame) do
    shadow = Map.get(result, :shadow_prices) || []
    constraints = frame[:constraints] || []
    if shadow == [] or constraints == [] do
      ""
    else
      constraints
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {c, i} ->
        price = Enum.at(shadow, i, 0.0)
        if abs(price) > 0.01 do
          "- #{c[:name] || c[:key]}: $#{Float.round(price / 1, 2)}/MT shadow price (binding)"
        else
          "- #{c[:name] || c[:key]}: not binding"
        end
      end)
    end
  end

  defp safe_get_forecast do
    try do
      TradingDesk.Data.LiveState.get_supplementary(:forecast)
    rescue
      _ -> nil
    catch
      :exit, _ -> nil
    end
  end

  # ── Objective helpers ────────────────────────────────────────

  defp objective_label_for_prompt(obj) do
    case obj do
      :max_profit    -> "Maximize Profit"
      :min_cost      -> "Minimize Cost"
      :max_roi       -> "Maximize ROI"
      :cvar_adjusted -> "CVaR-Adjusted (risk-weighted profit)"
      :min_risk      -> "Minimize Risk"
      _              -> "Maximize Profit"
    end
  end

  # A one-sentence description of what the solver is optimising for,
  # used as the framing sentence immediately after the objective label.
  defp objective_framing_for_prompt(obj) do
    case obj do
      :max_profit ->
        "The solver maximized gross profit in absolute dollar terms — " <>
        "volume and margin were the primary drivers; capital efficiency was secondary."

      :min_cost ->
        "The solver minimized total capital deployed — it prioritized lower-cost routes " <>
        "and tighter tonnage even if that left margin on the table."

      :max_roi ->
        "The solver maximized return on invested capital — it preferred high-margin, " <>
        "capital-efficient routes and avoided deploying extra barges for marginal gains."

      :cvar_adjusted ->
        "The solver maximized risk-weighted profit using CVaR — it discounted routes " <>
        "with high tail-risk (weather exposure, penalty clauses, low feasibility rate) " <>
        "in favour of more reliable, lower-variance allocations."

      :min_risk ->
        "The solver minimized operational and financial risk — it avoided routes with " <>
        "high penalty exposure, weather sensitivity, or uncertain feasibility, " <>
        "accepting lower profit to reduce downside variance."

      _ ->
        "The solver maximized gross profit."
    end
  end

  # Short label for the primary metric being optimised — used inline in instructions.
  defp objective_primary_metric(obj) do
    case obj do
      :max_profit    -> "gross profit"
      :min_cost      -> "capital deployed"
      :max_roi       -> "ROI"
      :cvar_adjusted -> "risk-adjusted profit"
      :min_risk      -> "risk exposure"
      _              -> "gross profit"
    end
  end

  defp format_forecast_for_prompt(nil), do: ""
  defp format_forecast_for_prompt(forecast) when is_map(forecast) do
    d3 = Map.get(forecast, :solver_d3) || Map.get(forecast, "solver_d3") || %{}
    if map_size(d3) == 0 do
      ""
    else
      lines = Enum.map_join(d3, "\n", fn {k, v} ->
        label = k |> to_string() |> String.replace("forecast_", "") |> String.replace("_", " ")
        "- D+3 #{label}: #{if is_float(v), do: Float.round(v, 1), else: v}"
      end)
      lines
    end
  end
  defp format_forecast_for_prompt(_), do: ""

  # Build penalty obligations text for the explanation prompt.
  # Returns {anonymized_text, anon_map}.
  defp format_penalty_obligations_for_prompt(store_key, counterparty_names) do
    penalty_sched =
      try do
        TradingDesk.Contracts.ConstraintBridge.penalty_schedule(store_key)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    active_contracts =
      try do
        TradingDesk.Contracts.Store.get_active_set(store_key)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

    schedules = TradingDesk.Trader.DeliverySchedule.from_contracts(active_contracts)
    total_exposure = TradingDesk.Trader.DeliverySchedule.total_daily_exposure(schedules)

    if penalty_sched == [] and schedules == [] do
      {"", %{}}
    else
      penalty_lines =
        penalty_sched
        |> Enum.sort_by(& &1.max_exposure, :desc)
        |> Enum.map_join("\n", fn p ->
          type = p.penalty_type |> to_string() |> String.replace("_", " ")
          dir  = if p.counterparty_type == :supplier, do: "purchase", else: "sale"
          "- #{p.counterparty} (#{dir}): #{type} penalty $#{trunc(p.rate_per_ton)}/MT, " <>
          "open #{trunc(p.open_qty)} MT, max exposure $#{trunc(p.max_exposure)}"
        end)

      schedule_lines =
        schedules
        |> Enum.sort_by(fn s -> s.scheduled_qty_mt * s.penalty_per_mt_per_day end, :desc)
        |> Enum.map_join("\n", fn s ->
          dir    = if s.direction == :purchase, do: "PURCHASE from", else: "SALE to"
          daily  = s.scheduled_qty_mt * s.penalty_per_mt_per_day
          status = if s.next_window_days == 0, do: "WINDOW OPEN NOW", else: "opens D+#{s.next_window_days}"
          "- #{dir} #{s.counterparty}: #{trunc(s.scheduled_qty_mt)} MT/window, " <>
          "#{s.grace_period_days}-day grace, $#{:erlang.float_to_binary(s.penalty_per_mt_per_day / 1.0, decimals: 2)}/MT/day " <>
          "($#{round(daily)}/day if delayed), #{status}"
        end)

      exposure_line =
        if total_exposure > 0 do
          "\nTotal book daily exposure if all deliveries miss grace: $#{round(total_exposure)}/day"
        else
          ""
        end

      raw_text =
        if penalty_lines != "" do
          "Penalty clauses:\n#{penalty_lines}\n\nDelivery schedules:\n#{schedule_lines}#{exposure_line}"
        else
          "Delivery schedules:\n#{schedule_lines}#{exposure_line}"
        end

      Anonymizer.anonymize(raw_text, counterparty_names)
    end
  end

  # ── Generic prompt (for external callers) ───────────────────

  @doc """
  Send an arbitrary prompt to Claude and return the raw text response.

  Used by modules that need Claude analysis but don't fit the structured
  explain_solve / explain_distribution flow (e.g. DeliveryScheduler summaries).

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  def prompt(text, opts \\ []) do
    call_claude(text, opts)
  end

  # ── Claude API ──────────────────────────────────────────────

  defp call_claude(prompt, opts \\ []) do
    max_tokens = Keyword.get(opts, :max_tokens, 300)
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      Logger.warning("ANTHROPIC_API_KEY not set, skipping analyst explanation")
      {:error, :no_api_key}
    else
      case Req.post("https://api.anthropic.com/v1/messages",
        json: %{
          model: @model,
          max_tokens: max_tokens,
          messages: [%{role: "user", content: prompt}]
        },
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 60_000
      ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: status, body: body}} ->
          error_msg = extract_api_error(body)
          Logger.error("Claude API error #{status}: #{error_msg}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("Claude API request failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end

  defp extract_api_error(%{"error" => %{"message" => msg}}), do: msg
  defp extract_api_error(body), do: inspect(body)

  defp format_number(val) when is_float(val) do
    val
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp format_number(val) when is_integer(val) do
    val
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end

  defp format_number(nil), do: "N/A"
  defp format_number(val), do: to_string(val)

  # ── Position Impact Builder ───────────────────────────────

  defp build_position_impact(result, book, intent, trader_action) do
    tons_shipped = Map.get(result, :tons) || 0

    by_contract =
      book.positions
      |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
      |> Enum.map(fn {name, pos} ->
        # Check if this contract was affected by the intent
        affected = if intent do
          Enum.find(intent.affected_contracts || [], fn ac ->
            String.contains?(String.downcase(name), String.downcase(ac.counterparty || ""))
          end)
        end

        impact_text = cond do
          affected && affected.impact != "" -> affected.impact
          pos.direction == :sale and tons_shipped > 0 ->
            "Sale obligation: #{format_number(pos.open_qty_mt)} MT remaining"
          pos.direction == :purchase and tons_shipped > 0 ->
            "Supply commitment: #{format_number(pos.open_qty_mt)} MT to lift"
          true -> "No direct impact from this solve"
        end

        %{
          counterparty: name,
          direction: to_string(pos.direction),
          incoterm: pos.incoterm |> to_string() |> String.upcase(),
          open_qty: pos.open_qty_mt,
          impact: impact_text
        }
      end)

    summary = cond do
      trader_action != nil and trader_action != "" ->
        "Solved for: \"#{trader_action}\" — " <>
        "#{format_number(tons_shipped)} MT optimized, " <>
        "$#{format_number(Map.get(result, :profit))} gross profit"
      true ->
        "#{format_number(tons_shipped)} MT optimized across routes, " <>
        "$#{format_number(Map.get(result, :profit))} gross profit"
    end

    %{
      summary: summary,
      by_contract: by_contract,
      net_position_before: book.net_position,
      net_position_after: book.net_position,
      total_tons_moved: tons_shipped
    }
  end
end
