defmodule TradingDesk.Decisions.DecisionLedger do
  @moduledoc """
  GenServer that manages the decision ledger — the shared layer between
  raw LiveState (API feeds) and what traders see as "effective state."

  ## Architecture

      effective_state = LiveState (API feeds) + applied decision deltas

  Applied decisions are cached in ETS for fast reads. On startup, the ledger
  loads all applied decisions from Postgres. As decisions are proposed, applied,
  revoked, or superseded, the ETS cache and PubSub broadcasts are kept in sync.

  ## Decision lifecycle

      draft       → proposed     (trader promotes their private what-if)
      proposed    → applied      (another trader or self approves it)
      proposed    → rejected     (another trader rejects it)
      proposed    → revoked      (original trader withdraws it)
      applied     → deactivated  (trader toggles off, or drift auto-deactivates)
      deactivated → applied      (trader reactivates)
      applied     → superseded   (newer decision replaces it)

  ## PubSub topic: "decisions"

  Events broadcast:
    - `{:decision_proposed, decision}`     — new decision visible to all
    - `{:decision_applied,  decision}`     — affects effective state
    - `{:decision_rejected, decision}`     — proposal turned down
    - `{:decision_revoked,  decision}`     — withdrawn/undone
    - `{:decision_deactivated, decision}`  — temporarily removed from state
    - `{:decision_reactivated, decision}`  — put back into state
    - `{:decision_superseded, old, new}`   — old replaced by new
    - `{:drift_warning, decision, score}`  — decision drifting from reality
    - `{:drift_critical, decision, score}` — decision auto-deactivated

  ## Drift detection

  On every LiveState refresh, the ledger recomputes drift scores for all
  applied decisions. Drift = how far the live base has moved relative to
  the decision's baseline snapshot.

    drift_score = max across variables of |live_now - baseline| / |override - baseline|

  Thresholds:
    - warning  >= 0.5 — reality has moved halfway to the override value
    - critical >= 1.0 — reality has moved past the override (override is stale)

  When critical drift is detected, the decision is auto-deactivated and all
  traders are notified.
  """

  use GenServer
  require Logger

  alias TradingDesk.Decisions.TraderDecision
  alias TradingDesk.Decisions.TraderNotification
  alias TradingDesk.Data.LiveState

  @ets_table :decision_ledger
  @all_product_groups ~w(ammonia_domestic ammonia_international sulphur_international petcoke)

  # Drift thresholds
  @drift_warning  0.5
  @drift_critical 1.0

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

  @doc "Create a draft decision (private to the trader). Returns {:ok, decision}."
  def create_draft(attrs) do
    GenServer.call(__MODULE__, {:create_draft, attrs})
  end

  @doc "Promote a draft to proposed (visible to all). Returns {:ok, decision}."
  def promote(decision_id) do
    GenServer.call(__MODULE__, {:promote, decision_id})
  end

  @doc "Propose a new decision (skips draft, goes straight to proposed)."
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

  @doc """
  Deactivate an applied decision — temporarily removes it from effective state.
  If the caller is the decision owner, deactivation is immediate.
  If the caller is a different trader, a deactivate_requested notification is
  sent to the owner for approval.
  """
  def deactivate_decision(decision_id, requester_id, requester_name) do
    GenServer.call(__MODULE__, {:deactivate_decision, decision_id, requester_id, requester_name})
  end

  @doc "Reactivate a deactivated decision — puts it back into effective state."
  def reactivate_decision(decision_id, reviewer_id) do
    GenServer.call(__MODULE__, {:reactivate_decision, decision_id, reviewer_id})
  end

  @doc "Respond to a deactivation request notification."
  def respond_to_deactivation(notification_id, response, responder_name) do
    GenServer.call(__MODULE__, {:respond_to_deactivation, notification_id, response, responder_name})
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

    # Subscribe to live_data so we know when to recompute + check drift
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
  def handle_call({:create_draft, attrs}, _from, state) do
    case TraderDecision.create_draft(attrs) do
      {:ok, decision} ->
        Logger.info("[DecisionLedger] Draft created by #{decision.trader_name}: #{decision.reason}")
        {:reply, {:ok, decision}, state}

      {:error, changeset} ->
        {:reply, {:error, changeset}, state}
    end
  end

  @impl true
  def handle_call({:promote, decision_id}, _from, state) do
    case TraderDecision.get(decision_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decision ->
        case TraderDecision.promote(decision) do
          {:ok, proposed} ->
            broadcast(:decision_proposed, proposed)
            # Notify all other traders
            TraderNotification.notify_all_except(
              proposed, "decision_proposed",
              proposed.trader_id, proposed.trader_name,
              "#{proposed.trader_name} proposed a decision: #{proposed.reason || "no reason"}",
              %{variable_keys: Map.keys(proposed.variable_changes)}
            )
            Logger.info("[DecisionLedger] Decision ##{proposed.id} promoted to proposed")
            {:reply, {:ok, proposed}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:propose, attrs}, _from, state) do
    case TraderDecision.create(attrs) do
      {:ok, decision} ->
        broadcast(:decision_proposed, decision)
        # Notify all other traders
        TraderNotification.notify_all_except(
          decision, "decision_proposed",
          decision.trader_id, decision.trader_name,
          "#{decision.trader_name} proposed: #{decision.reason || "no reason"}",
          %{variable_keys: Map.keys(decision.variable_changes)}
        )
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
            # Capture baseline snapshot at the moment of application
            capture_baseline(applied)

            refresh_ets_cache(applied.product_group)
            broadcast(:decision_applied, applied)

            # Notify all other traders
            reviewer_name = trader_name_for_id(reviewer_id)
            TraderNotification.notify_all_except(
              applied, "decision_applied",
              reviewer_id, reviewer_name,
              "#{reviewer_name} applied decision ##{applied.id} by #{applied.trader_name}",
              %{variable_keys: Map.keys(applied.variable_changes)}
            )

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

            reviewer_name = trader_name_for_id(reviewer_id)
            # Notify the decision owner
            TraderNotification.notify_one(
              rejected.trader_id, rejected, "decision_rejected",
              reviewer_id, reviewer_name,
              "#{reviewer_name} rejected your decision ##{rejected.id}: #{note || "no reason"}"
            )
            {:reply, {:ok, rejected}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:deactivate_decision, decision_id, requester_id, requester_name}, _from, state) do
    case TraderDecision.get(decision_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decision ->
        if decision.trader_id == requester_id do
          # Own decision — deactivate immediately
          case TraderDecision.deactivate(decision, requester_id) do
            {:ok, deactivated} ->
              refresh_ets_cache(deactivated.product_group)
              broadcast(:decision_deactivated, deactivated)

              TraderNotification.notify_all_except(
                deactivated, "decision_deactivated",
                requester_id, requester_name,
                "#{requester_name} deactivated their decision ##{deactivated.id}"
              )

              {:reply, {:ok, deactivated}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          # Another trader's decision — send a deactivation request
          TraderNotification.notify_one(
            decision.trader_id, decision, "deactivate_requested",
            requester_id, requester_name,
            "#{requester_name} requests to deactivate your decision ##{decision.id}: #{decision.reason || ""}",
            %{requester_id: requester_id, requester_name: requester_name}
          )

          {:reply, {:ok, :request_sent}, state}
        end
    end
  end

  @impl true
  def handle_call({:reactivate_decision, decision_id, reviewer_id}, _from, state) do
    case TraderDecision.get(decision_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      decision ->
        case TraderDecision.reactivate(decision, reviewer_id) do
          {:ok, reactivated} ->
            # Re-capture baseline at reactivation time
            capture_baseline(reactivated)

            refresh_ets_cache(reactivated.product_group)
            broadcast(:decision_reactivated, reactivated)

            reviewer_name = trader_name_for_id(reviewer_id)
            TraderNotification.notify_all_except(
              reactivated, "decision_reactivated",
              reviewer_id, reviewer_name,
              "#{reviewer_name} reactivated decision ##{reactivated.id}"
            )

            {:reply, {:ok, reactivated}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:respond_to_deactivation, notification_id, response, responder_name}, _from, state) do
    case TraderNotification.get(notification_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      notification ->
        case TraderNotification.respond(notification, response) do
          {:ok, responded} ->
            decision = TraderDecision.get(responded.decision_id)

            if response == "accepted" and decision && decision.status == "applied" do
              # Owner accepted — deactivate the decision
              case TraderDecision.deactivate(decision, notification.trader_id) do
                {:ok, deactivated} ->
                  refresh_ets_cache(deactivated.product_group)
                  broadcast(:decision_deactivated, deactivated)

                  TraderNotification.notify_all_except(
                    deactivated, "decision_deactivated",
                    notification.trader_id, responder_name,
                    "#{responder_name} accepted deactivation of decision ##{deactivated.id}"
                  )

                _ -> :ok
              end
            else
              # Owner rejected — notify the requester
              requester_id = get_in(notification.metadata, ["requester_id"]) ||
                             get_in(notification.metadata, [:requester_id])
              if requester_id do
                TraderNotification.notify_one(
                  requester_id, decision, "decision_rejected",
                  notification.trader_id, responder_name,
                  "#{responder_name} rejected your deactivation request for decision ##{notification.decision_id}"
                )
              end
            end

            {:reply, {:ok, responded}, state}

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

  # ── Data refresh: recompute drift + broadcast ──────────────────────────

  @impl true
  def handle_info({:data_updated, _source}, state) do
    # Recompute drift for all applied decisions
    check_drift()

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

  # ── Internal: effective state ──────────────────────────────────────────

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

  # ── Internal: baseline capture ─────────────────────────────────────────

  defp capture_baseline(decision) do
    base = LiveState.get()
    base_map = if is_struct(base), do: Map.from_struct(base), else: base

    # Only capture the variables this decision touches
    snapshot =
      decision.variable_changes
      |> Map.keys()
      |> Enum.reduce(%{}, fn key_str, acc ->
        key = safe_to_atom(key_str)
        val = if key, do: Map.get(base_map, key), else: nil
        if val != nil, do: Map.put(acc, key_str, val), else: acc
      end)

    TraderDecision.set_baseline(decision, snapshot)
  rescue
    e ->
      Logger.warning("[DecisionLedger] Failed to capture baseline: #{inspect(e)}")
  end

  # ── Internal: drift detection ──────────────────────────────────────────

  defp check_drift do
    base = LiveState.get()
    base_map = if is_struct(base), do: Map.from_struct(base), else: base

    Enum.each(@all_product_groups, fn pg ->
      applied_decisions(pg)
      |> Enum.each(fn decision ->
        score = compute_drift_score(decision, base_map)

        # Only update DB if score changed meaningfully (avoid write storms)
        if abs(score - (decision.drift_score || 0.0)) > 0.05 do
          TraderDecision.update_drift(decision, score)
        end

        cond do
          score >= @drift_critical and (decision.drift_score || 0.0) < @drift_critical ->
            # Just crossed critical threshold — auto-deactivate
            handle_critical_drift(decision, score, pg)

          score >= @drift_warning and (decision.drift_score || 0.0) < @drift_warning ->
            # Just crossed warning threshold — notify
            handle_warning_drift(decision, score)

          true ->
            :ok
        end
      end)
    end)
  rescue
    e ->
      Logger.warning("[DecisionLedger] Drift check failed: #{inspect(e)}")
  end

  defp compute_drift_score(decision, current_base) do
    baseline = decision.baseline_snapshot || %{}

    if map_size(baseline) == 0 do
      0.0
    else
      # For each variable, compute how far live has moved relative to the override
      scores =
        Enum.map(decision.variable_changes, fn {key_str, override_val} ->
          baseline_val = Map.get(baseline, key_str)
          key = safe_to_atom(key_str)
          live_now = if key, do: Map.get(current_base, key), else: nil

          compute_variable_drift(baseline_val, override_val, live_now, key_str, decision.change_modes)
        end)
        |> Enum.reject(&is_nil/1)

      if scores == [] do
        0.0
      else
        # Use the maximum drift across all variables
        Enum.max(scores)
      end
    end
  end

  defp compute_variable_drift(baseline_val, override_val, live_now, key_str, change_modes) do
    mode = Map.get(change_modes || %{}, key_str, "absolute")

    cond do
      # Can't compute drift without numeric values
      not is_number(baseline_val) or not is_number(live_now) ->
        # For booleans: if the override was boolean and live has changed, drift = 1.0
        if is_boolean(override_val) and is_boolean(live_now) and override_val != live_now do
          1.0
        else
          nil
        end

      mode == "relative" ->
        # Relative deltas don't drift in the same way — the delta still applies.
        # Only flag if the base has moved so much that the delta is insignificant.
        if override_val == 0, do: 0.0, else: 0.0

      true ->
        # Absolute mode: drift = |live_now - baseline| / |override - baseline|
        delta_override = abs(override_val - baseline_val)

        if delta_override < 0.001 do
          # Override was basically the same as baseline — it was a no-op.
          # If live has moved away, that's full drift.
          delta_live = abs(live_now - baseline_val)
          if delta_live > 0.001, do: 1.0, else: 0.0
        else
          delta_live = abs(live_now - baseline_val)
          delta_live / delta_override
        end
    end
  end

  defp handle_critical_drift(decision, score, pg) do
    case TraderDecision.drift_deactivate(decision) do
      {:ok, deactivated} ->
        refresh_ets_cache(pg)
        broadcast(:drift_critical, %{decision: deactivated, score: score})
        broadcast(:decision_deactivated, deactivated)

        # Notify ALL traders (including the owner)
        traders = TradingDesk.Traders.list_active()
        Enum.each(traders, fn trader ->
          drift_pct = round(score * 100)
          TraderNotification.notify_one(
            trader.id, deactivated, "drift_critical",
            nil, "System",
            "Decision ##{deactivated.id} auto-deactivated: reality drifted #{drift_pct}% from baseline (#{deactivated.trader_name}: #{deactivated.reason || ""})",
            %{drift_score: score, variable_keys: Map.keys(deactivated.variable_changes)}
          )
        end)

        Logger.warning("[DecisionLedger] Decision ##{decision.id} auto-deactivated: drift #{Float.round(score, 2)}")

      _ -> :ok
    end
  end

  defp handle_warning_drift(decision, score) do
    broadcast(:drift_warning, %{decision: decision, score: score})

    # Notify all traders about the drift
    traders = TradingDesk.Traders.list_active()
    Enum.each(traders, fn trader ->
      drift_pct = round(score * 100)
      TraderNotification.notify_one(
        trader.id, decision, "drift_warning",
        nil, "System",
        "Decision ##{decision.id} drifting: reality has moved #{drift_pct}% toward the override (#{decision.trader_name}: #{decision.reason || ""})",
        %{drift_score: score, variable_keys: Map.keys(decision.variable_changes)}
      )
    end)
  end

  # ── Internal: ETS cache ────────────────────────────────────────────────

  defp load_applied_from_db do
    Enum.each(@all_product_groups, fn pg ->
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

    @all_product_groups
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

  # ── Internal: helpers ──────────────────────────────────────────────────

  defp trader_name_for_id(trader_id) do
    case TradingDesk.Traders.get(trader_id) do
      nil -> "Trader ##{trader_id}"
      trader -> trader.name
    end
  rescue
    _ -> "Trader ##{trader_id}"
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(
      TradingDesk.PubSub,
      "decisions",
      {event, payload}
    )
  end
end
