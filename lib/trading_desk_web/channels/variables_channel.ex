defmodule TradingDeskWeb.VariablesChannel do
  @moduledoc """
  Phoenix Channel: "variables:<product_group>"

  Pushes live variable snapshots to the mobile client so it always has
  the latest values without polling.

  Events pushed to client:
    "variables_updated"  — debounced snapshot of all current variable values
    "variable_changed"   — single variable change (key, old, new, source)

  The channel subscribes to the PubSub topic used by the VariableWatcher.
  """

  use Phoenix.Channel

  require Logger

  @impl true
  def join("variables:" <> product_group, _params, socket) do
    pg = parse_pg(product_group)
    socket = assign(socket, :product_group, pg)

    Phoenix.PubSub.subscribe(TradingDesk.PubSub, "variables:#{product_group}")

    # Send current snapshot on join
    current = current_variables(pg)
    {:ok, %{product_group: product_group, variables: current}, socket}
  end

  @impl true
  def handle_info({:variables_updated, payload}, socket) do
    push(socket, "variables_updated", serialize(payload))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:variable_changed, payload}, socket) do
    push(socket, "variable_changed", serialize(payload))
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_in("get_variables", _params, socket) do
    pg = socket.assigns.product_group
    vars = current_variables(pg)
    {:reply, {:ok, %{product_group: pg, variables: vars}}, socket}
  end

  @impl true
  def handle_in(_, _, socket), do: {:noreply, socket}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp current_variables(pg) do
    try do
      case TradingDesk.Data.LiveState.get_variables(pg) do
        {:ok, vars} -> vars
        _ -> TradingDesk.ProductGroup.default_values(pg)
      end
    rescue
      _ -> TradingDesk.ProductGroup.default_values(pg)
    end
  end

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
