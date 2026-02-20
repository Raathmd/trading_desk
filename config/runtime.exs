import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing."

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing. " <>
            "Generate with: mix phx.gen.secret"

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4111")

  config :trading_desk, TradingDesk.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [port: port, ip: {0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    check_origin: false

  config :trading_desk, TradingDesk.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
end
