defmodule TradingDesk.Repo.Migrations.CreateVectorBackfillFileLogs do
  use Ecto.Migration

  def change do
    create table(:vector_backfill_file_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :backfill_job_id, references(:vector_backfill_jobs, type: :binary_id, on_delete: :delete_all), null: false
      add :filename, :text, null: false
      add :file_size_bytes, :bigint
      add :file_type, :text
      add :row_count, :integer, default: 0
      add :contracts_parsed, :integer, default: 0
      add :llm_calls_made, :integer, default: 0
      add :vectors_created, :integer, default: 0
      add :errors, :text
      add :status, :text, default: "pending"
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:vector_backfill_file_logs, [:backfill_job_id])
  end
end
