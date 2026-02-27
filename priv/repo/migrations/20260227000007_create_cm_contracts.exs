defmodule TradingDesk.Repo.Migrations.CreateCmContracts do
  use Ecto.Migration

  def change do
    create table(:cm_contracts, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :product_group, :text, null: false
      add :contract_negotiation_id, references(:cm_contract_negotiations, type: :binary_id), null: true
      add :contract_reference, :text, null: false
      add :counterparty, :text, null: false
      add :commodity, :text, null: false
      add :status, :text, default: "draft"
      add :current_version, :integer, default: 1
      add :terms, :map, null: false
      add :selected_clause_ids, {:array, :binary_id}, default: []
      add :requires_approval_from, {:array, :text}, default: []
      add :approved_by, {:array, :text}, default: []
      add :document_path, :text
      add :document_hash, :text
      add :executed_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cm_contracts, [:product_group, :contract_reference])
    create index(:cm_contracts, [:status])
    create index(:cm_contracts, [:counterparty])
  end
end
