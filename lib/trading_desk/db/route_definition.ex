defmodule TradingDesk.DB.RouteDefinition do
  @moduledoc """
  Ecto schema for route definitions.

  Each row defines one trade route (origin → destination) for a product group.
  Routes are the LP solver's decision variables — how much to ship on each lane.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "route_definitions" do
    field :product_group,         :string
    field :key,                   :string
    field :name,                  :string
    field :origin,                :string
    field :destination,           :string
    field :distance,              :float
    field :distance_unit,         :string, default: "mi"
    field :transport_mode,        :string
    field :freight_variable,      :string
    field :buy_variable,          :string
    field :sell_variable,         :string
    field :typical_transit_days,  :float
    field :transit_cost_per_day,  :float
    field :unit_capacity,         :float
    field :display_order,         :integer, default: 0
    field :active,                :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_group key name origin destination transport_mode)a
  @optional ~w(distance distance_unit freight_variable buy_variable sell_variable
               typical_transit_days transit_cost_per_day unit_capacity
               display_order active)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:key, min: 1, max: 80)
    |> validate_inclusion(:distance_unit, ~w(mi nm km), message: "must be mi, nm, or km")
    |> validate_inclusion(:transport_mode, ~w(barge ocean_vessel rail truck pipeline),
         message: "must be barge, ocean_vessel, rail, truck, or pipeline")
    |> unique_constraint([:product_group, :key])
  end
end
