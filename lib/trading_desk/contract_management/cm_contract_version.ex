defmodule TradingDesk.ContractManagement.CmContractVersion do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cm_contract_versions" do
    field :version_number, :integer
    field :terms_snapshot, :map
    field :document_path, :string
    field :document_hash, :string
    field :changes_from_previous, :map
    field :change_summary, :string
    field :created_by, :string

    belongs_to :contract, TradingDesk.ContractManagement.CmContract, type: :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [:contract_id, :version_number, :terms_snapshot, :document_path,
                    :document_hash, :changes_from_previous, :change_summary, :created_by])
    |> validate_required([:contract_id, :version_number, :terms_snapshot, :created_by])
    |> unique_constraint([:contract_id, :version_number])
  end
end
