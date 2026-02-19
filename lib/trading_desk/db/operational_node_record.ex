defmodule TradingDesk.DB.OperationalNodeRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operational_nodes" do
    field :product_group,    :string
    field :node_key,         :string
    field :name,             :string
    field :node_type,        :string   # terminal | barge_dock | port | refinery | rail_yard | gauge_station | vessel_fleet
    field :role,             :string   # supply | demand | waypoint | monitoring
    field :country,          :string   # ISO 3166-1 alpha-2
    field :region,           :string
    field :lat,              :float
    field :lon,              :float
    field :capacity_mt,      :float
    field :is_trammo_owned,  :boolean, default: false
    field :notes,            :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:product_group, :node_key, :name, :node_type, :role,
                    :country, :region, :lat, :lon, :capacity_mt,
                    :is_trammo_owned, :notes])
    |> validate_required([:product_group, :node_key, :name, :node_type, :role, :country])
  end
end
