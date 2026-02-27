defmodule TradingDesk.Repo.Migrations.CreateTraderDecisions do
  use Ecto.Migration

  def change do
    create table(:trader_decisions) do
      # Who made it
      add :trader_id,      :integer, null: false
      add :trader_name,    :string,  null: false
      add :product_group,  :string,  null: false

      # What changed — map of %{variable_key => value}
      # For :absolute mode: the value IS the new value
      # For :relative mode: the value is the delta to add to LiveState
      add :variable_changes, :map, null: false, default: %{}

      # Per-variable mode — map of %{variable_key => "absolute" | "relative"}
      # Keys not present default to :absolute
      add :change_modes, :map, null: false, default: %{}

      # Why — free-text reason and optional structured intent
      add :reason,    :string
      add :intent,    :map

      # Optional link to a solve audit
      add :audit_id, :string

      # Lifecycle
      # proposed: visible to all, not yet affecting shared state
      # applied:  affects effective state for all traders
      # superseded: replaced by a newer decision on same variable(s)
      # rejected: explicitly rejected
      # revoked: original trader withdrew it
      add :status, :string, null: false, default: "proposed"

      # Who applied/rejected and when
      add :reviewed_by,   :integer
      add :reviewed_at,   :utc_datetime
      add :review_note,   :string

      # Optional expiry — decision auto-revokes after this time
      add :expires_at, :utc_datetime

      # If this decision supersedes another, link to it
      add :supersedes_id, references(:trader_decisions, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:trader_decisions, [:product_group, :status])
    create index(:trader_decisions, [:trader_id])
    create index(:trader_decisions, [:status])
    create index(:trader_decisions, [:supersedes_id])
  end
end
