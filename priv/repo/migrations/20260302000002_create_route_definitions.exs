defmodule TradingDesk.Repo.Migrations.CreateRouteDefinitions do
  use Ecto.Migration

  def change do
    create table(:route_definitions) do
      add :product_group,         :string,  null: false   # FK to product_group_configs.key
      add :key,                   :string,  null: false   # e.g. "mer_stl"
      add :name,                  :string,  null: false   # "Mer→StL"
      add :origin,                :string,  null: false   # "Meredosia, IL"
      add :destination,           :string,  null: false   # "St. Louis, MO"
      add :distance,              :float                  # 100 (miles) or 8900 (nm)
      add :distance_unit,         :string,  default: "mi" # "mi" | "nm"
      add :transport_mode,        :string,  null: false   # "barge" | "ocean_vessel"
      add :freight_variable,      :string                 # variable key for freight cost
      add :buy_variable,          :string                 # variable key for buy price
      add :sell_variable,         :string                 # variable key for sell price
      add :typical_transit_days,  :float
      add :transit_cost_per_day,  :float
      add :unit_capacity,         :float
      add :display_order,         :integer, default: 0
      add :active,                :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:route_definitions, [:product_group, :key])
    create index(:route_definitions, [:product_group])
  end
end
