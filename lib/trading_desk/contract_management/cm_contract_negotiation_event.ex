defmodule TradingDesk.ContractManagement.CmContractNegotiationEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cm_contract_negotiation_events" do
    field :event_type, :string
    field :step_number, :integer
    field :actor, :string
    field :summary, :string
    field :details, :map
    field :clause_id, :binary_id

    belongs_to :contract_negotiation, TradingDesk.ContractManagement.CmContractNegotiation,
      type: :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:contract_negotiation_id, :event_type, :step_number, :actor, :summary, :details, :clause_id])
    |> validate_required([:contract_negotiation_id, :event_type, :actor])
  end
end
