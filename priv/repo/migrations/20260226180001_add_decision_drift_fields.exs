defmodule TradingDesk.Repo.Migrations.AddDecisionDriftFields do
  use Ecto.Migration

  def change do
    alter table(:trader_decisions) do
      # Snapshot of LiveState values at the moment the decision was committed.
      # Used to compute drift — how far reality has moved since the override.
      # Stores only the keys that appear in variable_changes.
      add :baseline_snapshot, :map, default: %{}

      # Computed drift score (0.0–1.0+). Updated by DecisionLedger on each
      # data refresh. >1.0 means live data has moved past the override.
      add :drift_score, :float, default: 0.0

      # When drift_score exceeds the auto-deactivate threshold, this is set
      # and the decision is deactivated. Null = no staleness problem.
      add :drift_revoked_at, :utc_datetime

      # Who deactivated and when (for the deactivated status)
      add :deactivated_by, :integer
      add :deactivated_at, :utc_datetime
    end

    # ── Trader Notifications ──────────────────────────────────────────────
    # Live notifications for decision lifecycle events.
    # Each notification targets a specific trader and can be acknowledged.
    create table(:trader_notifications) do
      # Which trader should see this notification
      add :trader_id, :integer, null: false

      # The decision this relates to
      add :decision_id, references(:trader_decisions, on_delete: :delete_all), null: false

      # Notification type
      # decision_proposed: someone proposed a new decision
      # deactivate_requested: another trader wants to deactivate your decision
      # decision_applied: a decision was applied to shared state
      # decision_rejected: a decision was rejected
      # decision_deactivated: a decision was deactivated
      # decision_reactivated: a decision was reactivated
      # drift_warning: a decision has drifted from reality
      # drift_critical: a decision has critically drifted, auto-deactivated
      add :type, :string, null: false

      # Who triggered this notification (null for system-generated like drift)
      add :triggered_by_id, :integer
      add :triggered_by_name, :string

      # Human-readable message
      add :message, :string, null: false

      # Extra data (drift score, variable details, etc.)
      add :metadata, :map, default: %{}

      # Has the trader seen/acknowledged it?
      add :read, :boolean, default: false
      add :read_at, :utc_datetime

      # For deactivate_requested: the trader's response
      # nil = pending, "accepted" = agreed, "rejected" = refused
      add :response, :string
      add :responded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:trader_notifications, [:trader_id, :read])
    create index(:trader_notifications, [:decision_id])
    create index(:trader_notifications, [:type])
  end
end
