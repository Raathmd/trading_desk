defmodule TradingDesk.Repo.Migrations.CreateCmContractNegotiations do
  use Ecto.Migration

  def change do
    create table(:cm_contract_negotiations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :product_group, :text, null: false
      add :reference_number, :text, null: false
      add :counterparty, :text, null: false
      add :commodity, :text, null: false
      add :status, :text, default: "draft"
      add :current_step, :integer, default: 1
      add :total_steps, :integer, default: 7
      add :step_data, :map, default: %{}
      add :step_history, {:array, :map}, default: []
      add :scenario_id, :binary_id
      add :solver_recommendation_snapshot, :map
      add :solver_margin_forecast, :decimal
      add :solver_confidence, :decimal
      add :quantity, :decimal
      add :quantity_unit, :text, default: "MT"
      add :delivery_window_start, :date
      add :delivery_window_end, :date
      add :proposed_price, :decimal
      add :proposed_freight, :decimal
      add :proposed_terms, :map
      add :trader_id, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cm_contract_negotiations, [:product_group, :reference_number])
    create index(:cm_contract_negotiations, [:status])
    create index(:cm_contract_negotiations, [:trader_id])
  end
end
