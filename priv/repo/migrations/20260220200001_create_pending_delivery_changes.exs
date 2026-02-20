defmodule TradingDesk.Repo.Migrations.CreatePendingDeliveryChanges do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # PENDING DELIVERY CHANGES
    # When a trader saves a solved scenario, proposed delivery
    # changes are written here. The Workflow tab shows these rows
    # so the trader can review and simulate pushing each one to SAP.
    # Clicking "Apply to SAP" marks the change as applied and
    # updates the live delivery schedule to reflect the SAP state.
    # ──────────────────────────────────────────────────────────

    create table(:pending_delivery_changes) do
      # Which scenario produced this change
      add :scenario_name,    :string, null: false
      add :scenario_id,      :integer             # fk to saved_scenarios (nullable — may not be saved yet)

      # SAP contract linkage
      add :contract_number,  :string              # e.g. "40012345"
      add :sap_contract_id,  :string              # e.g. "4600000101"
      add :counterparty,     :string, null: false
      add :direction,        :string, null: false  # "sale" | "purchase"
      add :product_group,    :string, null: false

      # What is changing
      add :original_quantity_mt, :float
      add :revised_quantity_mt,  :float
      add :original_date,        :date
      add :revised_date,         :date
      add :change_type,          :string, null: false, default: "quantity"  # "quantity" | "date" | "both" | "cancel"

      # Why
      add :change_reason, :text

      # Workflow status
      add :status, :string, null: false, default: "pending"  # pending | applied | rejected | cancelled

      # SAP simulation
      add :applied_at,     :utc_datetime
      add :sap_document,   :string   # SAP document number after apply (simulated)
      add :applied_by,     :integer  # trader_id who simulated the SAP update

      # Trader who created this change request
      add :trader_id, :integer

      # Notes
      add :notes, :text

      # SAP document dates (from SAP, updated when apply is simulated)
      add :sap_created_at, :utc_datetime
      add :sap_updated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:pending_delivery_changes, [:status])
    create index(:pending_delivery_changes, [:product_group])
    create index(:pending_delivery_changes, [:trader_id])
    create index(:pending_delivery_changes, [:scenario_id])
    create index(:pending_delivery_changes, [:sap_contract_id])
  end
end
