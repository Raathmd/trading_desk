defmodule TradingDesk.Vectorization.BackfillContractLog do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "vector_backfill_contract_logs" do
    field :row_number, :integer
    field :sap_contract_reference, :string
    field :sap_contract_data, :map
    field :llm_framing_prompt, :string
    field :llm_framing_output, :string
    field :vector_id, :binary_id
    field :status, :string, default: "pending"
    field :error_message, :string
    field :processed_at, :utc_datetime

    belongs_to :backfill_file_log, TradingDesk.Vectorization.BackfillFileLog, type: :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:backfill_file_log_id, :row_number, :sap_contract_reference,
                    :sap_contract_data, :llm_framing_prompt, :llm_framing_output,
                    :vector_id, :status, :error_message, :processed_at])
    |> validate_required([:backfill_file_log_id])
  end
end
