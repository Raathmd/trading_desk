# Trading Desk — Claude Code Notes

## After pulling new code

Always check for pending migrations before starting the server:

```bash
mix ecto.migrate
```

## Running the app

```bash
mix phx.server
# App runs at http://localhost:4111
```

## Seeding the database (first time / after DB reset)

**Local (dev):**
```bash
mix run priv/repo/seeds.exs
```

**Production on Fly.io — seeds (run once after first deploy):**
```bash
fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Release.seed()'"
```

**Production on Fly.io — migrations only (run automatically on every deploy via fly.toml):**
```bash
fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Release.migrate()'"
```

All seeds are idempotent — safe to re-run. Run order: OperationalNodeSeed → TraderSeed → NH3ContractSeed → tracked_vessels → users.

## Common tasks

- **Run tests:** `mix test`
- **Interactive shell:** `iex -S mix`
- **Check DB:** `mix ecto.migrations` (shows which migrations have/haven't run)
