defmodule TradingDeskWeb.Plugs.MobileAuth do
  @moduledoc """
  Authenticates mobile API requests via Bearer token.

  The token is looked up in the `mobile_api_tokens` table.
  On success, sets `conn.assigns.mobile_trader_id`.

  Usage in router:
      pipeline :mobile_api do
        plug :accepts, ["json"]
        plug TradingDeskWeb.Plugs.MobileAuth
      end
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  def init(opts), do: opts

  @doc "Verify a token string directly — used by MobileSocket."
  def verify_token(token), do: lookup_token(token)

  def call(conn, _opts) do
    case extract_token(conn) do
      {:ok, token} ->
        case lookup_token(token) do
          {:ok, trader_id} ->
            conn |> assign(:mobile_trader_id, trader_id)

          :error ->
            conn
            |> put_status(:unauthorized)
            |> json(%{error: "invalid or expired token"})
            |> halt()
        end

      :error ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authorization header required (Bearer <token>)"})
        |> halt()
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      ["bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp lookup_token(token) do
    try do
      import Ecto.Query
      result =
        from(t in TradingDesk.DB.MobileApiToken,
          where: t.token == ^token and t.revoked == false,
          where: is_nil(t.expires_at) or t.expires_at > ^DateTime.utc_now(),
          select: t.trader_id,
          limit: 1
        )
        |> TradingDesk.Repo.one()

      case result do
        nil -> :error
        trader_id -> {:ok, trader_id}
      end
    rescue
      e ->
        Logger.warning("MobileAuth: token lookup failed: #{inspect(e)}")
        # In dev, fall through to a dev bypass if no DB is available
        dev_bypass(token)
    end
  end

  # Dev mode: accept "dev-token-<email>" without a DB
  defp dev_bypass("dev-token-" <> trader_id) when byte_size(trader_id) > 0 do
    if Mix.env() == :dev do
      {:ok, trader_id}
    else
      :error
    end
  end
  defp dev_bypass(_), do: :error
end
