defmodule TradingDesk.TradeDB.NH3ClauseTemplate do
  @moduledoc """
  Canonical clause definition from the NH3 contract template inventory.

  One row per clause type. This is reference data — it defines what the
  LLM extractor and clause validator should look for when parsing a
  physical contract document.

  Seeded via `TradingDesk.TradeDB.ClauseTemplateSeed.run/0`.
  Linked from `trade_contract_clauses.clause_id`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:clause_id, :string, autogenerate: false}

  schema "nh3_clause_templates" do
    field :category, :string            # "metadata" | "core_terms" | "commercial" | "logistics" |
                                        # "logistics_cost" | "incorporation" | "operational" |
                                        # "compliance" | "determination" | "documentation" |
                                        # "risk_allocation" | "risk_costs" | "risk_events" |
                                        # "credit_legal" | "legal" | "legal_long_term"
    field :anchors_json, :string        # JSON array of detection anchor strings
    field :variants_json, :string       # JSON array of known variant names
    field :extract_fields_json, :string # JSON array of field names to extract
    field :notes, :string
    field :inventory_version, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:clause_id, :category, :anchors_json, :variants_json,
                    :extract_fields_json, :notes, :inventory_version])
    |> validate_required([:clause_id, :category])
  end
end

defmodule TradingDesk.TradeDB.NH3ContractFamily do
  @moduledoc """
  Contract family signature — identifies a template type and the clauses it requires.

  One row per template family (7 families for NH3). Used for:
    - Document classification: which family does this contract belong to?
    - Completeness scoring: (found_clauses / expected_clauses) × 100
    - Gap detection: which required clauses are missing from an ingested contract?

  The `detect_anchors` are text phrases that, when found in a document,
  strongly indicate it belongs to this family. The `expected_clause_ids`
  defines which canonical clause types should be present.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:family_id, :string, autogenerate: false}

  schema "nh3_contract_families" do
    field :detect_anchors_json, :string       # JSON array of detection phrases
    field :expected_clause_ids_json, :string  # JSON array of expected clause_id strings
    field :expected_clause_count, :integer, default: 0
    field :inventory_version, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:family_id, :detect_anchors_json, :expected_clause_ids_json,
                    :expected_clause_count, :inventory_version])
    |> validate_required([:family_id])
  end
end
