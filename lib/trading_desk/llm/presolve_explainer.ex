defmodule TradingDesk.LLM.PresolveExplainer do
  @moduledoc """
  Generates plain-English explanations of the presolve frame using all
  registered HuggingFace models.

  Takes the model summary text (the same structured text shown in the
  pre-solve review popup) and asks each LLM to explain:
    - What optimization problem is being set up
    - Key variables, constraints, and market conditions
    - What the solver will try to achieve given the chosen objective

  Results are returned as a list of `{model_id, model_name, explanation}`
  tuples, one per registered model.
  """

  require Logger

  alias TradingDesk.LLM.Pool
  alias TradingDesk.Anonymizer

  @doc """
  Explain the presolve frame using all registered models in parallel.

  `model_summary` is the plain-text model summary built by ScenarioLive.
  `book` is the SAP book summary (used for anonymization).
  `objective` is the solver objective atom.

  Returns `[{model_id, model_name, {:ok, text} | {:error, reason}}]`.
  """
  @spec explain_all(String.t(), map() | nil, atom()) :: [{atom(), String.t(), {:ok, String.t()} | {:error, term()}}]
  def explain_all(model_summary, book, objective \\ :max_profit) do
    # Anonymize before sending to external models
    counterparty_names = if book, do: Anonymizer.counterparty_names(book), else: []
    {anon_summary, anon_map} = Anonymizer.anonymize(model_summary || "", counterparty_names)

    prompt = build_presolve_prompt(anon_summary, objective)

    results = Pool.generate_all(prompt, max_tokens: 800)

    # De-anonymize each successful response
    Enum.map(results, fn {model_id, model_name, result} ->
      deanon_result =
        case result do
          {:ok, text} -> {:ok, Anonymizer.deanonymize(text, anon_map)}
          error -> error
        end

      {model_id, model_name, deanon_result}
    end)
  end

  @doc """
  Explain the presolve frame using a single model.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec explain(atom(), String.t(), map() | nil, atom()) :: {:ok, String.t()} | {:error, term()}
  def explain(model_id, model_summary, book, objective \\ :max_profit) do
    counterparty_names = if book, do: Anonymizer.counterparty_names(book), else: []
    {anon_summary, anon_map} = Anonymizer.anonymize(model_summary || "", counterparty_names)

    prompt = build_presolve_prompt(anon_summary, objective)

    case Pool.generate(model_id, prompt, max_tokens: 800) do
      {:ok, text} -> {:ok, Anonymizer.deanonymize(text, anon_map)}
      error -> error
    end
  end

  defp build_presolve_prompt(anon_summary, objective) do
    obj_label = objective_label(objective)

    """
    You are a senior commodity trading analyst reviewing a linear programming model
    before it is submitted to the solver.

    The trader has configured the following optimization model. Your job is to explain
    in plain English:
    1. What trading problem is being solved and why (the business context)
    2. The key variables and what they represent (prices, volumes, conditions)
    3. Which constraints are likely to be binding and why
    4. What the #{obj_label} objective means for the expected allocation
    5. Any risks or notable conditions visible in the current data

    MODEL STATE:
    #{anon_summary}

    SOLVER OBJECTIVE: #{obj_label}

    Write a clear, concise explanation (4-6 sentences) that a trader can scan quickly.
    Focus on what matters for the trading decision. Use plain prose, no bullet lists.
    """
  end

  defp objective_label(:max_profit), do: "Maximize Profit"
  defp objective_label(:min_cost), do: "Minimize Cost"
  defp objective_label(:max_roi), do: "Maximize ROI"
  defp objective_label(:cvar_adjusted), do: "CVaR-Adjusted (risk-weighted)"
  defp objective_label(:min_risk), do: "Minimize Risk"
  defp objective_label(_), do: "Maximize Profit"
end
