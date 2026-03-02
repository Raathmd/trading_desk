defmodule TradingDesk.Repo.Migrations.CreateConstraintDefinitions do
  use Ecto.Migration

  def change do
    create table(:constraint_definitions) do
      add :product_group,         :string,  null: false   # FK to product_group_configs.key
      add :key,                   :string,  null: false   # e.g. "supply_mer"
      add :name,                  :string,  null: false   # "Supply Meredosia"
      add :constraint_type,       :string,  null: false   # "supply" | "demand_cap" | "fleet_constraint" | "capital_constraint"
      add :terminal,              :string                 # origin terminal name (for supply constraints)
      add :destination,           :string                 # destination name (for demand_cap constraints)
      add :bound_variable,        :string,  null: false   # variable key for the bound
      add :bound_min_variable,    :string                 # optional min-bound variable (e.g. committed_lift)
      add :outage_variable,       :string                 # optional outage toggle variable
      add :outage_factor,         :float                  # factor applied when outage is active
      add :routes,                {:array, :string}, default: []  # route keys this constraint applies to
      add :display_order,         :integer, default: 0
      add :active,                :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:constraint_definitions, [:product_group, :key])
    create index(:constraint_definitions, [:product_group])
  end
end
