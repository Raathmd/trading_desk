defmodule TradingDesk.DB.TraderRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "traders" do
    field :name,   :string
    field :email,  :string
    field :active, :boolean, default: true

    # Notification channel preferences
    field :notify_email,            :boolean, default: true
    field :notify_slack,            :boolean, default: false
    field :notify_teams,            :boolean, default: false
    field :slack_webhook_url,       :string
    field :teams_webhook_url,       :string
    # Fire threshold: minimum profit delta (USD) before a notification is sent
    field :notify_threshold_profit, :float, default: 5000.0
    # Rate limit: minimum minutes between notifications
    field :notify_cooldown_minutes, :integer, default: 30
    # Global mute — trader can pause all notifications
    field :notifications_paused,    :boolean, default: false

    has_many :product_groups, TradingDesk.DB.TraderProductGroupRecord,
      foreign_key: :trader_id

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :name, :email, :active,
      :notify_email, :notify_slack, :notify_teams,
      :slack_webhook_url, :teams_webhook_url,
      :notify_threshold_profit, :notify_cooldown_minutes,
      :notifications_paused
    ])
    |> validate_required([:name])
    |> validate_number(:notify_threshold_profit, greater_than_or_equal_to: 0)
    |> validate_number(:notify_cooldown_minutes, greater_than_or_equal_to: 1)
  end
end

defmodule TradingDesk.DB.TraderProductGroupRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trader_product_groups" do
    field :product_group, :string
    field :is_primary,    :boolean, default: false

    belongs_to :trader, TradingDesk.DB.TraderRecord

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:trader_id, :product_group, :is_primary])
    |> validate_required([:trader_id, :product_group])
  end
end
