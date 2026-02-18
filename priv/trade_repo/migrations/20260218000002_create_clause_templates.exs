defmodule TradingDesk.TradeRepo.Migrations.CreateClauseTemplates do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # NH3 CANONICAL CLAUSE DEFINITIONS
    # The master inventory of every clause type that appears across
    # all Trammo ammonia contract templates. Seeded from the
    # "Ammonia Commercial Contract Templates" index page.
    #
    # This is reference data — it defines what the LLM extractor
    # and the clause validator should expect to find. When a clause
    # is extracted from an actual contract, its clause_id links back
    # to this table (trade_contract_clauses.clause_id).
    # ──────────────────────────────────────────────────────────

    create table(:nh3_clause_templates, primary_key: false) do
      add :clause_id, :string, primary_key: true    # e.g. "PRICE", "LAYTIME_DEMURRAGE"
      add :category, :string, null: false            # "core_terms" | "commercial" | "logistics" etc.

      # Detection anchors — text strings the parser looks for in the document
      add :anchors_json, :text, null: false, default: "[]"

      # Known clause variants across template families
      add :variants_json, :text, null: false, default: "[]"

      # Fields the extractor should pull out of this clause
      add :extract_fields_json, :text, null: false, default: "[]"

      # Human notes on how this clause varies across templates
      add :notes, :text

      # Inventory version this was loaded from
      add :inventory_version, :string, null: false, default: "NH3_TEMPLATES_ALL_PAGE_V1"

      timestamps(type: :utc_datetime)
    end

    create index(:nh3_clause_templates, [:category])

    # ──────────────────────────────────────────────────────────
    # CONTRACT FAMILY SIGNATURES
    # Each family defines the set of clause_ids expected for that
    # template type. Used to compute completeness scores when a
    # contract is ingested: (found_clauses / expected_clauses) × 100.
    # ──────────────────────────────────────────────────────────

    create table(:nh3_contract_families, primary_key: false) do
      add :family_id, :string, primary_key: true    # e.g. "VESSEL_SPOT_PURCHASE"

      # Detection anchors — phrases in the document that identify this family
      add :detect_anchors_json, :text, null: false, default: "[]"

      # Ordered list of clause_ids expected for this family
      add :expected_clause_ids_json, :text, null: false, default: "[]"

      # Derived count (redundant but useful for quick queries)
      add :expected_clause_count, :integer, null: false, default: 0

      add :inventory_version, :string, null: false, default: "NH3_TEMPLATES_ALL_PAGE_V1"

      timestamps(type: :utc_datetime)
    end
  end
end
