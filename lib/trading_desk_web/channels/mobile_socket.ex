defmodule TradingDeskWeb.MobileSocket do
  @moduledoc """
  WebSocket transport for native mobile clients.

  Authenticates with a Bearer token sent as the `token` URL parameter
  or in the `authorization` connect param:

    wss://host/mobile/websocket?token=<api_token>

  After connecting, the mobile client joins channels:

    "alerts:<product_group>"  — threshold breach alerts + pipeline events
    "variables:<product_group>"  — live variable updates (debounced 5s)
  """

  use Phoenix.Socket

  channel "alerts:*",    TradingDeskWeb.AlertsChannel
  channel "variables:*", TradingDeskWeb.VariablesChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case TradingDeskWeb.Plugs.MobileAuth.verify_token(token) do
      {:ok, trader_id} ->
        socket = assign(socket, :trader_id, trader_id)
        {:ok, socket}

      :error ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "mobile:#{socket.assigns.trader_id}"
end
