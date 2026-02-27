defmodule TradingDesk.ContractManagement.CmContractApproval do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cm_contract_approvals" do
    field :approver_id, :string
    field :approval_status, :string, default: "pending"
    field :notes, :string
    field :conditional_requirements, :string
    field :approved_at, :utc_datetime

    belongs_to :contract, TradingDesk.ContractManagement.CmContract, type: :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:contract_id, :approver_id, :approval_status, :notes,
                    :conditional_requirements, :approved_at])
    |> validate_required([:contract_id, :approver_id])
    |> validate_inclusion(:approval_status, ~w(pending approved rejected conditional))
  end
end
