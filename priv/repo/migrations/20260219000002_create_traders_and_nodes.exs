defmodule TradingDesk.Repo.Migrations.CreateTradersAndNodes do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # TRADERS
    # People who use the desk. A trader can be assigned to one
    # or more product groups. The UI dropdown simulates presence.
    # ──────────────────────────────────────────────────────────

    create table(:traders) do
      add :name,   :string, null: false
      add :email,  :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:traders, [:email], where: "email IS NOT NULL")
    create index(:traders, [:active])

    # ──────────────────────────────────────────────────────────
    # TRADER → PRODUCT GROUP ASSIGNMENTS
    # One row per trader per product group.
    # is_primary marks the group that loads by default in the UI.
    # ──────────────────────────────────────────────────────────

    create table(:trader_product_groups) do
      add :trader_id,     references(:traders, on_delete: :delete_all), null: false
      add :product_group, :string, null: false   # "ammonia_domestic" | "ammonia_international" | "petcoke" | "sulphur_international"
      add :is_primary,    :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:trader_product_groups, [:trader_id, :product_group])
    create index(:trader_product_groups, [:product_group])

    # ──────────────────────────────────────────────────────────
    # OPERATIONAL NODES
    # All physical locations used by Trammo across every product
    # group: terminals, ports, refineries, barge docks, rail yards,
    # river gauge stations, and vessel fleets.
    #
    # node_type:  terminal | barge_dock | port | refinery | rail_yard |
    #             gauge_station | vessel_fleet
    # role:       supply | demand | waypoint | monitoring
    # ──────────────────────────────────────────────────────────

    create table(:operational_nodes) do
      add :product_group, :string, null: false   # or "global" for shared nodes
      add :node_key,      :string, null: false   # short identifier e.g. "don", "geis"
      add :name,          :string, null: false   # full name e.g. "Donaldsonville, LA"
      add :node_type,     :string, null: false
      add :role,          :string, null: false
      add :country,       :string, null: false   # ISO 3166-1 alpha-2
      add :region,        :string                # geographic sub-region label
      add :lat,           :float
      add :lon,           :float
      add :capacity_mt,   :float                 # MT per year or per shipment, nullable
      add :is_trammo_owned, :boolean, default: false
      add :notes,         :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operational_nodes, [:product_group, :node_key])
    create index(:operational_nodes, [:product_group, :node_type])
    create index(:operational_nodes, [:role])

    # ──────────────────────────────────────────────────────────
    # ADD product_group TO SCENARIOS
    # Links each saved scenario to a specific product group so
    # that saves are keyed to trader + product_group together.
    # ──────────────────────────────────────────────────────────

    alter table(:scenarios) do
      add :product_group, :string
    end

    create index(:scenarios, [:trader_id, :product_group])

    # ──────────────────────────────────────────────────────────
    # MARKET HISTORY (Postgres)
    # Moved from SQLite. Daily/weekly market data used to feed
    # seasonal bounds in Monte Carlo.
    # ──────────────────────────────────────────────────────────

    create table(:river_stage_history, primary_key: false) do
      add :date,       :date,   null: false
      add :gauge_key,  :string, null: false   # "baton_rouge" | "vicksburg" | "memphis" | "cairo"
      add :stage_ft,   :float
      add :flow_cfs,   :float
      add :source,     :string, null: false, default: "usgs"
      add :fetched_at, :utc_datetime, null: false
    end

    create unique_index(:river_stage_history, [:date, :gauge_key])
    create index(:river_stage_history, [:gauge_key, :date])

    create table(:ammonia_price_history, primary_key: false) do
      add :date,          :date,   null: false
      add :benchmark_key, :string, null: false
      add :price_usd,     :float,  null: false
      add :unit,          :string
      add :source,        :string
      add :notes,         :string
      add :fetched_at,    :utc_datetime, null: false
    end

    create unique_index(:ammonia_price_history, [:date, :benchmark_key])
    create index(:ammonia_price_history, [:benchmark_key, :date])

    create table(:freight_rate_history, primary_key: false) do
      add :date,         :date,   null: false
      add :route,        :string, null: false
      add :rate_per_ton, :float,  null: false
      add :source,       :string
      add :notes,        :string
      add :fetched_at,   :utc_datetime, null: false
    end

    create unique_index(:freight_rate_history, [:date, :route])
    create index(:freight_rate_history, [:route, :date])
  end
end
