defmodule TradingDesk.Repo.Migrations.CreateVectorBackfillJobs do
  use Ecto.Migration

  def change do
    create table(:vector_backfill_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :job_reference, :text, null: false
      add :product_group, :text
      add :status, :text, default: "pending"
      add :file_count, :integer, default: 0
      add :total_contracts_parsed, :integer, default: 0
      add :total_contracts_framed, :integer, default: 0
      add :total_vectors_created, :integer, default: 0
      add :errors_encountered, :integer, default: 0
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vector_backfill_jobs, [:job_reference])
  end
end
