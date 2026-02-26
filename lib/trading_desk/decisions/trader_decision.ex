defmodule TradingDesk.Decisions.TraderDecision do
  @moduledoc """
  Ecto schema for a trader decision — an append-only record of a trader's
  committed change to shared state variables.

  ## Status lifecycle

      proposed → applied     (another trader or self approves it)
      proposed → rejected    (another trader rejects it)
      proposed → revoked     (original trader withdraws it)
      applied  → superseded  (a newer decision replaces it for the same variable(s))
      applied  → revoked     (trader undoes it)

  ## Variable change modes

  Each variable key in `variable_changes` can operate in one of two modes
  (tracked in `change_modes`):

    - `:absolute` — the value replaces the LiveState value entirely.
      Example: "barge_count is 13" regardless of what the API says.

    - `:relative` — the value is a delta added to the current LiveState value.
      Example: "add +4 hrs to lock_hrs" — floats on top of API refreshes.

  Keys not present in `change_modes` default to `:absolute`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias TradingDesk.Repo

  @valid_statuses ~w(proposed applied superseded rejected revoked)

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

    timestamps(type: :utc_datetime)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :trader_id, :trader_name, :product_group,
      :variable_changes, :change_modes,
      :reason, :intent, :audit_id,
      :status, :reviewed_by, :reviewed_at, :review_note,
      :expires_at, :supersedes_id
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

  @doc "Create a new decision (always starts as proposed)."
  def create(attrs) do
    %__MODULE__{}
    |> changeset(Map.put(attrs, :status, "proposed"))
    |> Repo.insert()
  end

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

  @doc "Revoke a decision (original trader withdraws or undoes applied decision)."
  def revoke_decision(%__MODULE__{status: status} = decision) when status in ["proposed", "applied"] do
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
