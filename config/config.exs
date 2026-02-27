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

config :trading_desk, TradingDesk.Repo,
  username: "trading_desk",
  password: "trading_desk",
  hostname: "localhost",
  database: "trading_desk_dev",
  pool_size: 10

config :trading_desk, ecto_repos: [TradingDesk.Repo, TradingDesk.TradeRepo]

# Mailer — uses local (log-only) adapter in dev; overridden in runtime.exs for prod
config :trading_desk, TradingDesk.Mailer, adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, Swoosh.ApiClient.Finch

# Nx / EXLA — default backend for Bumblebee model inference
config :nx, default_backend: EXLA.Backend

# LLM models to load at startup.
# Each 7B model needs ~8 GB RAM. Comment out models to reduce memory usage.
# Available: :mistral_7b, :zephyr_7b, :claude_sonnet
# Set to nil or remove to load ALL registered models.
# config :trading_desk, :llm_enabled_models, [:mistral_7b]
config :trading_desk, :llm_enabled_models, [:claude_opus, :claude_haiku]
