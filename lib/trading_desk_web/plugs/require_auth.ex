defmodule TradingDeskWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that enforces magic-link authentication.

  Checks for an :authenticated_email key in the session. If absent,
  redirects to /login. Sessions do not expire — the user must log out
  explicitly or use a new magic link.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :authenticated_email) do
      nil ->
        conn |> redirect(to: "/login") |> halt()

      email ->
        assign(conn, :current_user_email, email)
    end
  end
end
