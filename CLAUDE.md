# Trading Desk — Claude Code Notes

## After pulling new code

Always check for pending migrations before starting the server:

```bash
mix ecto.migrate
```

## Running the app

Always use the start script to run the app (it loads `.env` variables first):

```bash
bash start.sh
# App runs at http://localhost:4111
```

## Common tasks

- **Run tests:** `mix test`
- **Interactive shell:** `iex -S mix`
- **Check DB:** `mix ecto.migrations` (shows which migrations have/haven't run)
