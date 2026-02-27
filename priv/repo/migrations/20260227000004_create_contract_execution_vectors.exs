defmodule TradingDesk.Repo.Migrations.CreateContractExecutionVectors do
  use Ecto.Migration

  def change do
    create table(:contract_execution_vectors, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :product_group, :text
      add :source_process, :text, null: false
      add :source_event_type, :text, null: false
      add :source_event_id, :binary_id
      add :commodity, :text
      add :counterparty, :text
      add :decision_narrative, :text, null: false
      add :embedding, :vector, size: 1536
      add :market_snapshot, :map
      add :trader_id, :text
      add :optimizer_recommendation, :text
      add :optimizer_confidence, :decimal
      add :actual_outcome, :map
      add :forecast_vs_actual, :map
      add :vectorized_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:contract_execution_vectors, [:product_group])
    create index(:contract_execution_vectors, [:source_process, :source_event_type])
    create index(:contract_execution_vectors, [:commodity])
    create index(:contract_execution_vectors, [:counterparty])
  end
end
