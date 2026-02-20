import Config

config :trading_desk, TradingDesk.Endpoint,
  url: [host: "localhost"],
  http: [port: 4111, ip: {0, 0, 0, 0}],
  check_origin: false,
  secret_key_base: String.duplicate("nh3bargetrading", 6),
  live_view: [signing_salt: "nh3livebargedesk"],
  render_errors: [formats: [html: TradingDesk.ErrorHTML]],
  pubsub_server: TradingDesk.PubSub,
  server: true


config :logger, level: :info

config :phoenix, :json_library, Jason

config :trading_desk, ecto_repos: [TradingDesk.Repo]

# Mailer — uses local (log-only) adapter in dev; overridden in runtime.exs for prod
config :trading_desk, TradingDesk.Mailer, adapter: Swoosh.Adapters.Local
