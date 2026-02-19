defmodule TradingDesk.Repo.Migrations.CreateTrackedVessels do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # TRACKED VESSELS
    # Links SAP shipping data to AIS vessel tracking.
    # Each row = one vessel carrying Trammo product, keyed by
    # product group so each desk sees only its own fleet.
    # ──────────────────────────────────────────────────────────

    create table(:tracked_vessels) do
      # Vessel identity — at least one of mmsi/imo/vessel_name required
      add :mmsi,          :string       # 9-digit AIS identifier (primary for tracking)
      add :imo,           :string       # 7-digit IMO number (stable across flag changes)
      add :vessel_name,   :string, null: false

      # SAP linkage
      add :sap_shipping_number, :string  # SAP delivery/shipping doc number
      add :sap_contract_id,     :string  # e.g. "4600000101"

      # Product group — the key for filtering by desk
      add :product_group, :string, null: false  # ammonia_domestic | ammonia_international | sulphur_international | petcoke

      # Cargo details
      add :cargo,          :string       # "Anhydrous Ammonia", "Granular Sulphur", "Petcoke"
      add :quantity_mt,    :float        # metric tons on board
      add :loading_port,   :string       # origin
      add :discharge_port, :string       # destination
      add :eta,            :date         # estimated arrival

      # Status
      add :status, :string, null: false, default: "active"  # active | in_transit | discharged | cancelled

      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:tracked_vessels, [:product_group])
    create index(:tracked_vessels, [:status])
    create index(:tracked_vessels, [:mmsi], where: "mmsi IS NOT NULL")
    create unique_index(:tracked_vessels, [:sap_shipping_number], where: "sap_shipping_number IS NOT NULL")
  end
end
