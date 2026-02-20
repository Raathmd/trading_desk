defmodule TradingDeskWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug that enforces magic-link authentication.

  Checks for an `:authenticated_email` key in the session. If absent,
  redirects to /login. Also sets `conn.assigns.current_user_email` so
  templates can display who is logged in.

  Session timeout: 8 hours of inactivity.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  @session_ttl_seconds 8 * 3600

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :authenticated_email) do
      nil ->
        conn |> redirect(to: "/login") |> halt()

      email ->
        # Check session age
        authenticated_at = get_session(conn, :authenticated_at)

        if session_fresh?(authenticated_at) do
          assign(conn, :current_user_email, email)
        else
          conn
          |> clear_session()
          |> redirect(to: "/login")
          |> halt()
        end
    end
  end

  defp session_fresh?(nil), do: false
  defp session_fresh?(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, auth_time, _} ->
        age = DateTime.diff(DateTime.utc_now(), auth_time, :second)
        age < @session_ttl_seconds

      _ ->
        false
    end
  end
end
