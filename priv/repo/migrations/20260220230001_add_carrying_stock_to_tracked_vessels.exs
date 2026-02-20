defmodule TradingDesk.Repo.Migrations.AddCarryingStockToTrackedVessels do
  use Ecto.Migration

  def change do
    alter table(:tracked_vessels) do
      add :carrying_stock, :boolean, default: false, null: false
    end

    create index(:tracked_vessels, [:carrying_stock])
    create index(:tracked_vessels, [:product_group, :carrying_stock])
  end
end
