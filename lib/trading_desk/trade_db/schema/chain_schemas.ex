defmodule TradingDesk.TradeDB.ChainCommitLog do
  @moduledoc """
  Blockchain commit queue — one row per solve, stubbed until chain is live.

  Every solve immediately gets a row with status="pending". When the
  JungleBus/MAPI integration is implemented:

    1. `payload_hash`, `signature_hex`, and `pubkey_hex` are populated
    2. The raw BSV transaction is built and broadcast
    3. `txid` is set and `status` advances to "broadcast"
    4. On confirmation, `block_height` and `confirmed_at` are set

  This table is the recovery manifest: each row maps a solve to its
  on-chain record so the SQLite DB can be reconstructed from the blockchain.

  Commit type constants (match AutoSolveCommitter):
    1 = SOLVE           — single LP solve by trader
    2 = MC              — Monte Carlo by trader
    3 = AUTO_SOLVE      — single LP by auto-runner
    4 = AUTO_MC         — Monte Carlo by auto-runner
    5 = CONFIG_CHANGE   — admin changed DeltaConfig
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}

  schema "chain_commit_log" do
    field :solve_id, :string             # references solves.id (nullable — config changes have no solve)

    field :commit_type, :integer         # 1..5 (see moduledoc)
    field :product_group, :string

    field :signer_type, :string          # "trader" | "server"
    field :signer_id, :string            # trader email or "system"

    # Cryptographic fields (nil until chain is live)
    field :pubkey_hex, :string
    field :payload_hash, :string         # SHA-256 of canonical payload
    field :signature_hex, :string        # ECDSA secp256k1 signature

    # BSV transaction fields (nil until broadcast)
    field :txid, :string
    field :broadcast_at, :utc_datetime
    field :confirmed_at, :utc_datetime
    field :block_height, :integer

    field :status, :string, default: "pending"
                                         # "pending" | "broadcast" | "confirmed" | "failed"
    field :error_reason, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :id, :solve_id, :commit_type, :product_group, :signer_type, :signer_id,
      :pubkey_hex, :payload_hash, :signature_hex,
      :txid, :broadcast_at, :confirmed_at, :block_height,
      :status, :error_reason
    ])
    |> validate_required([:id, :commit_type, :product_group])
    |> validate_inclusion(:status, ~w(pending broadcast confirmed failed))
  end

  # Commit type constants — match TradingDesk.DB.ChainCommitRecord
  def type_solve, do: 1
  def type_mc, do: 2
  def type_auto_solve, do: 3
  def type_auto_mc, do: 4
  def type_config_change, do: 5
end

defmodule TradingDesk.TradeDB.ConfigChangeHistory do
  @moduledoc """
  Audit log of every admin change to DeltaConfig thresholds or settings.

  Each row captures the full config state after the change so any historical
  state can be reconstructed. Links to a chain_commit_log row so the
  config history is also on-chain when the chain integration is live.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "config_change_history" do
    field :product_group, :string
    field :admin_id, :string
    field :changed_at, :utc_datetime
    field :field_changed, :string        # e.g. "thresholds.nola_buy", "n_scenarios"
    field :old_value_json, :string       # JSON-encoded previous value
    field :new_value_json, :string       # JSON-encoded new value
    field :full_config_json, :string     # full config snapshot after this change
    field :chain_commit_id, :string      # references chain_commit_log.id (nullable)

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :product_group, :admin_id, :changed_at, :field_changed,
      :old_value_json, :new_value_json, :full_config_json, :chain_commit_id
    ])
    |> validate_required([:product_group, :changed_at, :full_config_json])
  end
end
