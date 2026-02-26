defmodule TradingDesk.Decisions.DecisionLedger do
  @moduledoc """
  GenServer that manages the decision ledger — the shared layer between
  raw LiveState (API feeds) and what traders see as "effective state."

  ## Architecture

      effective_state = LiveState (API feeds) + applied decision deltas

  Applied decisions are cached in ETS for fast reads. On startup, the ledger
  loads all applied decisions from Postgres. As decisions are proposed, applied,
  revoked, or superseded, the ETS cache and PubSub broadcasts are kept in sync.

  ## PubSub topic: "decisions"

  Events broadcast:
    - `{:decision_proposed, decision}`  — new decision visible to all
    - `{:decision_applied,  decision}`  — affects effective state
    - `{:decision_rejected, decision}`  — proposal turned down
    - `{:decision_revoked,  decision}`  — withdrawn/undone
    - `{:decision_superseded, old, new}` — old replaced by new

  ## Reingestion safety

  When LiveState refreshes (API polling, contract reingestion), effective state
  is recomputed from the new base + all applied deltas. Decisions are never lost
  by data refreshes because they are stored independently in Postgres.
  """

  use GenServer
  require Logger

  alias TradingDesk.Decisions.TraderDecision
  alias TradingDesk.Data.LiveState

  @ets_table :decision_ledger

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Compute the effective state for a product group.
  Merges LiveState base values with all applied decision changes.
  Returns a plain map (same shape as Variables struct fields).
  """
  def effective_state(product_group) do
    GenServer.call(__MODULE__, {:effective_state, product_group})
  end

  @doc "Propose a new decision. Returns {:ok, decision} or {:error, changeset}."
  def propose(attrs) do
    GenServer.call(__MODULE__, {:propose, attrs})
  end

  @doc "Apply a proposed decision. Returns {:ok, decision} or {:error, reason}."
  def apply_decision(decision_id, reviewer_id, note \\ nil) do
    GenServer.call(__MODULE__, {:apply_decision, decision_id, reviewer_id, note})
  end

  @doc "Reject a proposed decision."
  def reject_decision(decision_id, reviewer_id, note \\ nil) do
    GenServer.call(__MODULE__, {:reject_decision, decision_id, reviewer_id, note})
  end

  @doc "Revoke a decision (proposed or applied)."
  def revoke_decision(decision_id) do
    GenServer.call(__MODULE__, {:revoke_decision, decision_id})
  end

  @doc "List all decisions for a product group."
  def list(product_group, opts \\ []) do
    TraderDecision.list_for_product_group(product_group, opts)
  end

  @doc "List only applied decisions from ETS cache (fast)."
  def applied_decisions(product_group) do
    pg_str = to_string(product_group)

    case :ets.lookup(@ets_table, pg_str) do
      [{^pg_str, decisions}] -> decisions
      [] -> []
    end
  end

  @doc "Get a decision by ID."
  def get(decision_id) do
    TraderDecision.get(decision_id)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_) do
    table = :ets.new(@ets_table, [:named_table, :set, :protected, read_concurrency: true])

    # Subscribe to live_data so we know when to recompute
    Phoenix.PubSub.subscribe(TradingDesk.PubSub, "live_data")

    # Load applied decisions from DB into ETS cache
    load_applied_from_db()

    # Schedule periodic expiry check
    Process.send_after(self(), :check_expiry, :timer.minutes(1))

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:effective_state, product_group}, _from, state) do
    result = compute_effective_state(product_group)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:propose, attrs}, _from, state) do
    case TraderDecision.create(attrs) do
      {:ok, decision} ->
        broadcast(:decision_proposed, decision)
        Logger.info("[DecisionLedger] Decision proposed by #{decision.trader_name}: #{decision.reason}")
        {:reply, {:ok, decision}, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_call({:apply_decision, decision_id, reviewer_id, note}, _from, state) do
    case TraderDecision.get(decision_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decision ->
        # Auto-supersede any currently applied decisions that touch the same variables
        conflicts = TraderDecision.find_conflicts(decision)

        Enum.each(conflicts, fn old ->
          case TraderDecision.supersede(old, decision.id) do
            {:ok, superseded} ->
              broadcast(:decision_superseded, %{old: superseded, new: decision})
            _ -> :ok
          end
        end)

        case TraderDecision.apply_decision(decision, reviewer_id, note) do
          {:ok, applied} ->
            refresh_ets_cache(applied.product_group)
            broadcast(:decision_applied, applied)
            Logger.info("[DecisionLedger] Decision ##{applied.id} applied by reviewer #{reviewer_id}")
            {:reply, {:ok, applied}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:reject_decision, decision_id, reviewer_id, note}, _from, state) do
    case TraderDecision.get(decision_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decision ->
        case TraderDecision.reject_decision(decision, reviewer_id, note) do
          {:ok, rejected} ->
            broadcast(:decision_rejected, rejected)
            {:reply, {:ok, rejected}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:revoke_decision, decision_id}, _from, state) do
    case TraderDecision.get(decision_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decision ->
        was_applied = decision.status == "applied"

        case TraderDecision.revoke_decision(decision) do
          {:ok, revoked} ->
            if was_applied, do: refresh_ets_cache(revoked.product_group)
            broadcast(:decision_revoked, revoked)
            {:reply, {:ok, revoked}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  # When LiveState refreshes, we don't need to do anything to ETS —
  # effective_state is computed on-the-fly from LiveState + cached deltas.
  # But we broadcast so LiveViews know to re-read effective state.
  @impl true
  def handle_info({:data_updated, _source}, state) do
    broadcast(:effective_state_changed, %{reason: :live_data_refresh})
    {:noreply, state}
  end

  @impl true
  def handle_info({:supplementary_updated, _}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_expiry, state) do
    expire_old_decisions()
    Process.send_after(self(), :check_expiry, :timer.minutes(1))
    {:noreply, state}
  end

  # ── Internal ────────────────────────────────────────────────────────────

  defp compute_effective_state(product_group) do
    # Start with raw LiveState values
    base = LiveState.get()
    base_map = if is_struct(base), do: Map.from_struct(base), else: base

    # Layer on all applied decisions
    applied = applied_decisions(to_string(product_group))

    Enum.reduce(applied, base_map, fn decision, acc ->
      Enum.reduce(decision.variable_changes, acc, fn {key_str, value}, inner_acc ->
        key = safe_to_atom(key_str)
        if key == nil, do: inner_acc, else: apply_change(inner_acc, key, key_str, value, decision.change_modes)
      end)
    end)
  end

  defp apply_change(state_map, key, key_str, value, change_modes) do
    mode = Map.get(change_modes, key_str, "absolute")

    case mode do
      "relative" ->
        base_val = Map.get(state_map, key, 0)
        Map.put(state_map, key, base_val + value)

      _ ->
        # absolute — override directly
        Map.put(state_map, key, value)
    end
  end

  defp safe_to_atom(key_str) when is_binary(key_str) do
    String.to_existing_atom(key_str)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_atom(key) when is_atom(key), do: key

  defp load_applied_from_db do
    # Load applied decisions for all product groups and cache in ETS
    all_pgs = ~w(ammonia_domestic ammonia_international sulphur_international petcoke)

    Enum.each(all_pgs, fn pg ->
      decisions = TraderDecision.list_applied(pg)
      :ets.insert(@ets_table, {pg, decisions})
    end)
  rescue
    error ->
      Logger.warning("[DecisionLedger] Failed to load from DB: #{inspect(error)}")
  end

  defp refresh_ets_cache(product_group) do
    pg_str = to_string(product_group)
    decisions = TraderDecision.list_applied(pg_str)
    :ets.insert(@ets_table, {pg_str, decisions})
  end

  defp expire_old_decisions do
    now = DateTime.utc_now()

    # Find applied decisions that have expired
    ~w(ammonia_domestic ammonia_international sulphur_international petcoke)
    |> Enum.each(fn pg ->
      applied_decisions(pg)
      |> Enum.filter(fn d -> d.expires_at && DateTime.compare(d.expires_at, now) == :lt end)
      |> Enum.each(fn d ->
        case TraderDecision.revoke_decision(d) do
          {:ok, revoked} ->
            refresh_ets_cache(pg)
            broadcast(:decision_revoked, revoked)
            Logger.info("[DecisionLedger] Decision ##{d.id} auto-expired")
          _ -> :ok
        end
      end)
    end)
  rescue
    _ -> :ok
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(
      TradingDesk.PubSub,
      "decisions",
      {event, payload}
    )
  end
end
