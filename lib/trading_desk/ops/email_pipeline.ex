defmodule TradingDesk.Ops.EmailPipeline do
  @moduledoc """
  Ops handover pipeline for the trading desk.

  When a trader confirms and solves a scenario, this module formats the
  full context into a structured plain-text email and dispatches it to
  the operations team for SAP data entry.

  Currently this logs the formatted email body; a real SMTP / SendGrid
  integration can be dropped in by replacing `dispatch/1`.

  The email covers:
    - Trader's stated action (intent)
    - Variable adjustments applied before the solve
    - Affected contracts and counterparty positions
    - Solve result (profit, tons, barges, ROI)
    - Delivery schedule impact and estimated penalty exposure
    - Checklist of SAP entries the ops team needs to make
  """

  require Logger

  @ops_email "ops@trammo.com"

  @doc """
  Format and dispatch the ops handover email.

  `ctx` is the map assembled in ScenarioLive's `save_and_send_ops` handler:
    %{
      trader_id:       binary,
      trader_action:   binary,
      intent:          map | nil,
      objective:       atom,
      result:          map,
      delivery_impact: map | nil,
      variables:       map,
      timestamp:       binary,
      summary:         binary
    }
  """
  def send(ctx) do
    body = format_email(ctx)
    dispatch(%{
      to:      @ops_email,
      subject: "[Trammo Trading Desk] #{ctx.summary} — #{ctx.timestamp}",
      body:    body
    })
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp dispatch(%{to: to, subject: subject, body: body}) do
    # TODO: replace with Swoosh / SendGrid / SMTP when credentials are configured.
    Logger.info("""
    ============================================================
    OPS EMAIL QUEUED
    To:      #{to}
    Subject: #{subject}
    ------------------------------------------------------------
    #{body}
    ============================================================
    """)
    :ok
  end

  defp format_email(ctx) do
    sections = [
      header(ctx),
      trader_intent_section(ctx),
      variable_adjustments_section(ctx),
      solve_result_section(ctx),
      delivery_impact_section(ctx),
      sap_checklist_section(ctx),
      footer(ctx)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp header(ctx) do
    """
    TRAMMO TRADING DESK — OPS HANDOVER
    Generated: #{ctx.timestamp} UTC
    Trader:    #{ctx.trader_id}
    Objective: #{format_objective(ctx.objective)}
    """
    |> String.trim()
  end

  defp trader_intent_section(ctx) do
    action = ctx.trader_action || ""
    intent = ctx.intent

    lines = ["## TRADER ACTION", ""]

    lines =
      if action != "" do
        lines ++ [action, ""]
      else
        lines ++ ["(no action text entered)", ""]
      end

    lines =
      if intent && intent.summary && intent.summary != "" do
        lines ++ ["AI interpretation: #{intent.summary}"]
      else
        lines
      end

    lines =
      if intent && intent.confidence do
        lines ++ ["Confidence: #{intent.confidence}"]
      else
        lines
      end

    lines =
      if intent && intent.event_type do
        lines ++ ["Event type: #{intent.event_type}"]
      else
        lines
      end

    risk_notes = (intent && intent.risk_notes) || []

    lines =
      if risk_notes != [] do
        risk_lines = Enum.map(risk_notes, &"  ⚠ #{&1}")
        lines ++ ["", "Risk notes:"] ++ risk_lines
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp variable_adjustments_section(ctx) do
    adj = (ctx.intent && ctx.intent.variable_adjustments) || %{}

    if map_size(adj) == 0 do
      nil
    else
      rows =
        Enum.map(adj, fn {k, v} ->
          original = Map.get(ctx.variables, k)
          "  #{k}: #{original} → #{v}"
        end)

      (["## VARIABLE ADJUSTMENTS APPLIED", ""] ++ rows)
      |> Enum.join("\n")
    end
  end

  defp solve_result_section(%{result: nil}), do: nil

  defp solve_result_section(%{result: result}) do
    if result.status == :optimal do
      route_lines =
        (result.route_tons || [])
        |> Enum.with_index()
        |> Enum.filter(fn {tons, _} -> tons > 0.5 end)
        |> Enum.map(fn {tons, _idx} ->
          "  #{round(tons)} MT"
        end)

      lines =
        [
          "## SOLVE RESULT",
          "",
          "  Status:       OPTIMAL",
          "  Gross Profit: $#{format_number(result.profit)}",
          "  Total Tons:   #{format_number(result.tons)} MT",
          "  Barges Used:  #{Float.round(result.barges, 1)}",
          "  ROI:          #{Float.round(result.roi, 1)}%",
          "  Capital:      $#{format_number(result.cost)}"
        ]

      lines =
        if route_lines != [] do
          lines ++ ["", "  Active routes:"] ++ route_lines
        else
          lines
        end

      Enum.join(lines, "\n")
    else
      "## SOLVE RESULT\n\n  Status: #{result.status}"
    end
  end

  defp delivery_impact_section(%{delivery_impact: nil}), do: nil
  defp delivery_impact_section(%{delivery_impact: di}) when di == %{}, do: nil

  defp delivery_impact_section(%{delivery_impact: di}) do
    customers = di.by_customer || []

    if customers == [] do
      nil
    else
      header_lines = [
        "## DELIVERY SCHEDULE IMPACT",
        "",
        "  Deferred deliveries:     #{di.deferred_count}",
        "  Total penalty exposure:  ~$#{format_number(round(di.total_penalty_exposure))}",
        ""
      ]

      customer_lines =
        Enum.flat_map(customers, fn c ->
          status_label =
            case c.status do
              :deferred       -> "DEFERRED   ⚠"
              :priority       -> "PRIORITY   ✓"
              :supplier       -> "SUPPLIER   ↓"
              :future_window  -> "FUT WINDOW ·"
              :open_unaffected -> "ON SCHEDULE·"
              _               -> "UNKNOWN    ·"
            end

          penalty_str =
            if c.penalty_estimate > 0 do
              " | est. penalty: ~$#{format_number(round(c.penalty_estimate))}"
            else
              ""
            end

          ["  [#{status_label}] #{c.counterparty} — #{round(c.scheduled_qty_mt)} MT #{c.frequency}#{penalty_str}"]
        end)

      (header_lines ++ customer_lines) |> Enum.join("\n")
    end
  end

  defp sap_checklist_section(ctx) do
    intent  = ctx.intent
    result  = ctx.result
    di      = ctx.delivery_impact

    affected = (intent && intent.affected_contracts) || []
    deferred =
      if di do
        (di.by_customer || [])
        |> Enum.filter(&(&1.status == :deferred))
        |> Enum.map(& &1.counterparty)
      else
        []
      end

    items = ["## SAP DATA ENTRY CHECKLIST", "", "Please action the following in SAP:"]

    items =
      if result && result.status == :optimal do
        items ++ [
          "",
          "  [ ] Update transport order quantities per route (see Solve Result above)",
          "  [ ] Confirm barge allocation: #{Float.round(result.barges, 1)} barges"
        ]
      else
        items
      end

    items =
      if affected != [] do
        contract_lines =
          Enum.map(affected, fn c ->
            dir = if c.direction == "purchase", do: "BUY", else: "SELL"
            "  [ ] #{dir} — #{c.counterparty}: #{c.impact}"
          end)

        items ++ ["", "  Affected contracts:"] ++ contract_lines
      else
        items
      end

    items =
      if deferred != [] do
        deferred_lines = Enum.map(deferred, &"  [ ] DEFERRED: #{&1} — notify counterparty, update SAP delivery date")
        items ++ ["", "  Deferred deliveries to update:"] ++ deferred_lines
      else
        items
      end

    items =
      items ++
        [
          "",
          "  [ ] Attach this email to the relevant SAP contract records",
          "  [ ] Confirm with trader (#{ctx.trader_id}) once SAP is updated"
        ]

    Enum.join(items, "\n")
  end

  defp footer(ctx) do
    """
    ---
    This message was generated automatically by the Trammo Trading Desk.
    Scenario reference: #{ctx.trader_id}/#{ctx.timestamp}
    Do not reply to this email — contact the trader directly if clarification is needed.
    """
    |> String.trim()
  end

  defp format_objective(:max_profit),    do: "Maximize Profit"
  defp format_objective(:min_cost),      do: "Minimize Cost"
  defp format_objective(:max_roi),       do: "Maximize ROI"
  defp format_objective(:cvar_adjusted), do: "CVaR-Adjusted"
  defp format_objective(:min_risk),      do: "Minimize Risk"
  defp format_objective(other),          do: to_string(other)

  defp format_number(n) when is_float(n),   do: n |> round() |> format_number()
  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
  defp format_number(n), do: to_string(n)
end
