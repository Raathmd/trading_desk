defmodule TradingDesk.IntentMapper do
  @moduledoc """
  Maps a trader's edited model summary (or plain-text action description) into
  solver variable adjustments and contract impact context.

  The trader edits a structured model summary that shows all current variable
  values, routes, constraints, open positions, and fleet data. They can:
    - Change variable values directly in the text
    - Add a scenario description (barge repair, weather impact, cargo redirect)
    - Leave the model unchanged (uses current variables as-is)

  All counterparty names, vessel names, and contract references are anonymized
  before being sent to the LLM. The response is de-anonymized before being
  returned to the caller.

  Uses the local HuggingFace model (Mistral 7B via Bumblebee) by default.
  Falls back to the Claude API if the local model is unavailable.

  Returns a structured intent that the pre-solve review popup displays,
  and variable adjustments that get applied before solving.
  """

  require Logger

  alias TradingDesk.ProductGroup
  alias TradingDesk.Contracts.SapPositions
  alias TradingDesk.Contracts.Store, as: ContractStore
  alias TradingDesk.Trader.DeliverySchedule
  alias TradingDesk.Anonymizer
  alias TradingDesk.LLM.{Pool, ModelRegistry}

  @claude_model "claude-sonnet-4-5-20250929"

  @doc """
  Parse trader intent and produce a structured solve context.

  Returns:
    {:ok, %{
      summary: "one-line summary of what will be tested",
      variable_adjustments: %{key => new_value},
      affected_contracts: [%{counterparty, direction, impact_description, open_qty}],
      risk_notes: ["list of risks or penalties that may be triggered"],
      position_context: %{net_position, total_purchase, total_sale}
    }}

  Or {:error, reason} if parsing fails.
  """
  def parse_intent(action_text, current_vars, product_group \\ :ammonia_domestic) do
    frame = ProductGroup.frame(product_group)
    book = SapPositions.book_summary()

    # Collect sensitive names for anonymization
    counterparty_names = Anonymizer.counterparty_names(book)

    # Anonymize the trader's input (model summary text) using same map for all strings
    {[anon_action, anon_positions], anon_map} =
      Anonymizer.anonymize_many(
        [action_text, format_positions(book)],
        counterparty_names
      )

    vars_text = format_current_vars(current_vars, frame)

    # Load active delivery schedules for penalty exposure context
    active_contracts = safe_active_contracts(product_group)
    schedules = DeliverySchedule.from_contracts(active_contracts)
    delivery_text =
      if schedules != [],
        do: DeliverySchedule.format_for_prompt(schedules),
        else: "No active delivery schedules loaded."
    total_exposure = DeliverySchedule.total_daily_exposure(schedules)

    # Anonymize delivery text too
    {anon_delivery, _} = Anonymizer.anonymize(delivery_text, counterparty_names)

    is_model_summary = String.contains?(action_text, "--- ENVIRONMENT ---") or
                       String.contains?(action_text, "[ENVIRONMENT")

    input_section =
      if is_model_summary do
        """
        The trader has reviewed and edited the full model summary below.
        They may have: (1) changed specific variable values, (2) added a scenario
        description in the [TRADER SCENARIO] section, or (3) left it unchanged.

        EDITED MODEL SUMMARY (entity names anonymized):
        #{anon_action}
        """
      else
        """
        The trader described this scenario they want to test:
        "#{anon_action}"
        """
      end

    prompt = """
    You are a commodity trading desk optimization system. Your job is to interpret
    the trader's input and produce a structured JSON that maps their intent to
    solver variable adjustments and contract impacts.

    #{input_section}

    CANONICAL SOLVER VARIABLES (current live values — detect if trader changed any):
    #{vars_text}

    OPEN BOOK POSITIONS (entity codes are anonymized — use the same codes in your response):
    #{anon_positions}
    Net position: #{book.net_position} MT (positive = we are long)

    DELIVERY SCHEDULES (by daily penalty exposure):
    #{anon_delivery}
    Total daily exposure if all deliveries slip: $#{round(total_exposure)}/day

    AVAILABLE SOLVER OBJECTIVES:
    - max_profit: Maximize total profit across all routes
    - min_cost: Minimize total cost (best when capital or fleet is constrained)
    - max_roi: Maximize return on working capital
    - cvar_adjusted: CVaR-adjusted optimization (reduces tail risk)
    - min_risk: Minimize risk exposure (most conservative)

    INSTRUCTIONS — return ONLY a JSON object (no markdown, no explanation):

    {
      "summary": "One-line summary of what scenario is being tested",
      "variable_adjustments": {"solver_variable_key": new_numeric_value},
      "affected_contracts": [
        {"counterparty": "ENTITY_XX (use anonymized code)", "direction": "purchase|sale", "impact": "description", "open_qty_change": 0}
      ],
      "risk_notes": ["any penalties or contract risks this scenario triggers"],
      "confidence": "high|medium|low",
      "objective": "max_profit|min_cost|max_roi|cvar_adjusted|min_risk",
      "event_type": "barge_failure|port_outage|market_move|volume_change|weather_impact|cargo_redirect|other",
      "priority_deliveries": ["ENTITY_XX codes of counterparties to serve first"],
      "deferred_deliveries": ["ENTITY_XX codes of counterparties whose delivery can defer"],
      "penalty_exposure": 0.0
    }

    Rules:
    - variable_adjustments keys MUST match the canonical solver variable keys shown above
    - If the input is a model summary, detect changes by comparing values to the canonical list
    - Only include variables that differ from the canonical values
    - For fleet events (barge failure/repair): reduce barge_count by the affected number
    - For weather impacts: adjust river_stage, wind_mph, vis_mi, precip_in, temp_f as described
    - For cargo redirect / volume change: note affected_contracts with the anonymized entity codes
    - penalty_exposure = estimated $ if deferred deliveries slip past their grace period
    - Use the anonymized entity codes (ENTITY_01, etc.) throughout — do NOT use real names
    - Return ONLY the JSON, nothing else
    """

    case call_llm(prompt) do
      {:ok, json_text} ->
        result = parse_json_response(json_text, book)
        # De-anonymize counterparty codes in the response
        deanonymize_result(result, anon_map)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────

  defp format_current_vars(vars, frame) do
    (frame[:variables] || [])
    |> Enum.map_join("\n", fn v ->
      val = Map.get(vars, v[:key])
      "- #{v[:key]}: #{val} (#{v[:label]}, #{v[:unit]})"
    end)
  end

  defp format_positions(book) do
    book.positions
    |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
    |> Enum.map_join("\n", fn {name, pos} ->
      dir = if pos.direction == :purchase, do: "BUY", else: "SELL"
      "- #{name}: #{dir} #{pos.incoterm |> to_string() |> String.upcase()} | " <>
      "contract=#{pos.total_qty_mt} MT, delivered=#{pos.delivered_qty_mt} MT, " <>
      "open=#{pos.open_qty_mt} MT (#{pos.contract_number})"
    end)
  end

  defp parse_json_response(json_text, book) do
    # Strip markdown code fences if present
    cleaned =
      json_text
      |> String.replace(~r/^```json\s*/m, "")
      |> String.replace(~r/^```\s*/m, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, parsed} ->
        {:ok, %{
          summary: Map.get(parsed, "summary", "Trading action"),
          variable_adjustments: parse_adjustments(Map.get(parsed, "variable_adjustments", %{})),
          affected_contracts: parse_affected(Map.get(parsed, "affected_contracts", [])),
          risk_notes: Map.get(parsed, "risk_notes", []),
          confidence: String.to_atom(Map.get(parsed, "confidence", "medium")),
          position_context: %{
            net_position: book.net_position,
            total_purchase: book.total_purchase_open,
            total_sale: book.total_sale_open
          },
          objective: parse_objective(Map.get(parsed, "objective")),
          event_type: parse_event_type(Map.get(parsed, "event_type")),
          priority_deliveries: Map.get(parsed, "priority_deliveries", []),
          deferred_deliveries: Map.get(parsed, "deferred_deliveries", []),
          penalty_exposure: parse_number(Map.get(parsed, "penalty_exposure", 0))
        }}

      {:error, _} ->
        Logger.warning("IntentMapper: failed to parse JSON from Claude response")
        {:ok, %{
          summary: "Could not parse action — using current variables as-is",
          variable_adjustments: %{},
          affected_contracts: [],
          risk_notes: ["Intent could not be mapped to specific variables"],
          confidence: :low,
          position_context: %{
            net_position: book.net_position,
            total_purchase: book.total_purchase_open,
            total_sale: book.total_sale_open
          },
          objective: nil,
          event_type: nil,
          priority_deliveries: [],
          deferred_deliveries: [],
          penalty_exposure: 0.0
        }}
    end
  end

  defp parse_adjustments(adj) when is_map(adj) do
    Map.new(adj, fn {k, v} ->
      key = String.to_atom(k)
      val = if is_number(v), do: v / 1, else: parse_number(v)
      {key, val}
    end)
  end
  defp parse_adjustments(_), do: %{}

  defp parse_affected(contracts) when is_list(contracts) do
    Enum.map(contracts, fn c ->
      %{
        counterparty: Map.get(c, "counterparty", "Unknown"),
        direction: Map.get(c, "direction", "unknown"),
        impact: Map.get(c, "impact", ""),
        open_qty_change: Map.get(c, "open_qty_change", 0)
      }
    end)
  end
  defp parse_affected(_), do: []

  # De-anonymize entity codes in the returned intent struct
  defp deanonymize_result({:error, _} = err, _anon_map), do: err
  defp deanonymize_result({:ok, intent}, anon_map) when map_size(anon_map) == 0, do: {:ok, intent}
  defp deanonymize_result({:ok, intent}, anon_map) do
    updated = intent
      |> Map.update(:affected_contracts, [], fn contracts ->
        Enum.map(contracts, fn c ->
          Map.update(c, :counterparty, nil, &Anonymizer.deanonymize(&1, anon_map))
          |> Map.update(:impact, nil, &Anonymizer.deanonymize(&1, anon_map))
        end)
      end)
      |> Map.update(:priority_deliveries, [], &Anonymizer.deanonymize_list(&1, anon_map))
      |> Map.update(:deferred_deliveries, [], &Anonymizer.deanonymize_list(&1, anon_map))
      |> Map.update(:risk_notes, [], &Anonymizer.deanonymize_list(&1, anon_map))
      |> Map.update(:summary, "", &Anonymizer.deanonymize(&1, anon_map))
    {:ok, updated}
  end

  defp parse_number(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_number(v) when is_number(v), do: v / 1
  defp parse_number(_), do: 0.0

  @valid_objectives ~w[max_profit min_cost max_roi cvar_adjusted min_risk]
  defp parse_objective(s) when is_binary(s) and s in @valid_objectives, do: String.to_atom(s)
  defp parse_objective(_), do: nil

  @valid_event_types ~w[barge_failure port_outage market_move volume_change other]
  defp parse_event_type(s) when is_binary(s) and s in @valid_event_types, do: String.to_atom(s)
  defp parse_event_type(s) when is_binary(s), do: :other
  defp parse_event_type(_), do: nil

  defp safe_active_contracts(product_group) do
    ContractStore.get_active_set(product_group)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # Uses the local Bumblebee model (Mistral 7B) by default.
  # Falls back to Claude API if the local model is unavailable.
  defp call_llm(prompt) do
    default_model = ModelRegistry.default()

    case Pool.generate(default_model.id, prompt, max_tokens: 500) do
      {:ok, _text} = ok ->
        ok

      {:error, reason} ->
        Logger.warning("IntentMapper: local LLM failed (#{inspect(reason)}), trying Claude")
        call_claude_fallback(prompt)
    end
  end

  defp call_claude_fallback(prompt) do
    api_key = System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      case Req.post("https://api.anthropic.com/v1/messages",
        json: %{
          model: @claude_model,
          max_tokens: 500,
          messages: [%{role: "user", content: prompt}]
        },
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 15_000
      ) do
        {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]}}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: status, body: body}} ->
          Logger.error("IntentMapper Claude fallback error #{status}: #{inspect(body)}")
          {:error, :api_error}

        {:error, reason} ->
          Logger.error("IntentMapper Claude fallback failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end
end
