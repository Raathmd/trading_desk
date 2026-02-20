defmodule TradingDesk.TradeDB.Solve do
  @moduledoc "Core solve record — one row per pipeline execution."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "solves" do
    field :solve_type, :string         # "single" | "monte_carlo"
    field :trigger_source, :string     # "dashboard" | "auto_runner" | "api" | "scheduled"
    field :product_group, :string
    field :trader_id, :string
    field :is_auto_solve, :boolean, default: false

    field :contracts_checked, :boolean, default: false
    field :contracts_stale, :boolean, default: false
    field :contracts_stale_reason, :string
    field :contracts_ingested, :integer, default: 0

    field :result_status, :string
    field :chain_commit_id, :string

    field :started_at, :utc_datetime
    field :contracts_checked_at, :utc_datetime
    field :ingestion_completed_at, :utc_datetime
    field :solve_started_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id, :solve_type, :trigger_source, :product_group, :trader_id, :is_auto_solve,
      :contracts_checked, :contracts_stale, :contracts_stale_reason, :contracts_ingested,
      :result_status, :chain_commit_id,
      :started_at, :contracts_checked_at, :ingestion_completed_at,
      :solve_started_at, :completed_at
    ])
    |> validate_required([:id, :solve_type, :trigger_source, :product_group, :started_at])
  end
end

defmodule TradingDesk.TradeDB.SolveVariables do
  @moduledoc "All 20 solver variable values at the moment a solve ran (1:1 with solves)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:solve_id, :string, autogenerate: false}

  schema "solve_variables" do
    # Environmental
    field :river_stage, :float
    field :lock_hrs, :float
    field :temp_f, :float
    field :wind_mph, :float
    field :vis_mi, :float
    field :precip_in, :float

    # Operations
    field :inv_don, :float
    field :inv_geis, :float
    field :stl_outage, :boolean
    field :mem_outage, :boolean
    field :barge_count, :float

    # Commercial
    field :nola_buy, :float
    field :sell_stl, :float
    field :sell_mem, :float
    field :fr_don_stl, :float
    field :fr_don_mem, :float
    field :fr_geis_stl, :float
    field :fr_geis_mem, :float
    field :nat_gas, :float
    field :working_cap, :float
  end

  @fields [
    :solve_id,
    :river_stage, :lock_hrs, :temp_f, :wind_mph, :vis_mi, :precip_in,
    :inv_don, :inv_geis, :stl_outage, :mem_outage, :barge_count,
    :nola_buy, :sell_stl, :sell_mem,
    :fr_don_stl, :fr_don_mem, :fr_geis_stl, :fr_geis_mem,
    :nat_gas, :working_cap
  ]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields)
    |> validate_required([:solve_id])
  end
end

defmodule TradingDesk.TradeDB.SolveVariableSources do
  @moduledoc "API fetch timestamps for each data source at solve time (1:1 with solves)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:solve_id, :string, autogenerate: false}

  schema "solve_variable_sources" do
    field :usgs_fetched_at, :utc_datetime
    field :noaa_fetched_at, :utc_datetime
    field :usace_fetched_at, :utc_datetime
    field :eia_fetched_at, :utc_datetime
    field :internal_fetched_at, :utc_datetime
    field :broker_fetched_at, :utc_datetime
    field :market_fetched_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :solve_id,
      :usgs_fetched_at, :noaa_fetched_at, :usace_fetched_at, :eia_fetched_at,
      :internal_fetched_at, :broker_fetched_at, :market_fetched_at
    ])
    |> validate_required([:solve_id])
  end
end

defmodule TradingDesk.TradeDB.SolveDeltaConfig do
  @moduledoc "Snapshot of DeltaConfig thresholds active at solve time (1:1 with solves)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:solve_id, :string, autogenerate: false}

  schema "solve_delta_config" do
    field :enabled, :boolean, default: false
    field :n_scenarios, :integer
    field :min_solve_interval_ms, :integer
    field :thresholds_json, :string        # JSON: %{variable_key => threshold_float}
    field :triggered_mask, :integer, default: 0  # u32 bitmask (updated by auto_solve_triggers)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_id, :enabled, :n_scenarios, :min_solve_interval_ms,
                    :thresholds_json, :triggered_mask])
    |> validate_required([:solve_id])
  end
end
