defmodule TradingDesk.TradeDB.TradeContract do
  @moduledoc """
  Full contract data mirrored from the operational store.

  Append-only: each contract version is a separate row sharing the same `id`.
  The version field distinguishes amendments. Mirrors the Postgres contracts
  table but stores clause data as a single JSON text field (normalized into
  trade_contract_clauses separately for queryability).

  Includes all SAP fields so the SQLite file is a complete, self-contained
  record of every contract that was active during any solve.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "trade_contracts" do
    # Identity
    field :counterparty, :string
    field :counterparty_type, :string     # "customer" | "supplier"
    field :product_group, :string
    field :version, :integer, default: 1
    field :status, :string, default: "draft"

    # Commercial terms
    field :template_type, :string         # "purchase" | "sale" | "spot_purchase" | "spot_sale"
    field :incoterm, :string              # "fob" | "cif" | "cfr" | "dap" | "ddp" etc.
    field :term_type, :string             # "spot" | "long_term"
    field :company, :string               # "trammo_inc" | "trammo_sas" | "trammo_dmcc"
    field :contract_date, :date
    field :expiry_date, :date

    # Document identity
    field :contract_number, :string
    field :family_id, :string
    field :source_file, :string
    field :source_format, :string
    field :file_hash, :string             # SHA-256 hex
    field :file_size, :integer
    field :network_path, :string
    field :graph_item_id, :string
    field :graph_drive_id, :string

    # SAP integration
    field :sap_contract_id, :string
    field :sap_validated, :boolean, default: false
    field :open_position, :float          # tons remaining (from SAP/ERP)
    field :sap_discrepancies_json, :string  # JSON: [{field, contract_value, sap_value}]

    # Review & verification
    field :reviewed_by, :string
    field :reviewed_at, :utc_datetime
    field :review_notes, :string
    field :verification_status, :string
    field :last_verified_at, :utc_datetime
    field :previous_hash, :string         # hash of previous version — tamper chain

    # Extracted data as JSON
    field :clauses_json, :string          # full clause list — quick access
    field :template_validation_json, :string
    field :llm_validation_json, :string

    # Timestamps
    field :scan_date, :utc_datetime       # when the LLM parsed the document
    field :created_at, :utc_datetime
    field :updated_at, :utc_datetime
  end

  @all_fields [
    :id, :counterparty, :counterparty_type, :product_group, :version, :status,
    :template_type, :incoterm, :term_type, :company, :contract_date, :expiry_date,
    :contract_number, :family_id, :source_file, :source_format, :file_hash,
    :file_size, :network_path, :graph_item_id, :graph_drive_id,
    :sap_contract_id, :sap_validated, :open_position, :sap_discrepancies_json,
    :reviewed_by, :reviewed_at, :review_notes, :verification_status,
    :last_verified_at, :previous_hash, :clauses_json,
    :template_validation_json, :llm_validation_json, :scan_date,
    :created_at, :updated_at
  ]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @all_fields)
    |> validate_required([:id, :counterparty, :product_group, :version])
  end
end

defmodule TradingDesk.TradeDB.TradeContractClause do
  @moduledoc """
  Normalized extracted clauses — one row per clause per contract.

  Enables structured queries over clause data:
  - "All contracts with PRICE clause >= $350/ton"
  - "Contracts with penalty caps under $500k"
  - "Spot contracts expiring this quarter"

  Replaced atomically on contract re-ingest (delete + re-insert by contract_id).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "trade_contract_clauses" do
    field :contract_id, :string           # references trade_contracts.id

    field :clause_id, :string             # canonical label e.g. "PRICE", "QUANTITY_TOLERANCE"
    field :clause_type, :string           # "obligation" | "penalty" | "condition" | "price_term" etc.
    field :category, :string              # "core_terms" | "commercial" | "logistics"
    field :description, :string           # original clause text

    # Constraint expression
    field :parameter, :string             # solver variable key e.g. "nola_buy"
    field :operator, :string              # ">=" | "<=" | "==" | "between"
    field :value, :float                  # lower (or only) bound
    field :value_upper, :float            # upper bound for "between"
    field :unit, :string                  # "tons" | "$/ton" | "days" etc.

    # Penalty terms
    field :penalty_per_unit, :float       # $/unit
    field :penalty_cap, :float            # maximum exposure $

    # Metadata
    field :period, :string                # "monthly" | "quarterly" | "annual" | "spot"
    field :confidence, :string            # "high" | "medium" | "low"
    field :reference_section, :string     # document section reference
    field :extracted_at, :utc_datetime
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id, :contract_id, :clause_id, :clause_type, :category, :description,
      :parameter, :operator, :value, :value_upper, :unit,
      :penalty_per_unit, :penalty_cap, :period, :confidence,
      :reference_section, :extracted_at
    ])
    |> validate_required([:id, :contract_id])
  end
end

defmodule TradingDesk.TradeDB.SolveContract do
  @moduledoc """
  Join table: which contracts were active during each solve.

  The contract_id is a plain string (no FK) because contracts may not yet
  be in the SQLite DB when a solve runs. Counterparty and version are
  denormalized for query convenience.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "solve_contracts" do
    field :solve_id, :string
    field :contract_id, :string
    field :counterparty, :string       # denormalized snapshot
    field :contract_version, :integer  # version active at solve time
    field :open_position, :float       # SAP tons remaining at solve time
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_id, :contract_id, :counterparty, :contract_version, :open_position])
    |> validate_required([:solve_id, :contract_id])
  end
end
