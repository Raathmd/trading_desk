defmodule TradingDesk.Vectorization.BackfillFileLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "vector_backfill_file_logs" do
    field :filename, :string
    field :file_size_bytes, :integer
    field :file_type, :string
    field :row_count, :integer, default: 0
    field :contracts_parsed, :integer, default: 0
    field :llm_calls_made, :integer, default: 0
    field :vectors_created, :integer, default: 0
    field :errors, :string
    field :status, :string, default: "pending"
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :backfill_job, TradingDesk.Vectorization.BackfillJob, type: :binary_id

    has_many :contract_logs, TradingDesk.Vectorization.BackfillContractLog,
      foreign_key: :backfill_file_log_id

    timestamps(type: :utc_datetime)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:backfill_job_id, :filename, :file_size_bytes, :file_type,
                    :row_count, :contracts_parsed, :llm_calls_made, :vectors_created,
                    :errors, :status, :started_at, :completed_at])
    |> validate_required([:backfill_job_id, :filename])
  end
end
