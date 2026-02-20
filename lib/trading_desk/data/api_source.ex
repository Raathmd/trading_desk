defmodule TradingDesk.Data.ApiSource do
  @moduledoc """
  Persisted registry of every external API used by the Poller.

  Updated by the Poller after each poll cycle to record:
    - last_polled_at    — when the poll ran (regardless of success)
    - last_success_at   — when data was successfully received
    - last_error        — last error message (nil when healthy)
    - consecutive_failures — cleared on success

  The API tab reads this table to surface live status and variable metadata.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias TradingDesk.Repo

  schema "api_sources" do
    field :source_key,           :string
    field :display_name,         :string
    field :description,          :string
    field :api_endpoint,         :string
    field :poll_interval_s,      :integer
    field :variables_fed,        {:array, :string}, default: []
    field :product_groups,       {:array, :string}, default: []
    field :last_polled_at,       :utc_datetime
    field :last_success_at,      :utc_datetime
    field :last_error,           :string
    field :consecutive_failures, :integer, default: 0
    field :enabled,              :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(src, attrs) do
    src
    |> cast(attrs, [
      :source_key, :display_name, :description, :api_endpoint,
      :poll_interval_s, :variables_fed, :product_groups,
      :last_polled_at, :last_success_at, :last_error,
      :consecutive_failures, :enabled
    ])
    |> validate_required([:source_key, :display_name])
    |> unique_constraint(:source_key)
  end

  # ── Queries ─────────────────────────────────────────────────

  @doc "All API sources ordered by display_name."
  def list_all do
    from(s in __MODULE__, order_by: [asc: s.display_name])
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "All enabled sources."
  def list_enabled do
    from(s in __MODULE__, where: s.enabled == true, order_by: [asc: s.display_name])
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Get by source_key."
  def get(source_key) when is_atom(source_key),
    do: get(to_string(source_key))

  def get(source_key) when is_binary(source_key) do
    Repo.get_by(__MODULE__, source_key: source_key)
  end

  # ── Mutations ────────────────────────────────────────────────

  @doc "Record a successful poll."
  def record_success(source_key, extra_attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    upsert(source_key, Map.merge(extra_attrs, %{
      last_polled_at:       now,
      last_success_at:      now,
      last_error:           nil,
      consecutive_failures: 0
    }))
  end

  @doc "Record a failed poll."
  def record_failure(source_key, error_msg) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    existing = get(source_key)
    failures = (existing && existing.consecutive_failures || 0) + 1
    upsert(source_key, %{
      last_polled_at:       now,
      last_error:           to_string(error_msg),
      consecutive_failures: failures
    })
  end

  defp upsert(source_key, attrs) when is_atom(source_key), do: upsert(to_string(source_key), attrs)
  defp upsert(source_key, attrs) when is_binary(source_key) do
    case Repo.get_by(__MODULE__, source_key: source_key) do
      nil ->
        %__MODULE__{}
        |> changeset(Map.put(attrs, :source_key, source_key))
        |> Repo.insert(on_conflict: :replace_all, conflict_target: :source_key)
      existing ->
        existing
        |> changeset(attrs)
        |> Repo.update()
    end
  rescue
    _ -> {:error, :db_unavailable}
  end
end
