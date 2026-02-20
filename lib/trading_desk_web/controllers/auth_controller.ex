defmodule TradingDeskWeb.AuthController do
  use Phoenix.Controller,
    namespace: TradingDeskWeb,
    formats: [:html],
    layouts: [html: false]

  import Plug.Conn
  plug :put_view, TradingDeskWeb.AuthHTML

  alias TradingDesk.Auth.MagicLink
  alias TradingDesk.Emails.MagicLinkEmail
  alias TradingDesk.Mailer

  require Logger

  # GET /login — redirect straight to app if already authenticated
  def login(conn, _params) do
    if get_session(conn, :authenticated_email) do
      redirect(conn, to: "/")
    else
      conn
      |> put_layout(false)
      |> render(:login,
        error: nil,
        flash_error: get_flash(conn, :error),
        has_session: false
      )
    end
  end

  # POST /login/request
  def request_link(conn, %{"email" => email}) do
    # Already authenticated — send straight to app, don't issue a new token
    if get_session(conn, :authenticated_email) do
      redirect(conn, to: "/")
    else
      email = String.downcase(String.trim(email || ""))

      case MagicLink.generate(email) do
        {:ok, token} ->
          base_url = TradingDeskWeb.Endpoint.url()
          link = "#{base_url}/auth/#{token}"

          # Always log to console as fallback (visible via fly logs)
          Logger.info("\n\n========================================\n" <>
                      "MAGIC LINK for #{email}\n#{link}\n" <>
                      "========================================\n")

          # Send email — log if it fails but don't block the response
          email
          |> MagicLinkEmail.build(link)
          |> Mailer.deliver()
          |> case do
            {:ok, _} ->
              Logger.info("Magic link email sent to #{email}")
            {:error, reason} ->
              Logger.error("Failed to send magic link email to #{email}: #{inspect(reason)}")
          end

          conn
          |> put_layout(false)
          |> render(:sent)

        {:error, :rate_limited} ->
          # Indistinguishable from success — prevents probing
          conn
          |> put_layout(false)
          |> render(:sent)

        {:error, :not_allowed} ->
          conn
          |> put_layout(false)
          |> render(:login,
            error: "That email address is not authorised.",
            flash_error: nil,
            has_session: false
          )

        {:error, _} ->
          conn
          |> put_layout(false)
          |> render(:login,
            error: "Something went wrong. Please try again.",
            flash_error: nil,
            has_session: false
          )
      end
    end
  end

  def request_link(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login,
      error: "Please enter your email address.",
      flash_error: nil,
      has_session: false
    )
  end

  # GET /auth/:token
  def verify(conn, %{"token" => token}) do
    case MagicLink.verify(token) do
      {:ok, email} ->
        conn
        |> put_session(:authenticated_email, email)
        |> put_session(:authenticated_at, DateTime.utc_now() |> DateTime.to_iso8601())
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, :already_used} ->
        conn
        |> put_flash(:error, "This login link has already been used. Please request a new one.")
        |> redirect(to: "/login")

      {:error, _} ->
        conn
        |> put_flash(:error, "Invalid login link. Please request a new one.")
        |> redirect(to: "/login")
    end
  end

  # GET /logout
  def logout(conn, _params) do
    conn
    |> clear_session()
    |> redirect(to: "/login")
  end
end
