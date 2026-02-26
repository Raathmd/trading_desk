defmodule TradingDesk.Decisions.TraderDecision do
  @moduledoc """
  Ecto schema for a trader decision — an append-only record of a trader's
  committed change to shared state variables.

  ## Status lifecycle

      draft       → proposed     (trader promotes their private what-if)
      proposed    → applied      (another trader or self approves it)
      proposed    → rejected     (another trader rejects it)
      proposed    → revoked      (original trader withdraws it)
      applied     → deactivated  (trader toggles it off, or drift auto-deactivates)
      deactivated → applied      (trader reactivates it)
      applied     → superseded   (a newer decision replaces it for the same variable(s))
      applied     → revoked      (trader undoes it permanently)

  ## Variable change modes

  Each variable key in `variable_changes` can operate in one of two modes
  (tracked in `change_modes`):

    - `:absolute` — the value replaces the LiveState value entirely.
      Example: "barge_count is 13" regardless of what the API says.

    - `:relative` — the value is a delta added to the current LiveState value.
      Example: "add +4 hrs to lock_hrs" — floats on top of API refreshes.

  Keys not present in `change_modes` default to `:absolute`.

  ## Drift detection

  When a decision is applied, `baseline_snapshot` records what LiveState looked
  like at that moment (only the keys in `variable_changes`). On each data refresh,
  `drift_score` is recomputed. If drift exceeds a threshold, the decision is
  auto-deactivated and traders are notified.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias TradingDesk.Repo

  @valid_statuses ~w(draft proposed applied deactivated superseded rejected revoked)

  schema "trader_decisions" do
    field :trader_id,        :integer
    field :trader_name,      :string
    field :product_group,    :string

    # %{"barge_count" => 13.0, "lock_hrs" => 4.0}
    field :variable_changes, :map, default: %{}
    # %{"barge_count" => "absolute", "lock_hrs" => "relative"}
    field :change_modes,     :map, default: %{}

    field :reason,  :string
    field :intent,  :map
    field :audit_id, :string

    field :status, :string, default: "proposed"

    field :reviewed_by,  :integer
    field :reviewed_at,  :utc_datetime
    field :review_note,  :string

    field :expires_at,    :utc_datetime
    field :supersedes_id, :integer

    # Drift detection — tracks how far reality has moved since the override
    field :baseline_snapshot, :map, default: %{}
    field :drift_score,       :float, default: 0.0
    field :drift_revoked_at,  :utc_datetime

    # Deactivation tracking
    field :deactivated_by, :integer
    field :deactivated_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :trader_id, :trader_name, :product_group,
      :variable_changes, :change_modes,
      :reason, :intent, :audit_id,
      :status, :reviewed_by, :reviewed_at, :review_note,
      :expires_at, :supersedes_id,
      :baseline_snapshot, :drift_score, :drift_revoked_at,
      :deactivated_by, :deactivated_at
    ])
    |> validate_required([:trader_id, :trader_name, :product_group, :variable_changes])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_changes_non_empty()
  end

  defp validate_changes_non_empty(changeset) do
    case get_field(changeset, :variable_changes) do
      changes when is_map(changes) and map_size(changes) > 0 -> changeset
      _ -> add_error(changeset, :variable_changes, "must contain at least one variable change")
    end
  end

  # ── Queries ──────────────────────────────────────────────────────────────

  @doc "List all decisions for a product group, newest first."
  def list_for_product_group(pg, opts \\ []) do
    status_filter = Keyword.get(opts, :status, :all)

    query =
      from d in __MODULE__,
        where: d.product_group == ^to_string(pg),
        order_by: [desc: d.inserted_at]

    query =
      if status_filter != :all and to_string(status_filter) in @valid_statuses do
        from d in query, where: d.status == ^to_string(status_filter)
      else
        query
      end

    Repo.all(query)
  rescue
    _ -> []
  end

  @doc "List only applied decisions for a product group (used for effective state)."
  def list_applied(pg) do
    from(d in __MODULE__,
      where: d.product_group == ^to_string(pg) and d.status == "applied",
      order_by: [asc: d.inserted_at]
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Create a new decision as a draft (private to the trader)."
  def create_draft(attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :status, "draft"))
    |> Repo.insert()
  end

  @doc "Create a new decision (starts as proposed — visible to all traders)."
  def create(attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :status, "proposed"))
    |> Repo.insert()
  end

  @doc "Promote a draft to proposed — makes it visible to other traders."
  def promote(%__MODULE__{status: "draft"} = decision) do
    decision
    |> changeset(%{status: "proposed"})
    |> Repo.update()
  end

  def promote(%__MODULE__{}), do: {:error, :not_draft}

  @doc "Apply a proposed decision — makes it affect shared state."
  def apply_decision(%__MODULE__{status: "proposed"} = decision, reviewer_id, note \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    decision
    |> changeset(%{
      status: "applied",
      reviewed_by: reviewer_id,
      reviewed_at: now,
      review_note: note
    })
    |> Repo.update()
  end

  def apply_decision(%__MODULE__{}, _reviewer_id, _note),
    do: {:error, :not_proposed}

  @doc "Reject a proposed decision."
  def reject_decision(%__MODULE__{status: "proposed"} = decision, reviewer_id, note \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    decision
    |> changeset(%{
      status: "rejected",
      reviewed_by: reviewer_id,
      reviewed_at: now,
      review_note: note
    })
    |> Repo.update()
  end

  def reject_decision(%__MODULE__{}, _reviewer_id, _note),
    do: {:error, :not_proposed}

  @doc """
  Deactivate an applied decision — temporarily removes it from effective state.
  The decision can be reactivated later. Used by the trader toggle or by
  drift auto-deactivation.
  """
  def deactivate(%__MODULE__{status: "applied"} = decision, deactivator_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    decision
    |> changeset(%{
      status: "deactivated",
      deactivated_by: deactivator_id,
      deactivated_at: now
    })
    |> Repo.update()
  end

  def deactivate(%__MODULE__{}, _deactivator_id), do: {:error, :not_applied}

  @doc "Deactivate due to drift — records the drift_revoked_at timestamp."
  def drift_deactivate(%__MODULE__{status: "applied"} = decision) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    decision
    |> changeset(%{
      status: "deactivated",
      deactivated_at: now,
      drift_revoked_at: now
    })
    |> Repo.update()
  end

  def drift_deactivate(%__MODULE__{}), do: {:error, :not_applied}

  @doc "Reactivate a deactivated decision — puts it back into effective state."
  def reactivate(%__MODULE__{status: "deactivated"} = decision, reviewer_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    decision
    |> changeset(%{
      status: "applied",
      reviewed_by: reviewer_id,
      reviewed_at: now,
      deactivated_by: nil,
      deactivated_at: nil,
      drift_revoked_at: nil,
      drift_score: 0.0
    })
    |> Repo.update()
  end

  def reactivate(%__MODULE__{}, _reviewer_id), do: {:error, :not_deactivated}

  @doc "Revoke a decision (original trader withdraws or undoes applied decision)."
  def revoke_decision(%__MODULE__{status: status} = decision)
      when status in ["draft", "proposed", "applied", "deactivated"] do
    decision
    |> changeset(%{status: "revoked"})
    |> Repo.update()
  end

  def revoke_decision(%__MODULE__{}), do: {:error, :cannot_revoke}

  @doc "Mark a decision as superseded by a newer one."
  def supersede(%__MODULE__{status: "applied"} = decision, new_decision_id) do
    decision
    |> changeset(%{status: "superseded"})
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        # Update the new decision to reference the one it supersedes
        from(d in __MODULE__, where: d.id == ^new_decision_id)
        |> Repo.update_all(set: [supersedes_id: updated.id])
        {:ok, updated}
      error -> error
    end
  end

  def supersede(%__MODULE__{}, _new_id), do: {:error, :not_applied}

  @doc "Update drift score for a decision."
  def update_drift(%__MODULE__{} = decision, score) do
    decision
    |> changeset(%{drift_score: score})
    |> Repo.update()
  end

  @doc "Record the baseline snapshot when a decision is applied."
  def set_baseline(%__MODULE__{} = decision, snapshot) do
    decision
    |> changeset(%{baseline_snapshot: snapshot})
    |> Repo.update()
  end

  @doc "Get a decision by ID."
  def get(id) do
    Repo.get(__MODULE__, id)
  rescue
    _ -> nil
  end

  @doc """
  Find applied decisions that conflict with a proposed decision
  (i.e. touch the same variable keys).
  """
  def find_conflicts(%__MODULE__{} = decision) do
    changed_keys = Map.keys(decision.variable_changes)

    list_applied(decision.product_group)
    |> Enum.filter(fn applied ->
      applied_keys = Map.keys(applied.variable_changes)
      Enum.any?(changed_keys, &(&1 in applied_keys))
    end)
  end

  @doc """
  Find proposed decisions that touch the same variables as the given decision.
  Used for conflict highlighting in the UI.
  """
  def find_proposed_conflicts(%__MODULE__{} = decision) do
    changed_keys = Map.keys(decision.variable_changes)

    from(d in __MODULE__,
      where: d.product_group == ^decision.product_group
             and d.status == "proposed"
             and d.id != ^decision.id,
      order_by: [desc: d.inserted_at]
    )
    |> Repo.all()
    |> Enum.filter(fn proposed ->
      proposed_keys = Map.keys(proposed.variable_changes)
      Enum.any?(changed_keys, &(&1 in proposed_keys))
    end)
  rescue
    _ -> []
  end
end
