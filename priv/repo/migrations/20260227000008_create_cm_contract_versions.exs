defmodule TradingDesk.Repo.Migrations.CreateCmContractVersions do
  use Ecto.Migration

  def change do
    create table(:cm_contract_versions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :contract_id, references(:cm_contracts, type: :binary_id, on_delete: :delete_all), null: false
      add :version_number, :integer, null: false
      add :terms_snapshot, :map, null: false
      add :document_path, :text
      add :document_hash, :text
      add :changes_from_previous, :map
      add :change_summary, :text
      add :created_by, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:cm_contract_versions, [:contract_id, :version_number])
  end
end
