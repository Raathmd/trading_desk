defmodule TradingDeskWeb.AlertsChannel do
  @moduledoc """
  Phoenix Channel: "alerts:<product_group>"

  Pushes two event types to the mobile client:

  1. `threshold_breach`  — a variable has moved beyond its configured delta
     payload: %{variable: key, current: value, baseline: value, delta: delta,
               threshold: threshold, product_group: pg, timestamp: dt}

  2. `pipeline_event`   — a solve pipeline event (started, done, error)
     payload: %{event: atom, run_id: id, ...}

  The channel subscribes to the PubSub topics used by the server's
  VariableWatcher and SolvePipeline.
  """

  use Phoenix.Channel

  require Logger

  @impl true
  def join("alerts:" <> product_group, _params, socket) do
    pg = parse_pg(product_group)
    socket = assign(socket, :product_group, pg)

    # Subscribe to PubSub topics
    Phoenix.PubSub.subscribe(TradingDesk.PubSub, "threshold_alerts:#{product_group}")
    Phoenix.PubSub.subscribe(TradingDesk.PubSub, "solve_pipeline")

    Logger.info("Mobile alerts channel joined: #{product_group} by #{socket.assigns.trader_id}")

    {:ok,
     %{
       product_group: product_group,
       message: "subscribed to threshold alerts and pipeline events"
     }, socket}
  end

  @impl true
  def handle_info({:threshold_breach, payload}, socket) do
    push(socket, "threshold_breach", serialize(payload))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pipeline_event, event, payload}, socket) do
    push(socket, "pipeline_event", Map.merge(serialize(payload), %{event: event}))
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Mobile → Server messages ─────────────────────────────────────────────

  @doc """
  Mobile client can acknowledge an alert to stop repeat pushes.
  """
  @impl true
  def handle_in("ack_alert", %{"alert_id" => alert_id}, socket) do
    Logger.debug("Mobile ack_alert #{alert_id} from #{socket.assigns.trader_id}")
    {:reply, {:ok, %{acked: alert_id}}, socket}
  end

  @doc """
  Mobile client requests the current threshold config.
  """
  @impl true
  def handle_in("get_thresholds", _params, socket) do
    pg = socket.assigns.product_group
    config = TradingDesk.Config.DeltaConfig.get(pg)

    {:reply, {:ok, %{
      product_group: pg,
      thresholds: config[:thresholds] || %{}
    }}, socket}
  end

  @impl true
  def handle_in(_, _, socket), do: {:noreply, socket}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp parse_pg("ammonia_domestic"),      do: :ammonia_domestic
  defp parse_pg("ammonia_international"), do: :ammonia_international
  defp parse_pg("uan"),                   do: :uan
  defp parse_pg("urea"),                  do: :urea
  defp parse_pg("sulphur_international"), do: :sulphur_international
  defp parse_pg("petcoke"),               do: :petcoke
  defp parse_pg(_),                       do: :ammonia_domestic

  defp serialize(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {to_string(k), serialize_value(v)}
    end)
  end

  defp serialize_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp serialize_value(v) when is_atom(v), do: to_string(v)
  defp serialize_value(v), do: v
end
