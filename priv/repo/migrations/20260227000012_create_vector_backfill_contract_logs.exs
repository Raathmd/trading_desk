defmodule TradingDesk.Repo.Migrations.CreateVectorBackfillContractLogs do
  use Ecto.Migration

  def change do
    create table(:vector_backfill_contract_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :backfill_file_log_id, references(:vector_backfill_file_logs, type: :binary_id, on_delete: :delete_all), null: false
      add :row_number, :integer
      add :sap_contract_reference, :text
      add :sap_contract_data, :map
      add :llm_framing_prompt, :text
      add :llm_framing_output, :text
      add :vector_id, references(:contract_execution_vectors, type: :binary_id), null: true
      add :status, :text, default: "pending"
      add :error_message, :text
      add :processed_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:vector_backfill_contract_logs, [:backfill_file_log_id])
  end
end
