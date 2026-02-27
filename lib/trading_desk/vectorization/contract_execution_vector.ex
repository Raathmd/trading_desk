defmodule TradingDesk.Vectorization.ContractExecutionVector do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "contract_execution_vectors" do
    field :product_group, :string
    field :source_process, :string
    field :source_event_type, :string
    field :source_event_id, :binary_id
    field :commodity, :string
    field :counterparty, :string
    field :decision_narrative, :string
    field :embedding, Pgvector.Ecto.Vector
    field :market_snapshot, :map
    field :trader_id, :string
    field :optimizer_recommendation, :string
    field :optimizer_confidence, :decimal
    field :actual_outcome, :map
    field :forecast_vs_actual, :map
    field :vectorized_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(vector, attrs) do
    vector
    |> cast(attrs, [:product_group, :source_process, :source_event_type, :source_event_id,
                    :commodity, :counterparty, :decision_narrative, :embedding,
                    :market_snapshot, :trader_id, :optimizer_recommendation,
                    :optimizer_confidence, :actual_outcome, :forecast_vs_actual, :vectorized_at])
    |> validate_required([:source_process, :source_event_type, :decision_narrative])
  end
end
