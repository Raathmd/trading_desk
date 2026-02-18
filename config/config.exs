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

# SQLite trade history database — portable, self-contained, chain-restorable.
# Stores every solve (auto + manual), all variable snapshots, contract data,
# and blockchain commit queue. Independent from the operational Postgres DB.
config :trading_desk, TradingDesk.TradeRepo,
  adapter: Ecto.Adapters.SQLite3,
  database: "priv/trade_history.db",
  pool_size: 1,
  journal_mode: :wal,
  cache_size: -64_000,
  foreign_keys: :on,
  temp_store: :memory

config :trading_desk, ecto_repos: [TradingDesk.Repo, TradingDesk.TradeRepo]
