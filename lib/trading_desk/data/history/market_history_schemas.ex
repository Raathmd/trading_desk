defmodule TradingDesk.Data.History.RiverStageHistory do
  @moduledoc "Daily USGS gauge reading for one Mississippi River gauge."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "river_stage_history" do
    field :date, :date
    field :gauge_key, :string     # "baton_rouge" | "vicksburg" | "memphis" | "cairo"
    field :stage_ft, :float
    field :flow_cfs, :float
    field :source, :string
    field :fetched_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:date, :gauge_key, :stage_ft, :flow_cfs, :source, :fetched_at])
    |> validate_required([:date, :gauge_key, :fetched_at])
  end
end

defmodule TradingDesk.Data.History.AmmoniaPriceHistory do
  @moduledoc "Weekly ammonia benchmark price for one pricing point."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "ammonia_price_history" do
    field :date, :date
    field :benchmark_key, :string   # "fob_nola" | "cfr_tampa" etc.
    field :price_usd, :float
    field :unit, :string
    field :source, :string
    field :notes, :string
    field :fetched_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:date, :benchmark_key, :price_usd, :unit, :source, :notes, :fetched_at])
    |> validate_required([:date, :benchmark_key, :price_usd, :fetched_at])
  end
end

defmodule TradingDesk.Data.History.FreightRateHistory do
  @moduledoc "Daily barge freight rate for one Mississippi route."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "freight_rate_history" do
    field :date, :date
    field :route, :string          # "don_stl" | "don_mem" | "geis_stl" | "geis_mem"
    field :rate_per_ton, :float
    field :source, :string
    field :notes, :string
    field :fetched_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:date, :route, :rate_per_ton, :source, :notes, :fetched_at])
    |> validate_required([:date, :route, :rate_per_ton, :fetched_at])
  end
end
