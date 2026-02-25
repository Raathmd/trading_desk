defmodule TradingDesk.Repo.Migrations.CreateScheduledDeliveriesAndFolderScan do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # CONTRACTS: soft-delete columns
    #
    # When a file disappears from the watched folder or SAP
    # marks the contract as closed, the contract is logically
    # deleted (deleted_at is set, deletion_reason explains why).
    # ──────────────────────────────────────────────────────────

    alter table(:contracts) do
      add :deleted_at, :utc_datetime
      add :deletion_reason, :string  # file_removed | sap_closed | manual
    end

    create index(:contracts, [:deleted_at])

    # ──────────────────────────────────────────────────────────
    # SCHEDULED DELIVERIES
    #
    # Generated from ingested contracts. Each delivery line is
    # linked to the contract via contract_id AND contract_hash.
    #
    # When a contract file is reimported (new hash), old schedule
    # records are physically deleted and new ones generated.
    # ──────────────────────────────────────────────────────────

    create table(:scheduled_deliveries) do
      add :contract_id, references(:contracts, type: :string, on_delete: :nilify_all)
      add :contract_hash, :string, null: false

      # Denormalized for fast querying without joins
      add :counterparty, :string, null: false
      add :contract_number, :string
      add :sap_contract_id, :string
      add :direction, :string, null: false        # purchase | sale
      add :product_group, :string, null: false
      add :incoterm, :string

      # Delivery details
      add :quantity_mt, :float, null: false
      add :required_date, :date, null: false
      add :estimated_date, :date
      add :delay_days, :integer, default: 0
      add :status, :string, default: "on_track"   # on_track | at_risk | delayed
      add :delivery_index, :integer
      add :total_deliveries, :integer
      add :destination, :string
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:scheduled_deliveries, [:contract_id])
    create index(:scheduled_deliveries, [:contract_hash])
    create index(:scheduled_deliveries, [:product_group, :status])
    create index(:scheduled_deliveries, [:required_date])
    create index(:scheduled_deliveries, [:counterparty])
  end
end
