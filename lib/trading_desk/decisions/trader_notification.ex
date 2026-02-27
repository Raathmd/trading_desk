defmodule TradingDesk.Decisions.TraderNotification do
  @moduledoc """
  Live notifications for decision lifecycle events.

  Every time a decision changes state — proposed, applied, deactivated, drift
  detected — notifications are created for the relevant traders and broadcast
  via PubSub so LiveViews update in real time.

  ## Notification types

    - `decision_proposed`       — a new decision needs review
    - `decision_applied`        — a decision was applied to shared state
    - `decision_rejected`       — a decision was rejected
    - `decision_deactivated`    — a decision was deactivated (manual or drift)
    - `decision_reactivated`    — a deactivated decision was reactivated
    - `deactivate_requested`    — another trader wants to deactivate your decision
    - `drift_warning`           — a decision has drifted significantly from reality
    - `drift_critical`          — a decision was auto-deactivated due to drift

  ## Response flow (for deactivate_requested)

  When trader A wants to deactivate trader B's decision:
    1. A notification with type `deactivate_requested` is created for trader B
    2. Trader B can respond with "accepted" or "rejected"
    3. If accepted, the decision is deactivated
    4. If rejected, the decision stays applied and trader A is notified
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias TradingDesk.Repo

  @valid_types ~w(
    decision_proposed decision_applied decision_rejected
    decision_deactivated decision_reactivated
    deactivate_requested
    drift_warning drift_critical
  )

  @valid_responses ~w(accepted rejected)

  schema "trader_notifications" do
    field :trader_id,          :integer
    field :decision_id,        :integer
    field :type,               :string
    field :triggered_by_id,    :integer
    field :triggered_by_name,  :string
    field :message,            :string
    field :metadata,           :map, default: %{}
    field :read,               :boolean, default: false
    field :read_at,            :utc_datetime
    field :response,           :string
    field :responded_at,       :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [
      :trader_id, :decision_id, :type,
      :triggered_by_id, :triggered_by_name,
      :message, :metadata,
      :read, :read_at,
      :response, :responded_at
    ])
    |> validate_required([:trader_id, :decision_id, :type, :message])
    |> validate_inclusion(:type, @valid_types)
  end

  # ── Create ──────────────────────────────────────────────────────────────

  @doc "Create a notification for a specific trader."
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create notifications for all traders EXCEPT the triggering trader.
  Used when a decision is proposed/applied/etc. — everyone else should know.
  Returns a list of created notifications.
  """
  def notify_all_except(decision, type, triggered_by_id, triggered_by_name, message, metadata \\ %{}) do
    traders = TradingDesk.Traders.list_active()

    notifications =
      traders
      |> Enum.reject(&(&1.id == triggered_by_id))
      |> Enum.map(fn trader ->
        case create(%{
          trader_id: trader.id,
          decision_id: decision.id,
          type: type,
          triggered_by_id: triggered_by_id,
          triggered_by_name: triggered_by_name,
          message: message,
          metadata: metadata
        }) do
          {:ok, notif} -> notif
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Broadcast to the PubSub topic so LiveViews pick it up immediately
    Enum.each(notifications, fn notif ->
      Phoenix.PubSub.broadcast(
        TradingDesk.PubSub,
        "notifications:#{notif.trader_id}",
        {:new_notification, notif}
      )
    end)

    notifications
  end

  @doc "Create a notification for a specific trader (e.g. the decision owner)."
  def notify_one(trader_id, decision, type, triggered_by_id, triggered_by_name, message, metadata \\ %{}) do
    case create(%{
      trader_id: trader_id,
      decision_id: decision.id,
      type: type,
      triggered_by_id: triggered_by_id,
      triggered_by_name: triggered_by_name,
      message: message,
      metadata: metadata
    }) do
      {:ok, notif} ->
        Phoenix.PubSub.broadcast(
          TradingDesk.PubSub,
          "notifications:#{trader_id}",
          {:new_notification, notif}
        )
        {:ok, notif}

      error ->
        error
    end
  end

  # ── Read / Query ────────────────────────────────────────────────────────

  @doc "List unread notifications for a trader, newest first."
  def list_unread(trader_id) do
    from(n in __MODULE__,
      where: n.trader_id == ^trader_id and n.read == false,
      order_by: [desc: n.inserted_at],
      limit: 50
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "List all recent notifications for a trader (read + unread)."
  def list_recent(trader_id, limit \\ 30) do
    from(n in __MODULE__,
      where: n.trader_id == ^trader_id,
      order_by: [desc: n.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Count unread notifications for a trader."
  def unread_count(trader_id) do
    from(n in __MODULE__,
      where: n.trader_id == ^trader_id and n.read == false,
      select: count(n.id)
    )
    |> Repo.one()
  rescue
    _ -> 0
  end

  @doc "Get pending deactivation requests for a decision."
  def pending_deactivate_requests(decision_id) do
    from(n in __MODULE__,
      where: n.decision_id == ^decision_id
             and n.type == "deactivate_requested"
             and is_nil(n.response),
      order_by: [desc: n.inserted_at]
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  # ── Actions ─────────────────────────────────────────────────────────────

  @doc "Mark a notification as read."
  def mark_read(%__MODULE__{} = notification) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    notification
    |> changeset(%{read: true, read_at: now})
    |> Repo.update()
  end

  @doc "Mark all unread notifications for a trader as read."
  def mark_all_read(trader_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(n in __MODULE__,
      where: n.trader_id == ^trader_id and n.read == false
    )
    |> Repo.update_all(set: [read: true, read_at: now])
  rescue
    _ -> {0, nil}
  end

  @doc "Respond to a deactivation request (accept or reject)."
  def respond(%__MODULE__{type: "deactivate_requested"} = notification, response)
      when response in @valid_responses do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    notification
    |> changeset(%{
      response: response,
      responded_at: now,
      read: true,
      read_at: now
    })
    |> Repo.update()
  end

  def respond(%__MODULE__{}, _response), do: {:error, :not_deactivate_request}

  @doc "Get a notification by ID."
  def get(id) do
    Repo.get(__MODULE__, id)
  rescue
    _ -> nil
  end
end
