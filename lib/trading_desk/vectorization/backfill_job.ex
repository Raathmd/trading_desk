defmodule TradingDesk.Vectorization.BackfillJob do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "vector_backfill_jobs" do
    field :job_reference, :string
    field :product_group, :string
    field :status, :string, default: "pending"
    field :file_count, :integer, default: 0
    field :total_contracts_parsed, :integer, default: 0
    field :total_contracts_framed, :integer, default: 0
    field :total_vectors_created, :integer, default: 0
    field :errors_encountered, :integer, default: 0
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    has_many :file_logs, TradingDesk.Vectorization.BackfillFileLog,
      foreign_key: :backfill_job_id

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [:job_reference, :product_group, :status, :file_count,
                    :total_contracts_parsed, :total_contracts_framed,
                    :total_vectors_created, :errors_encountered,
                    :started_at, :completed_at])
    |> validate_required([:job_reference])
    |> unique_constraint(:job_reference)
  end
end
