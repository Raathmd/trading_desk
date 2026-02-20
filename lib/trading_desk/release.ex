defmodule TradingDesk.Release do
  @moduledoc """
  Release tasks for running in production without Mix.

  Usage on Fly.io:
    fly ssh console -C "/app/bin/trading_desk eval 'TradingDesk.Release.migrate()'"
  """

  @app :trading_desk

  def migrate do
    load_app()
    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
