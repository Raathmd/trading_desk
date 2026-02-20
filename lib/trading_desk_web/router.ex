defmodule TradingDesk.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {TradingDesk.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :require_auth do
    plug TradingDeskWeb.Plugs.RequireAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # ── Public auth routes (no login required) ───────────────────────────────
  scope "/", TradingDeskWeb do
    pipe_through :browser

    get  "/login",          AuthController, :login
    post "/login/request",  AuthController, :request_link
    get  "/auth/:token",    AuthController, :verify
    get  "/logout",         AuthController, :logout
  end

  # ── Protected trading desk (requires magic-link session) ─────────────────
  scope "/", TradingDesk do
    pipe_through [:browser, :require_auth]

    live "/",          ScenarioLive
    live "/contracts", ContractsLive
  end

  # ── SAP integration endpoints (no browser auth needed) ───────────────────
  scope "/api/sap", TradingDeskWeb do
    pipe_through :api

    post "/ping",   SapWebhookController, :ping
    get  "/status", SapWebhookController, :status
  end
end
