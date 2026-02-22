defmodule TradingDesk.Release do
  @moduledoc """
  Release tasks for running in production without Mix.

  ## Running on Fly.io

  ### Migrations (run automatically on every deploy via fly.toml [deploy]):
      fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Release.migrate()'"

  ### Seed data (run once after first deploy, or after a database reset):
      fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Release.seed()'"

  ### Seed individual modules:
      fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Seeds.OperationalNodeSeed.run()'"
      fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Seeds.TraderSeed.run()'"
      fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Seeds.NH3ContractSeed.run()'"

  ## When to seed

  | Seed                   | When                                            |
  |------------------------|-------------------------------------------------|
  | OperationalNodeSeed    | First deploy; safe to re-run (idempotent)       |
  | TraderSeed             | First deploy; safe to re-run (idempotent)       |
  | NH3ContractSeed        | First deploy or after contract data reset       |
  | tracked_vessels seed   | First deploy; safe to re-run (upsert-based)     |
  | users seed             | First deploy; safe to re-run (upsert-based)     |

  ## Local (dev) seeding via Mix:
      mix run priv/repo/seeds/users.exs
      mix run priv/repo/seeds/tracked_vessels.exs
      # or run all at once:
      mix run priv/repo/seeds.exs
  """

  @app :trading_desk

  # ── Migrations ─────────────────────────────────────────────────────

  def migrate do
    load_app()
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
    :ok
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # ── Seeds ───────────────────────────────────────────────────────────

  @doc """
  Run all seed modules and scripts.
  Safe to re-run: each seed is idempotent (insert-if-not-exists or upsert).
  """
  def seed do
    load_app()

    require Logger

    Logger.info("Seeds: starting OperationalNodeSeed")
    TradingDesk.Seeds.OperationalNodeSeed.run()

    Logger.info("Seeds: starting TraderSeed")
    TradingDesk.Seeds.TraderSeed.run()

    Logger.info("Seeds: starting NH3ContractSeed")
    TradingDesk.Seeds.NH3ContractSeed.run()

    Logger.info("Seeds: running tracked_vessels script")
    run_script("priv/repo/seeds/tracked_vessels.exs")

    Logger.info("Seeds: running users script")
    run_script("priv/repo/seeds/users.exs")

    Logger.info("Seeds: all complete")
    :ok
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp run_script(relative_path) do
    app_dir = Application.app_dir(@app)
    # In a release the priv dir is inside the app dir; in dev fall back to CWD
    path =
      [app_dir, relative_path]
      |> Path.join()
      |> then(fn p -> if File.exists?(p), do: p, else: relative_path end)

    Code.eval_file(path)
  end
end

