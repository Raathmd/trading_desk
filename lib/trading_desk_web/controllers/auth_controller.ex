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

  # GET /login — always show the login page; magic link is the only entry point
  def login(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login,
      error: nil,
      flash_error: get_flash(conn, :error),
      users: MagicLink.list_emails()
    )
  end

  # POST /login/request
  def request_link(conn, %{"email" => email}) do
    email = String.downcase(String.trim(email || ""))

    case MagicLink.generate(email) do
      {:ok, token} ->
        base_url = TradingDesk.Endpoint.url()
        link = "#{base_url}/auth/#{token}"

        Logger.info("\n\n========================================\n" <>
                    "MAGIC LINK for #{email}\n#{link}\n" <>
                    "========================================\n")

        email
        |> MagicLinkEmail.build(link)
        |> Mailer.deliver()
        |> case do
          {:ok, _}         -> Logger.info("Magic link email sent to #{email}")
          {:error, reason} -> Logger.error("Failed to send magic link email: #{inspect(reason)}")
        end

        conn
        |> put_layout(false)
        |> render(:sent, magic_link: link)

      {:error, :rate_limited, token} ->
        base_url = TradingDesk.Endpoint.url()
        link = "#{base_url}/auth/#{token}"

        Logger.info("\n\n========================================\n" <>
                    "MAGIC LINK (rate-limited, existing token) for #{email}\n#{link}\n" <>
                    "========================================\n")

        conn
        |> put_layout(false)
        |> render(:sent, magic_link: link)

      {:error, :not_allowed} ->
        conn
        |> put_layout(false)
        |> render(:login,
          error: "That email address is not authorised.",
          flash_error: nil,
          users: MagicLink.list_emails()
        )

      {:error, _} ->
        conn
        |> put_layout(false)
        |> render(:login,
          error: "Something went wrong. Please try again.",
          flash_error: nil,
          users: MagicLink.list_emails()
        )
    end
  end

  def request_link(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:login,
      error: nil,
      flash_error: nil,
      users: MagicLink.list_emails()
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
