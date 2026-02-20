defmodule TradingDesk.Repo.Migrations.AddFleetTrackingAndNotifications do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # TRACKED VESSELS — add Trammo fleet flag
    # Separate from `status` so a vessel can be "in_transit" but
    # NOT counted toward the Trammo operational fleet (e.g., spot charter).
    # The trader toggles track_in_fleet per vessel from the Fleet tab.
    # ──────────────────────────────────────────────────────────

    alter table(:tracked_vessels) do
      add :track_in_fleet, :boolean, null: false, default: true
      add :vessel_type,    :string   # towboat | barge | gas_carrier | bulk_carrier | chemical_tanker
      add :operator,       :string   # e.g. "Kirby", "ARTCO", "Marquette", "Navigator Gas"
      add :flag_state,     :string   # ISO 3166-1 alpha-2 e.g. "US", "LR", "MH"
      add :capacity_mt,    :float    # max cargo capacity in metric tons
      add :river_segment,  :string   # "upper_mississippi" | "lower_mississippi" | "gulf" | "international"
    end

    create index(:tracked_vessels, [:track_in_fleet])
    create index(:tracked_vessels, [:river_segment])

    # ──────────────────────────────────────────────────────────
    # TRADERS — notification preferences
    # email already exists; add channel flags and threshold config.
    # ──────────────────────────────────────────────────────────

    alter table(:traders) do
      add :notify_email,     :boolean, null: false, default: true
      add :notify_slack,     :boolean, null: false, default: false
      add :notify_teams,     :boolean, null: false, default: false
      add :slack_webhook_url, :string   # trader's personal Slack incoming webhook
      add :teams_webhook_url, :string   # trader's personal Teams incoming webhook
      # Notification threshold: only fire when profit delta >= this value (USD)
      add :notify_threshold_profit, :float, default: 5000.0
      # Minimum interval between notifications (minutes) — rate-limit spam
      add :notify_cooldown_minutes, :integer, default: 30
      # Suppress all notifications flag (trader can mute themselves)
      add :notifications_paused, :boolean, null: false, default: false
    end

    # ──────────────────────────────────────────────────────────
    # API SOURCE REGISTRY
    # Tracks every external API used by the poller, when it was
    # last refreshed, what variables it feeds, and its poll schedule.
    # The API tab reads from this table to render a live dashboard.
    # ──────────────────────────────────────────────────────────

    create table(:api_sources) do
      add :source_key,      :string, null: false   # "vessel_tracking" | "weather" | "river_stage" | etc.
      add :display_name,    :string, null: false   # human-readable label for the API tab
      add :description,     :text                  # what data it provides
      add :api_endpoint,    :string                # base URL (no secrets)
      add :poll_interval_s, :integer               # nominal poll interval in seconds
      add :variables_fed,   {:array, :string}, default: []   # variable keys this API feeds
      add :product_groups,  {:array, :string}, default: []   # which desks use this API
      add :last_polled_at,  :utc_datetime          # when poller last ran
      add :last_success_at, :utc_datetime          # last successful response
      add :last_error,      :text                  # last error message, if any
      add :consecutive_failures, :integer, null: false, default: 0
      add :enabled,         :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_sources, [:source_key])
    create index(:api_sources, [:enabled])
  end
end
