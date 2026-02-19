defmodule TradingDesk.TradeRepo.Migrations.CreateMarketHistory do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # RIVER STAGE HISTORY
    # Daily gauge readings from USGS for all four Mississippi gauges.
    # Populated by HistoryIngester.backfill_river/2 (one-shot or on-demand).
    # ──────────────────────────────────────────────────────────

    create table(:river_stage_history, primary_key: false) do
      add :date, :date, null: false
      add :gauge_key, :string, null: false   # "baton_rouge" | "vicksburg" | "memphis" | "cairo"
      add :stage_ft, :float                  # daily mean gauge height (ft)
      add :flow_cfs, :float                  # daily mean discharge (cfs)
      add :source, :string, null: false, default: "usgs"
      add :fetched_at, :utc_datetime, null: false
    end

    create unique_index(:river_stage_history, [:date, :gauge_key])
    create index(:river_stage_history, [:gauge_key, :date])

    # ──────────────────────────────────────────────────────────
    # AMMONIA PRICE HISTORY
    # Weekly benchmark assessments per pricing point.
    # On-demand: call HistoryIngester.snapshot_prices/0 to record today.
    # Historical backfill requires manual import from Argus/Fertecon export.
    # ──────────────────────────────────────────────────────────

    create table(:ammonia_price_history, primary_key: false) do
      add :date, :date, null: false
      add :benchmark_key, :string, null: false   # "fob_nola" | "fob_trinidad" | "cfr_tampa" etc.
      add :price_usd, :float, null: false        # USD per MT (or $/ST for domestic benchmarks)
      add :unit, :string                         # "$/MT" | "$/ST"
      add :source, :string                       # "fertecon" | "fmb" | "manual"
      add :notes, :string
      add :fetched_at, :utc_datetime, null: false
    end

    create unique_index(:ammonia_price_history, [:date, :benchmark_key])
    create index(:ammonia_price_history, [:benchmark_key, :date])

    # ──────────────────────────────────────────────────────────
    # FREIGHT RATE HISTORY
    # Barge freight rates per route.
    # On-demand: call HistoryIngester.snapshot_freight/0 to record today.
    # Historical backfill requires manual import from broker/TMS export.
    # ──────────────────────────────────────────────────────────

    create table(:freight_rate_history, primary_key: false) do
      add :date, :date, null: false
      add :route, :string, null: false    # "don_stl" | "don_mem" | "geis_stl" | "geis_mem"
      add :rate_per_ton, :float, null: false
      add :source, :string               # "broker_api" | "tms" | "manual"
      add :notes, :string
      add :fetched_at, :utc_datetime, null: false
    end

    create unique_index(:freight_rate_history, [:date, :route])
    create index(:freight_rate_history, [:route, :date])
  end
end
