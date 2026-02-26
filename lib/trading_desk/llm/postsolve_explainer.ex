defmodule TradingDesk.LLM.PostsolveExplainer do
  @moduledoc """
  Generates post-solve explanations of solver output using all registered
  HuggingFace models.

  Runs after the solver completes. Each model receives the same prompt
  containing the solver result, route allocations, and market context,
  then provides its own analytical interpretation.

  Results are displayed sequentially on the Response tab alongside the
  existing Claude analyst note.
  """

  require Logger

  alias TradingDesk.LLM.Pool
  alias TradingDesk.ProductGroup
  alias TradingDesk.Anonymizer

  @doc """
  Explain a solve result using all registered models in parallel.

  Returns `[{model_id, model_name, {:ok, text} | {:error, reason}}]`.
  """
  @spec explain_all(map(), map(), atom(), atom()) ::
          [{atom(), String.t(), {:ok, String.t()} | {:error, term()}}]
  def explain_all(variables, result, product_group, objective \\ :max_profit) do
    frame = ProductGroup.frame(product_group)
    book = safe_book_summary()
    counterparty_names = if book, do: Anonymizer.counterparty_names(book), else: []

    prompt = build_postsolve_prompt(variables, result, frame, objective)
    {anon_prompt, anon_map} = Anonymizer.anonymize(prompt, counterparty_names)

    results = Pool.generate_all(anon_prompt, max_tokens: 1024)

    Enum.map(results, fn {model_id, model_name, res} ->
      deanon_res =
        case res do
          {:ok, text} -> {:ok, Anonymizer.deanonymize(text, anon_map)}
          error -> error
        end

      {model_id, model_name, deanon_res}
    end)
  end

  @doc """
  Explain a Monte Carlo distribution using all registered models.
  """
  @spec explain_distribution_all(map(), map(), atom()) ::
          [{atom(), String.t(), {:ok, String.t()} | {:error, term()}}]
  def explain_distribution_all(variables, distribution, product_group) do
    frame = ProductGroup.frame(product_group)

    prompt = build_distribution_prompt(variables, distribution, frame)

    Pool.generate_all(prompt, max_tokens: 800)
  end

  # ── Private ────────────────────────────────────────────────

  defp build_postsolve_prompt(variables, result, frame, objective) do
    vars_text = format_variables(variables, frame)
    routes_text = format_routes(result, frame)
    roi = Map.get(result, :roi) || 0.0
    obj_label = objective_label(objective)

    """
    You are a senior #{frame[:product]} trading analyst at a global commodities firm.
    Product: #{frame[:name]} | Geography: #{frame[:geography]} | Transport: #{frame[:transport_mode]}.

    The solver just completed an optimization with objective: #{obj_label}.

    SOLVER INPUTS:
    #{vars_text}

    SOLVER RESULT:
    - Status: #{Map.get(result, :status, :unknown)}
    - Gross profit: $#{format_number(Map.get(result, :profit))}
    - Total tons shipped: #{format_number(Map.get(result, :tons))}
    - ROI: #{Float.round(roi / 1, 1)}%
    - Capital deployed: $#{format_number(Map.get(result, :cost))}

    ROUTE ALLOCATION:
    #{routes_text}

    Write a concise analyst note (3-5 sentences) explaining:
    1. Why this allocation makes sense given the #{obj_label} objective
    2. Which routes dominate and why (margin vs volume drivers)
    3. Any risks or constraints worth watching
    Be analytical and tactical. Plain prose, no bullet lists.
    """
  end

  defp build_distribution_prompt(variables, distribution, frame) do
    vars_text = format_variables_compact(variables, frame)

    """
    You are a #{frame[:product]} trading analyst. Product: #{frame[:name]} (#{frame[:geography]}).

    A trader ran #{Map.get(distribution, :n_scenarios)} Monte Carlo scenarios:

    #{vars_text}

    DISTRIBUTION:
    - #{Map.get(distribution, :n_feasible)}/#{Map.get(distribution, :n_scenarios)} scenarios feasible
    - Mean: $#{format_number(Map.get(distribution, :mean))}
    - VaR 5%: $#{format_number(Map.get(distribution, :p5))}
    - P95: $#{format_number(Map.get(distribution, :p95))}
    - Std dev: $#{format_number(Map.get(distribution, :stddev))}
    - Signal: #{Map.get(distribution, :signal)}

    Write 2-3 sentences interpreting this distribution and signal.
    What does the VaR/upside spread tell us? Should the trader proceed?
    """
  end

  defp format_variables(vars, frame) when is_map(vars) do
    (frame[:variables] || [])
    |> Enum.group_by(& &1[:group])
    |> Enum.map_join("\n\n", fn {group, var_defs} ->
      header = group |> to_string() |> String.upcase()
      lines = Enum.map_join(var_defs, "\n", fn v ->
        val = Map.get(vars, v[:key])
        unit = if v[:unit] && v[:unit] != "", do: " #{v[:unit]}", else: ""
        "- #{v[:label]}: #{format_val(val)}#{unit}"
      end)
      "#{header}:\n#{lines}"
    end)
  end

  defp format_variables_compact(vars, frame) when is_map(vars) do
    (frame[:variables] || [])
    |> Enum.group_by(& &1[:group])
    |> Enum.map_join("\n", fn {group, var_defs} ->
      header = group |> to_string() |> String.upcase()
      items = Enum.map_join(var_defs, ", ", fn v ->
        val = Map.get(vars, v[:key])
        "#{v[:label]} #{format_val(val)}"
      end)
      "#{header}: #{items}"
    end)
  end

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

  defp format_val(val) when is_float(val) and abs(val) >= 1000, do: format_number(val)
  defp format_val(val) when is_float(val), do: "#{Float.round(val, 1)}"
  defp format_val(val) when is_number(val), do: "#{val}"
  defp format_val(true), do: "YES"
  defp format_val(false), do: "NO"
  defp format_val(val), do: "#{inspect(val)}"

  defp format_number(val) when is_float(val) do
    val |> round() |> format_number()
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

  defp objective_label(:max_profit), do: "Maximize Profit"
  defp objective_label(:min_cost), do: "Minimize Cost"
  defp objective_label(:max_roi), do: "Maximize ROI"
  defp objective_label(:cvar_adjusted), do: "CVaR-Adjusted"
  defp objective_label(:min_risk), do: "Minimize Risk"
  defp objective_label(_), do: "Maximize Profit"

  defp safe_book_summary do
    TradingDesk.Contracts.SapPositions.book_summary()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
