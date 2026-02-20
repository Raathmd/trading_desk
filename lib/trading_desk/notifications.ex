defmodule TradingDesk.Notifications do
  @moduledoc """
  Trader notification dispatcher.

  Sends threshold-triggered alert messages to traders via their configured
  channels (email, Slack, MS Teams) when the AutoRunner detects a material
  market move or completes an auto-solve that crosses a trader's profit threshold.

  ## Cooldown
  In-memory ETS table (`td_notify_cooldown`) tracks the last notification
  timestamp per trader. Resets on restart (intentional — conservative on quiet periods).

  ## Usage

      TradingDesk.Notifications.maybe_notify_traders(
        product_group: :ammonia_domestic,
        event:         :auto_solve,
        profit:        212_500.0,
        profit_delta:  18_000.0,
        trigger_keys:  ["river_stage", "nat_gas"],
        distribution:  dist_map,
        explanation:   nil   # may arrive later
      )
  """

  require Logger

  alias TradingDesk.Traders
  alias TradingDesk.DB.TraderRecord

  @ets_table :td_notify_cooldown

  # ── Setup ────────────────────────────────────────────────────

  @doc "Create the ETS cooldown table. Called at application start."
  def init_ets do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :set, :public, read_concurrency: true])
    end
  end

  # ── Public API ────────────────────────────────────────────────

  @doc """
  Check each active trader against their notification preferences and send
  alerts if the event clears all filters (threshold, cooldown, channel enabled).

  `opts` map/keyword list:
    - `product_group`  atom/string — used to filter traders
    - `event`          atom — `:auto_solve` | `:delta_trigger` | `:infeasible`
    - `profit`         float — current expected profit
    - `profit_delta`   float — change from previous solve (optional, defaults to 0)
    - `trigger_keys`   [string] — variable keys that triggered the solve
    - `distribution`   map — MC distribution (mean, p5, p95, signal, n_feasible, n_scenarios)
    - `explanation`    string | nil
  """
  def maybe_notify_traders(opts) do
    pg          = Keyword.get(opts, :product_group, :ammonia_domestic)
    event       = Keyword.get(opts, :event, :auto_solve)
    profit      = Keyword.get(opts, :profit) || 0.0
    profit_delta = Keyword.get(opts, :profit_delta) || 0.0
    trigger_keys = Keyword.get(opts, :trigger_keys) || []
    distribution = Keyword.get(opts, :distribution)
    explanation  = Keyword.get(opts, :explanation)

    pg_str = to_string(pg)

    # Load all active traders assigned to this product group
    traders = load_traders_for_pg(pg_str)

    for trader <- traders, not is_nil(trader.email) do
      maybe_send_to_trader(trader, %{
        product_group: pg_str,
        event: event,
        profit: profit,
        profit_delta: profit_delta,
        trigger_keys: trigger_keys,
        distribution: distribution,
        explanation: explanation
      })
    end

    :ok
  end

  # ── Internal ─────────────────────────────────────────────────

  defp load_traders_for_pg(pg_str) do
    try do
      Traders.list_active()
      |> Enum.filter(fn t ->
        Enum.any?(t.product_groups || [], &(&1.product_group == pg_str))
      end)
    rescue
      _ -> []
    end
  end

  defp maybe_send_to_trader(%TraderRecord{} = trader, event_ctx) do
    paused         = Map.get(trader, :notifications_paused, false)
    threshold      = abs(trader.notify_threshold_profit || 5000.0)
    delta_abs      = abs(event_ctx.profit_delta)
    cooldown_mins  = trader.notify_cooldown_minutes || 30

    cond do
      paused ->
        Logger.debug("Notifications: trader #{trader.name} has notifications paused, skipping")

      delta_abs < threshold ->
        Logger.debug("Notifications: delta $#{round(delta_abs)} below threshold $#{round(threshold)} for #{trader.name}")

      in_cooldown?(trader.id, cooldown_mins) ->
        Logger.debug("Notifications: #{trader.name} in cooldown, skipping")

      true ->
        record_cooldown(trader.id)
        subject = build_subject(event_ctx)
        body    = build_body(trader, event_ctx)

        spawn(fn ->
          # Email
          if Map.get(trader, :notify_email, true) && trader.email not in [nil, ""] do
            send_email(trader.email, subject, body)
          end
          # Slack
          if Map.get(trader, :notify_slack, false) && not is_nil(trader.slack_webhook_url) do
            send_slack(trader.slack_webhook_url, subject, body)
          end
          # MS Teams
          if Map.get(trader, :notify_teams, false) && not is_nil(trader.teams_webhook_url) do
            send_teams(trader.teams_webhook_url, subject, body)
          end
        end)
    end

    :ok
  end

  # ── Cooldown ─────────────────────────────────────────────────

  defp in_cooldown?(trader_id, cooldown_minutes) do
    case :ets.lookup(@ets_table, trader_id) do
      [{_, last_at}] ->
        elapsed_s = DateTime.diff(DateTime.utc_now(), last_at, :second)
        elapsed_s < cooldown_minutes * 60
      [] ->
        false
    end
  rescue
    _ -> false
  end

  defp record_cooldown(trader_id) do
    try do
      :ets.insert(@ets_table, {trader_id, DateTime.utc_now()})
    rescue
      _ -> :ok
    end
  end

  # ── Message builders ─────────────────────────────────────────

  defp build_subject(%{event: event, product_group: pg, profit: profit, profit_delta: delta}) do
    direction = if delta >= 0, do: "▲ UP", else: "▼ DOWN"
    event_label = case event do
      :auto_solve     -> "Auto-Solve"
      :delta_trigger  -> "Market Delta"
      :infeasible     -> "INFEASIBLE"
      _               -> to_string(event)
    end
    pg_label = pg |> String.replace("_", " ") |> String.upcase()
    "#{pg_label} — #{event_label}: $#{format_number(profit)} (#{direction} $#{format_number(abs(delta))})"
  end

  defp build_body(trader, ctx) do
    %{
      product_group: pg,
      event: event,
      profit: profit,
      profit_delta: delta,
      trigger_keys: trigger_keys,
      distribution: dist
    } = ctx

    pg_label    = pg |> String.replace("_", " ") |> String.upcase()
    event_label = case event do
      :auto_solve    -> "Automated Solve"
      :delta_trigger -> "Market Delta Trigger"
      :infeasible    -> "Infeasible — Model Cannot Satisfy Constraints"
      _              -> to_string(event)
    end
    direction = if delta >= 0, do: "UP", else: "DOWN"
    trigger_line = if trigger_keys != [],
      do: "\nTriggered by: #{Enum.join(trigger_keys, ", ")}",
      else: ""

    dist_lines = if dist do
      """
      Monte Carlo:
        Mean:  $#{format_number(dist.mean)}
        VaR₅:  $#{format_number(dist.p5)}
        P95:   $#{format_number(dist.p95)}
        Signal: #{dist.signal}
        Feasible: #{dist.n_feasible}/#{dist.n_scenarios}
      """
    else
      ""
    end

    exp_lines = if ctx.explanation, do: "\nAnalyst Note:\n#{ctx.explanation}\n", else: ""

    """
    Hi #{trader.name},

    The Trammo #{pg_label} Trading Desk has triggered a #{event_label}.

    Current Expected Profit: $#{format_number(profit)}
    Change from Last Solve:  #{direction} $#{format_number(abs(delta))}#{trigger_line}

    #{dist_lines}#{exp_lines}
    This is an automated alert from the Trammo Scenario Desk.
    To adjust your notification preferences, open the desk and go to your trader profile.
    """
  end

  # ── Channel senders ──────────────────────────────────────────

  defp send_email(to_email, subject, body) do
    try do
      TradingDesk.Ops.EmailPipeline.send_raw(%{
        to:      to_email,
        subject: subject,
        body:    body
      })
    rescue
      e ->
        Logger.error("Notifications: email to #{to_email} failed: #{inspect(e)}")
    catch
      :exit, reason ->
        Logger.error("Notifications: email send exited: #{inspect(reason)}")
    end
  end

  defp send_slack(webhook_url, subject, body) do
    try do
      Req.post!(webhook_url,
        json: %{
          text: "*#{subject}*\n```#{body}```"
        },
        receive_timeout: 10_000
      )
    rescue
      e -> Logger.error("Notifications: Slack webhook failed: #{inspect(e)}")
    end
  end

  defp send_teams(webhook_url, subject, body) do
    try do
      Req.post!(webhook_url,
        json: %{
          "@type": "MessageCard",
          "@context": "http://schema.org/extensions",
          "themeColor": "0891b2",
          "summary": subject,
          "sections": [
            %{
              "activityTitle": subject,
              "activityText": body
            }
          ]
        },
        receive_timeout: 10_000
      )
    rescue
      e -> Logger.error("Notifications: Teams webhook failed: #{inspect(e)}")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp format_number(nil), do: "N/A"
  defp format_number(val) when is_float(val) do
    val |> round() |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end
  defp format_number(val) when is_integer(val) do
    val |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end
  defp format_number(val), do: to_string(val)
end
