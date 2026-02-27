defmodule TradingDesk.Repo.Migrations.CreateCmContractApprovals do
  use Ecto.Migration

  def change do
    create table(:cm_contract_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :contract_id, references(:cm_contracts, type: :binary_id, on_delete: :delete_all), null: false
      add :approver_id, :text, null: false
      add :approval_status, :text, default: "pending"
      add :notes, :text
      add :conditional_requirements, :text
      add :approved_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cm_contract_approvals, [:contract_id])
    create index(:cm_contract_approvals, [:approver_id])
  end
end
