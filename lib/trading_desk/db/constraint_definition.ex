defmodule TradingDesk.DB.ConstraintDefinition do
  @moduledoc """
  Ecto schema for solver constraint definitions.

  Each row defines one constraint in the LP model: supply caps, demand caps,
  fleet limits, or working capital bounds. Constraints bind a variable to a
  set of routes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "constraint_definitions" do
    field :product_group,       :string
    field :key,                 :string
    field :name,                :string
    field :constraint_type,     :string
    field :terminal,            :string
    field :destination,         :string
    field :bound_variable,      :string
    field :bound_min_variable,  :string
    field :outage_variable,     :string
    field :outage_factor,       :float
    field :routes,              {:array, :string}, default: []
    field :display_order,       :integer, default: 0
    field :active,              :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required ~w(product_group key name constraint_type bound_variable)a
  @optional ~w(terminal destination bound_min_variable outage_variable outage_factor
               routes display_order active)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:key, min: 1, max: 80)
    |> validate_inclusion(:constraint_type,
         ~w(supply demand_cap fleet_constraint capital_constraint),
         message: "must be supply, demand_cap, fleet_constraint, or capital_constraint")
    |> unique_constraint([:product_group, :key])
  end
end
