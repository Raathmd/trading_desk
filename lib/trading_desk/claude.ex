defmodule TradingDesk.Claude do
  @moduledoc """
  Dedicated Claude API client for the vectorization pipeline.
  Handles semantic framing, pre-solve context building, and post-solve explanation.
  Separate from the existing TradingDesk.Analyst fallback pattern.
  """

  require Logger

  @claude_model "claude-sonnet-4-5-20250929"
  @max_tokens 1024

  @doc "Frame a raw event narrative into a semantic, searchable narrative for vectorization."
  def frame_event(narrative, event_type) do
    prompt = """
    You are a trading desk intelligence system for Trammo, a multi-commodity trading company.

    Frame the following trading decision event into a semantic narrative optimized for future
    retrieval via similarity search. The narrative should capture:
    - What decision was made and why
    - Market conditions at the time
    - How the optimizer's recommendation compared to the trader's action
    - Key risk factors and constraints
    - Any deviations from standard practice

    Event type: #{event_type}

    Raw context:
    #{narrative}

    Produce a concise, searchable narrative (200-500 words) that another trader or LLM could
    use to understand this decision in context.
    """

    complete(prompt)
  end

  @doc "Frame pre-solve context incorporating similar historical deals."
  def frame_pre_solve(context, similar_deals) do
    prompt = """
    You are a trading desk intelligence system for Trammo, a multi-commodity trading company.

    A trader is about to run an optimization for a potential deal. Frame the following context
    for decision support, incorporating relevant patterns from similar historical deals.

    Current context:
    #{Jason.encode!(context, pretty: true)}

    Similar historical deals from vector database:
    #{Jason.encode!(similar_deals, pretty: true)}

    Provide:
    1. Key risk factors based on current market conditions
    2. Patterns from similar historical deals that are relevant
    3. Specific areas where the trader should pay attention
    4. Any red flags or opportunities based on historical outcomes
    """

    complete(prompt)
  end

  @doc "Explain post-solve optimizer output in plain English."
  def explain_post_solve(recommendation, context, similar_deals) do
    prompt = """
    You are a trading desk intelligence system for Trammo, a multi-commodity trading company.

    The HiGHS optimizer has returned a recommendation. Explain this in plain English for the trader.

    Optimizer recommendation:
    #{Jason.encode!(recommendation, pretty: true)}

    Original context:
    #{Jason.encode!(context, pretty: true)}

    Historical similar deals:
    #{Jason.encode!(similar_deals || [], pretty: true)}

    Explain:
    1. What the optimizer recommends and why
    2. Key sensitivities (what would change the recommendation)
    3. How this compares to outcomes in similar historical deals
    4. Confidence level and what could go wrong
    """

    complete(prompt)
  end

  @doc "Frame a historical SAP contract for backfill vectorization."
  def frame_historical_contract(contract_data) do
    prompt = """
    You are a trading desk intelligence system for Trammo, a multi-commodity trading company.

    Frame the following historical SAP contract record into a semantic narrative optimized for
    future retrieval via vector similarity search. Extract decision-relevant patterns.

    Historical SAP contract data:
    #{Jason.encode!(contract_data, pretty: true)}

    Produce a concise, searchable narrative (200-500 words) covering:
    - Contract type, commodity, and key commercial terms
    - Counterparty and relationship context
    - Pricing strategy and market positioning
    - Risk allocation through clause structures
    - Inferred market conditions based on pricing and dates
    - Seasonal or cyclical patterns
    - Any notable characteristics useful for future decision-making
    """

    complete(prompt)
  end

  @doc "Direct Claude API call. Returns {:ok, text} or {:error, reason}."
  def complete(prompt, opts \\ []) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    unless api_key do
      {:error, :no_anthropic_api_key}
    else
      model = Keyword.get(opts, :model, @claude_model)
      max_tokens = Keyword.get(opts, :max_tokens, @max_tokens)

      case Req.post("https://api.anthropic.com/v1/messages",
        json: %{
          model: model,
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
          {:ok, text}

        {:ok, %{status: status, body: body}} ->
          Logger.error("Claude API error #{status}: #{inspect(body)}")
          {:error, "Claude API returned #{status}"}

        {:error, reason} ->
          Logger.error("Claude API request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end
end
