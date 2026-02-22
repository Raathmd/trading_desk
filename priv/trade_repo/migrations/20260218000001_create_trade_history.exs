defmodule TradingDesk.TradeRepo.Migrations.CreateTradeHistory do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # CORE SOLVE RECORD
    # Every pipeline execution (auto + manual) writes one row here.
    # This is the spine that all other tables link back to.
    # ──────────────────────────────────────────────────────────

    create table(:solves, primary_key: false) do
      add :id, :string, primary_key: true        # pipeline run_id (12-char base32)
      add :solve_type, :string, null: false       # "single" | "monte_carlo"
      add :trigger_source, :string, null: false   # "dashboard" | "auto_runner" | "api" | "scheduled"
      add :product_group, :string, null: false    # "ammonia" | "uan" | "urea"
      add :trader_id, :string                     # NULL for auto-runner
      add :is_auto_solve, :boolean, null: false, default: false

      # Contract freshness check outcome
      add :contracts_checked, :boolean, null: false, default: false
      add :contracts_stale, :boolean, null: false, default: false
      add :contracts_stale_reason, :string
      add :contracts_ingested, :integer, null: false, default: 0

      # Denormalized result summary for fast list queries
      add :result_status, :string                 # "optimal" | signal atom as string

      # Chain commit reference (populated by stub, updated when broadcast)
      add :chain_commit_id, :string

      # Pipeline phase timestamps (ISO8601 UTC)
      add :started_at, :utc_datetime, null: false
      add :contracts_checked_at, :utc_datetime
      add :ingestion_completed_at, :utc_datetime
      add :solve_started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:solves, [:product_group, :started_at])
    create index(:solves, [:trader_id, :started_at])
    create index(:solves, [:is_auto_solve, :started_at])
    create index(:solves, [:trigger_source, :started_at])
    create index(:solves, [:result_status])

    # ──────────────────────────────────────────────────────────
    # VARIABLE SNAPSHOT
    # The exact values of all 20 solver variables used in the solve.
    # One row per solve, 1:1. Enables reconstructing any solve from scratch.
    # ──────────────────────────────────────────────────────────

    create table(:solve_variables, primary_key: false) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all),
          primary_key: true

      # Environmental — USGS / NOAA / USACE
      add :river_stage, :float    # ft — USGS gauge (navigation risk)
      add :lock_hrs, :float       # hrs total delay — USACE (locks & dams)
      add :temp_f, :float         # °F — NOAA (NH3 vapor pressure risk)
      add :wind_mph, :float       # mph — NOAA (barge handling)
      add :vis_mi, :float         # miles — NOAA (navigation)
      add :precip_in, :float      # inches/3-day — NOAA (flood risk)

      # Operations — internal systems
      add :inv_mer, :float        # tons — Meredosia terminal inventory (Insight)
      add :inv_nio, :float        # tons — Niota terminal inventory (Insight)
      add :mer_outage, :boolean   # Meredosia terminal outage flag (trader-set)
      add :nio_outage, :boolean   # Niota terminal outage flag (trader-set)
      add :barge_count, :float    # selected barges from fleet management

      # Commercial — market / broker / EIA
      add :nola_buy, :float       # $/ton — NH3 NOLA purchase price
      add :sell_stl, :float       # $/ton — delivered St. Louis
      add :sell_mem, :float       # $/ton — delivered Memphis
      add :fr_don_stl, :float     # $/ton freight Don→StL
      add :fr_don_mem, :float     # $/ton freight Don→Mem
      add :fr_geis_stl, :float    # $/ton freight Geis→StL
      add :fr_geis_mem, :float    # $/ton freight Geis→Mem
      add :nat_gas, :float        # $/MMBtu — EIA Henry Hub
      add :working_cap, :float    # $ — available working capital
    end

    # ──────────────────────────────────────────────────────────
    # API SOURCE FRESHNESS
    # When each data source was last fetched relative to this solve.
    # Critical for data quality audit: "was USGS data stale when we solved?"
    # ──────────────────────────────────────────────────────────

    create table(:solve_variable_sources, primary_key: false) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all),
          primary_key: true

      add :usgs_fetched_at, :utc_datetime     # river_stage, (implied visibility)
      add :noaa_fetched_at, :utc_datetime     # temp_f, wind_mph, vis_mi, precip_in
      add :usace_fetched_at, :utc_datetime    # lock_hrs
      add :eia_fetched_at, :utc_datetime      # nat_gas
      add :internal_fetched_at, :utc_datetime # inv_mer, inv_nio, mer_outage, nio_outage, barge_count, working_cap
      add :broker_fetched_at, :utc_datetime   # freight rates
      add :market_fetched_at, :utc_datetime   # nola_buy, sell_stl, sell_mem
    end

    # ──────────────────────────────────────────────────────────
    # DELTA CONFIG SNAPSHOT
    # The auto-solve thresholds and settings active at solve time.
    # Without this, you can't explain WHY a particular auto-solve was triggered.
    # ──────────────────────────────────────────────────────────

    create table(:solve_delta_config, primary_key: false) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all),
          primary_key: true

      add :enabled, :boolean, null: false, default: false
      add :n_scenarios, :integer            # MC scenario count configured at solve time
      add :min_solve_interval_ms, :integer  # cooldown active at solve time
      add :thresholds_json, :string, null: false, default: "{}"  # JSON map of {variable_key: threshold}
      add :triggered_mask, :integer, null: false, default: 0     # u32 bitmask — which vars crossed
    end

    # ──────────────────────────────────────────────────────────
    # SINGLE LP SOLVE RESULT
    # The output from the Zig LP solver for :solve mode.
    # ──────────────────────────────────────────────────────────

    create table(:solve_results_single, primary_key: false) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all),
          primary_key: true

      add :status, :string, null: false   # "optimal" | "infeasible" | "error"
      add :profit, :float                 # total gross profit $
      add :tons, :float                   # total tons shipped
      add :barges, :float                 # total barges used
      add :cost, :float                   # total capital deployed $
      add :roi, :float                    # return on capital %
      add :eff_barge, :float              # profit per barge (efficiency metric)
    end

    # ──────────────────────────────────────────────────────────
    # PER-ROUTE BREAKDOWN
    # One row per route with material allocation.
    # Routes: Don→StL (0), Don→Mem (1), Geis→StL (2), Geis→Mem (3)
    # ──────────────────────────────────────────────────────────

    create table(:solve_result_routes) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all), null: false
      add :route_index, :integer, null: false   # 0-3 (matches Zig solver output order)
      add :origin, :string                      # "don" | "geis"
      add :destination, :string                 # "stl" | "mem"
      add :tons, :float                         # tons allocated on this route
      add :profit, :float                       # route-level gross profit $
      add :margin, :float                       # $/ton margin
      add :transit_days, :float                 # expected transit days
      add :shadow_price, :float                 # dual variable (constraint binding tightness)
    end

    create index(:solve_result_routes, [:solve_id])

    # ──────────────────────────────────────────────────────────
    # MONTE CARLO DISTRIBUTION RESULT
    # Output from :monte_carlo mode — the full P5-P95 distribution.
    # ──────────────────────────────────────────────────────────

    create table(:solve_results_mc, primary_key: false) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all),
          primary_key: true

      add :signal, :string, null: false    # "strong_go" | "go" | "cautious" | "weak" | "no_go"
      add :n_scenarios, :integer           # total scenarios run
      add :n_feasible, :integer            # feasible scenarios (LP solved)
      add :n_infeasible, :integer          # infeasible scenarios

      # Profit distribution ($ gross profit per scenario)
      add :mean, :float
      add :stddev, :float
      add :p5, :float      # 5th percentile (downside tail)
      add :p25, :float
      add :p50, :float     # median
      add :p75, :float
      add :p95, :float     # 95th percentile (upside tail)
      add :min_profit, :float
      add :max_profit, :float
    end

    # ──────────────────────────────────────────────────────────
    # MC SENSITIVITY RANKING
    # Which variables drive profit outcomes most (Pearson correlation).
    # Up to 6 rows per solve, ranked descending by |correlation|.
    # ──────────────────────────────────────────────────────────

    create table(:solve_mc_sensitivity) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all), null: false
      add :variable_key, :string, null: false   # e.g. "nola_buy", "river_stage"
      add :correlation, :float, null: false      # Pearson r with profit (-1..+1)
      add :rank, :integer, null: false           # 1 = highest impact
    end

    create index(:solve_mc_sensitivity, [:solve_id])

    # ──────────────────────────────────────────────────────────
    # AUTO-SOLVE TRIGGERS
    # For auto-runner solves: which variables crossed their threshold,
    # by how much, and in which direction. The causal chain of the solve.
    # ──────────────────────────────────────────────────────────

    create table(:auto_solve_triggers) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all), null: false
      add :variable_key, :string, null: false   # e.g. :nola_buy
      add :variable_index, :integer             # bit position in triggered_mask
      add :baseline_value, :float               # value from last solve
      add :current_value, :float                # value that triggered re-solve
      add :threshold, :float                    # admin-configured threshold
      add :delta, :float                        # current - baseline (signed)
      add :direction, :string                   # "up" | "down"
    end

    create index(:auto_solve_triggers, [:solve_id])
    create index(:auto_solve_triggers, [:variable_key])

    # ──────────────────────────────────────────────────────────
    # CONTRACT MASTER TABLE
    # Full contract data mirrored from the operational store.
    # Append-only: new version = new row. IDs are stable across versions.
    # ──────────────────────────────────────────────────────────

    create table(:trade_contracts, primary_key: false) do
      add :id, :string, primary_key: true        # stable across versions (same as Postgres id)

      # Identity
      add :counterparty, :string, null: false
      add :counterparty_type, :string            # "customer" | "supplier"
      add :product_group, :string, null: false   # "ammonia" | "uan" | "urea"
      add :version, :integer, null: false, default: 1
      add :status, :string, null: false, default: "draft"
                                                 # "draft" | "pending_review" | "approved" | "rejected"

      # Commercial terms
      add :template_type, :string               # "purchase" | "sale" | "spot_purchase" | "spot_sale"
      add :incoterm, :string                    # "fob" | "cif" | "cfr" | "dap" | "ddp" etc.
      add :term_type, :string                   # "spot" | "long_term"
      add :company, :string                     # "trammo_inc" | "trammo_sas" | "trammo_dmcc"
      add :contract_date, :date
      add :expiry_date, :date

      # Document identity
      add :contract_number, :string
      add :family_id, :string                   # groups related contracts
      add :source_file, :string
      add :source_format, :string               # "pdf" | "docx" | "docm"
      add :file_hash, :string                   # SHA-256 hex — tamper detection
      add :file_size, :integer                  # bytes
      add :network_path, :string                # UNC / SharePoint path
      add :graph_item_id, :string               # Graph API SharePoint item ID
      add :graph_drive_id, :string              # Graph API drive ID

      # SAP integration
      add :sap_contract_id, :string
      add :sap_validated, :boolean, default: false
      add :open_position, :float                # tons remaining on contract (from SAP)
      add :sap_discrepancies_json, :text        # JSON: [{field, contract_value, sap_value}]

      # Review & verification
      add :reviewed_by, :string
      add :reviewed_at, :utc_datetime
      add :review_notes, :text
      add :verification_status, :string         # "verified" | "mismatch" | "file_not_found" | "pending" | "error"
      add :last_verified_at, :utc_datetime
      add :previous_hash, :string               # hash of prior version — tamper chain

      # Extracted data (JSON — full clause list + validation results)
      add :clauses_json, :text, null: false, default: "[]"
      add :template_validation_json, :text      # completeness check result
      add :llm_validation_json, :text           # second-pass LLM verification result

      # Timestamps
      add :scan_date, :utc_datetime             # when document was parsed by Copilot
      add :created_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:trade_contracts, [:counterparty, :product_group, :version])
    create index(:trade_contracts, [:product_group, :status])
    create index(:trade_contracts, [:file_hash])
    create index(:trade_contracts, [:sap_contract_id])
    create index(:trade_contracts, [:expiry_date])

    # ──────────────────────────────────────────────────────────
    # NORMALIZED CONTRACT CLAUSES
    # Each extracted clause as its own row for queryability.
    # Enables: "which contracts have a price clause > $350/ton?"
    # ──────────────────────────────────────────────────────────

    create table(:trade_contract_clauses, primary_key: false) do
      add :id, :string, primary_key: true         # clause ID (hex)
      add :contract_id, references(:trade_contracts, type: :string, on_delete: :delete_all),
          null: false

      add :clause_id, :string          # canonical label e.g. "PRICE", "QUANTITY_TOLERANCE"
      add :clause_type, :string        # "obligation" | "penalty" | "condition" | "price_term" etc.
      add :category, :string           # "core_terms" | "commercial" | "logistics"
      add :description, :text          # original clause text from document

      # Constraint expression: parameter operator value [value_upper]
      add :parameter, :string          # solver variable key e.g. "nola_buy", "barge_count"
      add :operator, :string           # ">=" | "<=" | "==" | "between"
      add :value, :float               # lower (or only) bound
      add :value_upper, :float         # upper bound for "between" operator
      add :unit, :string               # "tons" | "$/ton" | "days" | "$/MMBtu" etc.

      # Penalty terms
      add :penalty_per_unit, :float    # $/ton or $/day
      add :penalty_cap, :float         # max penalty exposure $

      # Temporal
      add :period, :string             # "monthly" | "quarterly" | "annual" | "spot"
      add :confidence, :string         # "high" | "medium" | "low" (parser confidence)
      add :reference_section, :string  # document section e.g. "Section 4.2"
      add :extracted_at, :utc_datetime
    end

    create index(:trade_contract_clauses, [:contract_id])
    create index(:trade_contract_clauses, [:parameter])       # query: all clauses affecting nola_buy
    create index(:trade_contract_clauses, [:clause_type])
    create index(:trade_contract_clauses, [:clause_id])

    # ──────────────────────────────────────────────────────────
    # SOLVE → CONTRACT JOIN
    # Which contracts were active (approved + in-force) at solve time.
    # Enables: "which solves used this contract?" and "what contracts
    # were in play when this solve ran?"
    # ──────────────────────────────────────────────────────────

    create table(:solve_contracts) do
      add :solve_id, references(:solves, type: :string, on_delete: :delete_all), null: false
      add :contract_id, :string, null: false     # no FK — contract may not yet be in SQLite
      add :counterparty, :string                 # denormalized — survives contract deletion
      add :contract_version, :integer            # version active at solve time
      add :open_position, :float                 # SAP tons remaining at solve time
    end

    create unique_index(:solve_contracts, [:solve_id, :contract_id])
    create index(:solve_contracts, [:solve_id])
    create index(:solve_contracts, [:contract_id])

    # ──────────────────────────────────────────────────────────
    # BLOCKCHAIN COMMIT LOG
    # Stub table — populated immediately with status="pending" for every solve.
    # When the JungleBus/MAPI chain integration is live:
    #   - payload_hash, signature_hex, txid are populated
    #   - status advances: pending → broadcast → confirmed
    # This table is the recovery map: each row links a solve to its on-chain record.
    # ──────────────────────────────────────────────────────────

    create table(:chain_commit_log, primary_key: false) do
      add :id, :string, primary_key: true        # hex commit ID (16 chars)
      add :solve_id, references(:solves, type: :string, on_delete: :nilify_all)

      # Commit type (matches AutoSolveCommitter constants)
      # 1=SOLVE  2=MC  3=AUTO_SOLVE  4=AUTO_MC  5=CONFIG_CHANGE
      add :commit_type, :integer, null: false

      add :product_group, :string, null: false
      add :signer_type, :string                  # "trader" | "server"
      add :signer_id, :string                    # trader email or "system"

      # Cryptographic fields (populated when chain is live)
      add :pubkey_hex, :string                   # signer's BSV public key
      add :payload_hash, :string                 # SHA-256 of canonical payload
      add :signature_hex, :string                # ECDSA signature

      # BSV transaction fields
      add :txid, :string                         # BSV transaction ID
      add :broadcast_at, :utc_datetime
      add :confirmed_at, :utc_datetime
      add :block_height, :integer

      add :status, :string, null: false, default: "pending"
                                                 # "pending" | "broadcast" | "confirmed" | "failed"
      add :error_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:chain_commit_log, [:solve_id])
    create index(:chain_commit_log, [:status, :inserted_at])
    create index(:chain_commit_log, [:txid])
    create index(:chain_commit_log, [:product_group, :inserted_at])

    # ──────────────────────────────────────────────────────────
    # CONFIG CHANGE HISTORY
    # Every admin change to DeltaConfig thresholds or settings.
    # Links to a chain commit so the config state at any point in time
    # is recoverable from the blockchain.
    # ──────────────────────────────────────────────────────────

    create table(:config_change_history) do
      add :product_group, :string, null: false
      add :admin_id, :string                     # who made the change
      add :changed_at, :utc_datetime, null: false
      add :field_changed, :string                # which field e.g. "thresholds.nola_buy"
      add :old_value_json, :text                 # previous value
      add :new_value_json, :text                 # new value
      add :full_config_json, :text, null: false  # full config snapshot after change
      add :chain_commit_id, :string              # FK to chain_commit_log (nullable)

      timestamps(type: :utc_datetime)
    end

    create index(:config_change_history, [:product_group, :changed_at])
  end
end
