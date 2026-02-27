defmodule TradingDesk.ContractManagement.CmContract do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_statuses ~w(draft pending_review pending_approval approved executed active expired terminated disputed)

  schema "cm_contracts" do
    field :product_group, :string
    field :contract_reference, :string
    field :counterparty, :string
    field :commodity, :string
    field :status, :string, default: "draft"
    field :current_version, :integer, default: 1
    field :terms, :map
    field :selected_clause_ids, {:array, :binary_id}, default: []
    field :requires_approval_from, {:array, :string}, default: []
    field :approved_by, {:array, :string}, default: []
    field :document_path, :string
    field :document_hash, :string
    field :executed_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :contract_negotiation, TradingDesk.ContractManagement.CmContractNegotiation,
      type: :binary_id

    has_many :versions, TradingDesk.ContractManagement.CmContractVersion,
      foreign_key: :contract_id

    has_many :approvals, TradingDesk.ContractManagement.CmContractApproval,
      foreign_key: :contract_id

    timestamps(type: :utc_datetime)
  end

  def changeset(contract, attrs) do
    contract
    |> cast(attrs, [
      :product_group, :contract_negotiation_id, :contract_reference, :counterparty,
      :commodity, :status, :current_version, :terms, :selected_clause_ids,
      :requires_approval_from, :approved_by, :document_path, :document_hash,
      :executed_at, :expires_at
    ])
    |> validate_required([:product_group, :contract_reference, :counterparty, :commodity, :terms])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:product_group, :contract_reference])
  end
end
