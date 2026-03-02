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

    live "/",          LandingLive
    live "/home",      LandingLive
    live "/desk",      ScenarioLive
    live "/whatif",    WhatifLive
    live "/contracts", ContractsLive
    live "/variables",  VariableManagerLive
    live "/api-config", ApiConfigLive
    live "/decisions",  DecisionsLive
    live "/contracts/manage", ContractManagementLive
    live "/backfill", HistoricalBackfillLive
    live "/admin/seeds", FrameSeedLive
  end

  # ── SAP integration endpoints (no browser auth needed) ───────────────────
  scope "/api/sap", TradingDeskWeb do
    pipe_through :api

    post "/ping",   SapWebhookController, :ping
    get  "/status", SapWebhookController, :status
  end

  # ── Mobile app API (Bearer token auth) ───────────────────────────────────
  pipeline :mobile_api do
    plug :accepts, ["json"]
    plug TradingDeskWeb.Plugs.MobileAuth
  end

  scope "/api/v1/mobile", TradingDeskWeb do
    pipe_through :mobile_api

    # Model: fetch the full model payload (variables + metadata + binary descriptor)
    get  "/model",            MobileApiController, :get_model
    get  "/model/descriptor", MobileApiController, :get_descriptor

    # Thresholds: fetch delta thresholds for a product group
    get  "/thresholds",       MobileApiController, :get_thresholds

    # Solves: save a device-side solve result back to the server
    post "/solves",           MobileApiController, :save_solve
  end
end
