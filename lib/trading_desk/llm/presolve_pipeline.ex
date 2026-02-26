defmodule TradingDesk.LLM.PresolvePipeline do
  @moduledoc """
  Unified presolve pipeline: frame → solve → explain, per LLM model.

  When the trader clicks PRESOLVE, this module runs the full pipeline for
  every registered LLM model in parallel:

    1. **Frame** — each LLM reads contract clauses + variables + trader notes
       and produces variable adjustments (via `PresolveFramer.frame/2`)
    2. **Solve** — the framed variables are submitted to the LP solver
       (via `Solver.Port.solve/3`)
    3. **Explain** — the solver result is sent back to the same LLM for a
       plain-English explanation (via `Pool.generate/3`)

  Progress is streamed to the caller LiveView as messages:

      {:presolve_model_progress, model_id, :framing}
      {:presolve_model_progress, model_id, :solving}
      {:presolve_model_progress, model_id, :explaining}
      {:presolve_model_done, model_id, result_map}
      {:presolve_model_error, model_id, phase, reason}
      {:presolve_pipeline_done, all_results}

  Each `result_map` contains:

      %{
        framing: %{variables: ..., adjustments: [...], warnings: [...], framing_notes: ...},
        solver_result: %{status: ..., profit: ..., tons: ..., ...},
        explanation: {:ok, text} | {:error, reason},
        framed_variables: %{...}
      }
  """

  require Logger

  alias TradingDesk.LLM.{PresolveFramer, Pool, ModelRegistry}
  alias TradingDesk.Solver.Port, as: Solver
  alias TradingDesk.{ProductGroup, Anonymizer}
  alias TradingDesk.Contracts.SapPositions

  @doc """
  Run the full presolve pipeline for all registered models in parallel.

  Options:
    :caller_pid     — (required) the LiveView pid to receive progress messages
    :product_group  — which product group (default: :ammonia_domestic)
    :trader_notes   — free-text what-if from the trader
    :objective      — solver objective atom (default: :max_profit)
    :solver_opts    — keyword list passed to the solver
  """
  @spec run_all(map(), keyword()) :: [{atom(), String.t(), map()}]
  def run_all(variables, opts) do
    caller_pid = Keyword.fetch!(opts, :caller_pid)
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)
    trader_notes = Keyword.get(opts, :trader_notes)
    objective = Keyword.get(opts, :objective, :max_profit)
    solver_opts = Keyword.get(opts, :solver_opts, [objective: objective])

    models = ModelRegistry.list()
    book = safe_book_summary()

    tasks =
      Enum.map(models, fn model ->
        Task.async(fn ->
          run_single(model, variables, product_group, trader_notes,
                     objective, solver_opts, book, caller_pid)
        end)
      end)

    results = Task.await_many(tasks, 300_000)

    send(caller_pid, {:presolve_pipeline_done, results})
    results
  end

  # ── Single model pipeline ──────────────────────────────

  defp run_single(model, variables, product_group, trader_notes,
                  objective, solver_opts, book, caller_pid) do
    model_id = model.id
    model_name = model.name

    # Phase 1: Frame
    send(caller_pid, {:presolve_model_progress, model_id, :framing})

    case PresolveFramer.frame(variables,
           product_group: product_group,
           trader_notes: trader_notes,
           model_id: model_id) do
      {:ok, %{variables: framed_vars} = framing_report} ->
        Logger.info("PresolvePipeline: #{model_id} framing complete — #{length(framing_report.adjustments)} adjustments")

        # Phase 2: Solve
        send(caller_pid, {:presolve_model_progress, model_id, :solving})

        case Solver.solve(product_group, framed_vars, solver_opts) do
          {:ok, solver_result} ->
            Logger.info("PresolvePipeline: #{model_id} solve complete — #{solver_result.status}")

            # Phase 3: Explain
            send(caller_pid, {:presolve_model_progress, model_id, :explaining})

            explanation = explain_result(model_id, framed_vars, solver_result,
                                         product_group, objective, book)

            result_map = %{
              framing: framing_report,
              solver_result: solver_result,
              explanation: explanation,
              framed_variables: framed_vars
            }

            send(caller_pid, {:presolve_model_done, model_id, result_map})
            {model_id, model_name, result_map}

          {:error, reason} ->
            Logger.warning("PresolvePipeline: #{model_id} solve failed — #{inspect(reason)}")
            send(caller_pid, {:presolve_model_error, model_id, :solve, reason})
            {model_id, model_name, %{status: :error, phase: :solve, reason: reason}}
        end

      {:error, reason} ->
        Logger.warning("PresolvePipeline: #{model_id} framing failed — #{inspect(reason)}")
        send(caller_pid, {:presolve_model_error, model_id, :frame, reason})
        {model_id, model_name, %{status: :error, phase: :frame, reason: reason}}
    end
  rescue
    e ->
      Logger.error("PresolvePipeline: #{model.id} crashed — #{Exception.message(e)}")
      send(caller_pid, {:presolve_model_error, model.id, :crash, Exception.message(e)})
      {model.id, model.name, %{status: :error, phase: :crash, reason: Exception.message(e)}}
  end

  # ── Explain a solver result using a single model ───────

  defp explain_result(model_id, variables, result, product_group, objective, book) do
    frame = ProductGroup.frame(product_group)
    prompt = build_explain_prompt(variables, result, frame, objective)

    # Anonymize counterparty names before sending to LLM
    counterparty_names = if book, do: Anonymizer.counterparty_names(book), else: []
    {anon_prompt, anon_map} = Anonymizer.anonymize(prompt, counterparty_names)

    case Pool.generate(model_id, anon_prompt, max_tokens: 1024) do
      {:ok, text} -> {:ok, Anonymizer.deanonymize(text, anon_map)}
      error -> error
    end
  end

  defp build_explain_prompt(variables, result, frame, objective) do
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

  # ── Formatting helpers (mirrors PostsolveExplainer) ────

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

  defp format_number(val) when is_float(val), do: val |> round() |> format_number()
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
    SapPositions.book_summary()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
