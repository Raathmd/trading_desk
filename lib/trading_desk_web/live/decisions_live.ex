defmodule TradingDesk.DecisionsLive do
  @moduledoc """
  Decision Ledger LiveView — shows all trader decisions across the desk.

  Traders can:
    - See all draft, proposed, applied, deactivated, rejected, revoked decisions
    - Apply a proposed decision to the shared effective state
    - Reject a proposed decision
    - Deactivate/reactivate applied decisions with a toggle
    - Respond to deactivation requests from other traders
    - See drift indicators showing how far reality has moved
    - Receive live notifications for all decision lifecycle events
  """
  use Phoenix.LiveView
  require Logger

  alias TradingDesk.Decisions.DecisionLedger
  alias TradingDesk.Decisions.TraderDecision
  alias TradingDesk.Decisions.TraderNotification
  alias TradingDesk.Data.LiveState
  alias TradingDesk.Variables

  @impl true
  def mount(_params, session, socket) do
    current_user_email = Map.get(session, "authenticated_email")

    # Load traders for reviewer identification
    available_traders = TradingDesk.Traders.list_active()
    selected_trader = List.first(available_traders)
    trader_id = if selected_trader, do: selected_trader.id, else: nil
    trader_name = if selected_trader, do: selected_trader.name, else: "Unknown"

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "decisions")
      if trader_id do
        Phoenix.PubSub.subscribe(TradingDesk.PubSub, "notifications:#{trader_id}")
      end
    end

    product_group = :ammonia_domestic

    socket =
      socket
      |> assign(:current_user_email, current_user_email)
      |> assign(:trader_id, trader_id)
      |> assign(:trader_name, trader_name)
      |> assign(:available_traders, available_traders)
      |> assign(:product_group, product_group)
      |> assign(:status_filter, :all)
      |> assign(:decisions, [])
      |> assign(:effective_state, %{})
      |> assign(:live_base, %{})
      |> assign(:variable_meta, build_variable_meta())
      |> assign(:review_note, "")
      |> assign(:flash_msg, nil)
      # Notifications
      |> assign(:notifications, [])
      |> assign(:unread_count, 0)
      |> assign(:show_notifications, false)
      |> refresh_decisions()
      |> refresh_effective_state()
      |> refresh_notifications()

    {:ok, socket}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("switch_product_group", %{"group" => pg}, socket) do
    pg_atom = String.to_existing_atom(pg)

    socket =
      socket
      |> assign(:product_group, pg_atom)
      |> refresh_decisions()
      |> refresh_effective_state()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    filter = if status == "all", do: :all, else: String.to_existing_atom(status)

    socket =
      socket
      |> assign(:status_filter, filter)
      |> refresh_decisions()

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_trader", %{"trader" => tid}, socket) do
    trader = Enum.find(socket.assigns.available_traders, &(to_string(&1.id) == tid))

    # Unsubscribe from old trader's notifications, subscribe to new
    old_id = socket.assigns.trader_id
    new_id = if trader, do: trader.id, else: nil

    if connected?(socket) do
      if old_id, do: Phoenix.PubSub.unsubscribe(TradingDesk.PubSub, "notifications:#{old_id}")
      if new_id, do: Phoenix.PubSub.subscribe(TradingDesk.PubSub, "notifications:#{new_id}")
    end

    socket =
      socket
      |> assign(:trader_id, new_id)
      |> assign(:trader_name, if(trader, do: trader.name, else: "Unknown"))
      |> refresh_notifications()

    {:noreply, socket}
  end

  @impl true
  def handle_event("apply_decision", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    reviewer_id = socket.assigns.trader_id

    case DecisionLedger.apply_decision(id, reviewer_id) do
      {:ok, _applied} ->
        {:noreply, socket |> assign(:flash_msg, "Decision ##{id} applied") |> refresh_decisions() |> refresh_effective_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_decision", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    reviewer_id = socket.assigns.trader_id

    case DecisionLedger.reject_decision(id, reviewer_id) do
      {:ok, _rejected} ->
        {:noreply, socket |> assign(:flash_msg, "Decision ##{id} rejected") |> refresh_decisions() |> refresh_effective_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("revoke_decision", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case DecisionLedger.revoke_decision(id) do
      {:ok, _revoked} ->
        {:noreply, socket |> assign(:flash_msg, "Decision ##{id} revoked") |> refresh_decisions() |> refresh_effective_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("deactivate_decision", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case DecisionLedger.deactivate_decision(id, socket.assigns.trader_id, socket.assigns.trader_name) do
      {:ok, :request_sent} ->
        {:noreply, assign(socket, :flash_msg, "Deactivation request sent to the decision owner")}

      {:ok, _deactivated} ->
        {:noreply, socket |> assign(:flash_msg, "Decision ##{id} deactivated") |> refresh_decisions() |> refresh_effective_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reactivate_decision", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)

    case DecisionLedger.reactivate_decision(id, socket.assigns.trader_id) do
      {:ok, _reactivated} ->
        {:noreply, socket |> assign(:flash_msg, "Decision ##{id} reactivated") |> refresh_decisions() |> refresh_effective_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  # ── Notification events ─────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_notifications", _params, socket) do
    {:noreply, assign(socket, :show_notifications, !socket.assigns.show_notifications)}
  end

  @impl true
  def handle_event("mark_all_read", _params, socket) do
    if socket.assigns.trader_id do
      TraderNotification.mark_all_read(socket.assigns.trader_id)
    end
    {:noreply, refresh_notifications(socket)}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    case TraderNotification.get(id) do
      nil -> :ok
      notif -> TraderNotification.mark_read(notif)
    end
    {:noreply, refresh_notifications(socket)}
  end

  @impl true
  def handle_event("accept_deactivation", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    case DecisionLedger.respond_to_deactivation(id, "accepted", socket.assigns.trader_name) do
      {:ok, _} ->
        {:noreply, socket |> assign(:flash_msg, "Deactivation accepted") |> refresh_decisions() |> refresh_effective_state() |> refresh_notifications()}
      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reject_deactivation", %{"id" => id_str}, socket) do
    id = String.to_integer(id_str)
    case DecisionLedger.respond_to_deactivation(id, "rejected", socket.assigns.trader_name) do
      {:ok, _} ->
        {:noreply, socket |> assign(:flash_msg, "Deactivation rejected") |> refresh_notifications()}
      {:error, reason} ->
        {:noreply, assign(socket, :flash_msg, "Failed: #{inspect(reason)}")}
    end
  end

  # ── PubSub handlers ────────────────────────────────────────────────────

  @impl true
  def handle_info({:decision_proposed, _decision}, socket) do
    {:noreply, refresh_decisions(socket)}
  end

  @impl true
  def handle_info({:decision_applied, _decision}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state()}
  end

  @impl true
  def handle_info({:decision_rejected, _decision}, socket) do
    {:noreply, refresh_decisions(socket)}
  end

  @impl true
  def handle_info({:decision_revoked, _decision}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state()}
  end

  @impl true
  def handle_info({:decision_deactivated, _decision}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state()}
  end

  @impl true
  def handle_info({:decision_reactivated, _decision}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state()}
  end

  @impl true
  def handle_info({:decision_superseded, _payload}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state()}
  end

  @impl true
  def handle_info({:effective_state_changed, _}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state()}
  end

  @impl true
  def handle_info({:drift_warning, _payload}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_notifications()}
  end

  @impl true
  def handle_info({:drift_critical, _payload}, socket) do
    {:noreply, socket |> refresh_decisions() |> refresh_effective_state() |> refresh_notifications()}
  end

  @impl true
  def handle_info({:new_notification, _notif}, socket) do
    {:noreply, refresh_notifications(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp refresh_decisions(socket) do
    pg = socket.assigns.product_group
    filter = socket.assigns.status_filter
    opts = if filter == :all, do: [], else: [status: filter]
    decisions = DecisionLedger.list(pg, opts)
    assign(socket, :decisions, decisions)
  end

  defp refresh_effective_state(socket) do
    pg = socket.assigns.product_group
    effective = DecisionLedger.effective_state(pg)
    base = LiveState.get()
    base_map = if is_struct(base), do: Map.from_struct(base), else: base
    assign(socket, effective_state: effective, live_base: base_map)
  end

  defp refresh_notifications(socket) do
    tid = socket.assigns.trader_id
    if tid do
      notifications = TraderNotification.list_recent(tid)
      unread = TraderNotification.unread_count(tid)
      assign(socket, notifications: notifications, unread_count: unread)
    else
      assign(socket, notifications: [], unread_count: 0)
    end
  end

  defp build_variable_meta do
    Variables.metadata()
    |> Enum.map(fn m -> {to_string(m.key), m} end)
    |> Map.new()
  end

  defp var_label(key_str, meta) do
    case Map.get(meta, key_str) do
      nil -> key_str
      m -> m.label
    end
  end

  defp var_unit(key_str, meta) do
    case Map.get(meta, key_str) do
      nil -> ""
      m -> m.unit
    end
  end

  defp status_color("draft"), do: "#475569"
  defp status_color("proposed"), do: "#f59e0b"
  defp status_color("applied"), do: "#10b981"
  defp status_color("deactivated"), do: "#f97316"
  defp status_color("rejected"), do: "#f87171"
  defp status_color("revoked"), do: "#94a3b8"
  defp status_color("superseded"), do: "#7c3aed"
  defp status_color(_), do: "#475569"

  defp status_bg("draft"), do: "#0d1117"
  defp status_bg("proposed"), do: "#1c1a0f"
  defp status_bg("applied"), do: "#0a1f17"
  defp status_bg("deactivated"), do: "#1a120a"
  defp status_bg("rejected"), do: "#1f0a0a"
  defp status_bg("revoked"), do: "#111827"
  defp status_bg("superseded"), do: "#1a0f2e"
  defp status_bg(_), do: "#111827"

  defp notif_color("decision_proposed"), do: "#f59e0b"
  defp notif_color("decision_applied"), do: "#10b981"
  defp notif_color("decision_rejected"), do: "#f87171"
  defp notif_color("decision_deactivated"), do: "#f97316"
  defp notif_color("decision_reactivated"), do: "#10b981"
  defp notif_color("deactivate_requested"), do: "#ef4444"
  defp notif_color("drift_warning"), do: "#f59e0b"
  defp notif_color("drift_critical"), do: "#ef4444"
  defp notif_color(_), do: "#94a3b8"

  defp notif_icon("decision_proposed"), do: "NEW"
  defp notif_icon("decision_applied"), do: "ON"
  defp notif_icon("decision_rejected"), do: "REJ"
  defp notif_icon("decision_deactivated"), do: "OFF"
  defp notif_icon("decision_reactivated"), do: "ON"
  defp notif_icon("deactivate_requested"), do: "REQ"
  defp notif_icon("drift_warning"), do: "DRIFT"
  defp notif_icon("drift_critical"), do: "DRIFT"
  defp notif_icon(_), do: "?"

  defp drift_color(score) when is_number(score) and score >= 1.0, do: "#ef4444"
  defp drift_color(score) when is_number(score) and score >= 0.5, do: "#f59e0b"
  defp drift_color(_), do: "#475569"

  defp format_time(nil), do: "—"
  defp format_time(dt) do
    Calendar.strftime(dt, "%b %d %H:%M")
  end

  defp format_val(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp format_val(v) when is_integer(v), do: Integer.to_string(v)
  defp format_val(true), do: "YES"
  defp format_val(false), do: "NO"
  defp format_val(v), do: to_string(v)

  defp mode_label("relative"), do: "REL"
  defp mode_label(_), do: "ABS"

  defp mode_color("relative"), do: "#38bdf8"
  defp mode_color(_), do: "#a78bfa"

  # Find proposed decisions that conflict (touch same vars) with a given decision
  defp has_conflicts?(decision, all_decisions) do
    if decision.status != "proposed" do
      false
    else
      changed_keys = Map.keys(decision.variable_changes)

      Enum.any?(all_decisions, fn other ->
        other.id != decision.id
        and other.status in ["proposed", "applied"]
        and Enum.any?(Map.keys(other.variable_changes), &(&1 in changed_keys))
      end)
    end
  end

  defp conflicting_decisions(decision, all_decisions) do
    changed_keys = Map.keys(decision.variable_changes)

    Enum.filter(all_decisions, fn other ->
      other.id != decision.id
      and other.status in ["proposed", "applied"]
      and Enum.any?(Map.keys(other.variable_changes), &(&1 in changed_keys))
    end)
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace">
      <%!-- === TOP BAR === --%>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:10px 20px;display:flex;justify-content:space-between;align-items:center">
        <div style="display:flex;align-items:center;gap:12px">
          <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px">DECISION LEDGER</span>
          <select phx-change="switch_trader" name="trader"
            style="background:#111827;border:1px solid #2563eb;color:#60a5fa;padding:3px 8px;border-radius:4px;font-size:12px;font-weight:600;cursor:pointer">
            <%= for t <- @available_traders do %>
              <option value={t.id} selected={t.id == @trader_id}><%= t.name %></option>
            <% end %>
          </select>
          <select phx-change="switch_product_group" name="group"
            style="background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:3px 8px;border-radius:4px;font-size:12px;font-weight:600;cursor:pointer">
            <option value="ammonia_domestic" selected={@product_group == :ammonia_domestic}>Ammonia Domestic</option>
            <option value="ammonia_international" selected={@product_group == :ammonia_international}>Ammonia International</option>
            <option value="sulphur_international" selected={@product_group == :sulphur_international}>Sulphur International</option>
            <option value="petcoke" selected={@product_group == :petcoke}>Petcoke</option>
          </select>
          <a href="/home" style="color:#94a3b8;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px">HOME</a>
          <a href="/desk" style="color:#a78bfa;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px">TRADING DESK</a>
          <a href="/contracts" style="color:#38bdf8;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px">CONTRACTS</a>
          <a href="/process_flows.html" target="_blank" style="color:#2dd4bf;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px" title="Process Flows &amp; Data Sources">PROCESS FLOWS</a>
        </div>
        <div style="display:flex;align-items:center;gap:12px;font-size:11px">
          <%!-- Notification bell --%>
          <div style="position:relative">
            <button phx-click="toggle_notifications"
              style={"background:#{if @unread_count > 0, do: "#1c1a0f", else: "none"};border:1px solid #{if @unread_count > 0, do: "#f59e0b44", else: "#1e293b"};color:#{if @unread_count > 0, do: "#f59e0b", else: "#7b8fa4"};padding:4px 10px;border-radius:4px;cursor:pointer;font-size:12px;font-weight:600"}>
              ALERTS
              <%= if @unread_count > 0 do %>
                <span style="background:#ef4444;color:#fff;padding:1px 5px;border-radius:8px;font-size:9px;font-weight:700;margin-left:4px"><%= @unread_count %></span>
              <% end %>
            </button>
          </div>
          <%= if @current_user_email do %>
            <span style="color:#475569;font-size:10px"><%= @current_user_email %></span>
            <a href="/logout" style="background:none;border:1px solid #2d3748;color:#7b8fa4;padding:3px 9px;border-radius:4px;font-size:11px;cursor:pointer;font-weight:600;text-decoration:none">LOGOUT</a>
          <% end %>
        </div>
      </div>

      <div style="display:grid;grid-template-columns:280px 1fr;height:calc(100vh - 45px)">
        <%!-- === LEFT: EFFECTIVE STATE PANEL === --%>
        <div style="background:#0a0f18;border-right:1px solid #1b2838;overflow-y:auto;padding:14px">
          <div style="font-size:11px;font-weight:700;color:#60a5fa;letter-spacing:1.2px;margin-bottom:12px;text-transform:uppercase">
            EFFECTIVE STATE
          </div>
          <div style="font-size:9px;color:#475569;margin-bottom:12px">
            Base (API) + Applied Decisions = What traders see
          </div>

          <%= for {key_str, meta_item} <- Enum.sort_by(@variable_meta, fn {_, m} -> {m.group, m.label} end) do %>
            <% key_atom = String.to_existing_atom(key_str) %>
            <% base_val = Map.get(@live_base, key_atom) %>
            <% eff_val = Map.get(@effective_state, key_atom) %>
            <% changed = base_val != eff_val %>
            <div style={"display:grid;grid-template-columns:110px 1fr 1fr;gap:4px;padding:3px 6px;margin-bottom:1px;border-radius:3px;border-left:2px solid #{if changed, do: "#f59e0b", else: "transparent"};background:#{if changed, do: "#111827", else: "transparent"}"}>
              <span style="font-size:10px;color:#7b8fa4;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= meta_item.label %></span>
              <span style="font-size:10px;color:#475569;font-family:monospace;text-align:right" title="API base"><%= format_val(base_val) %></span>
              <span style={"font-size:10px;font-family:monospace;text-align:right;font-weight:#{if changed, do: "700", else: "400"};color:#{if changed, do: "#f59e0b", else: "#94a3b8"}"} title="Effective"><%= format_val(eff_val) %></span>
            </div>
          <% end %>
        </div>

        <%!-- === RIGHT: DECISION LIST === --%>
        <div style="overflow-y:auto;padding:20px">
          <%!-- Status filter tabs --%>
          <div style="display:flex;gap:8px;margin-bottom:16px;flex-wrap:wrap">
            <%= for {label, val} <- [{"ALL", "all"}, {"DRAFT", "draft"}, {"PROPOSED", "proposed"}, {"APPLIED", "applied"}, {"DEACTIVATED", "deactivated"}, {"REJECTED", "rejected"}, {"REVOKED", "revoked"}, {"SUPERSEDED", "superseded"}] do %>
              <button phx-click="filter_status" phx-value-status={val}
                style={"padding:5px 12px;border:1px solid #{if to_string(@status_filter) == val, do: "#2563eb", else: "#1e293b"};border-radius:4px;background:#{if to_string(@status_filter) == val, do: "#111827", else: "transparent"};color:#{if to_string(@status_filter) == val, do: "#60a5fa", else: "#7b8fa4"};font-size:11px;font-weight:600;cursor:pointer;letter-spacing:0.5px"}>
                <%= label %>
              </button>
            <% end %>
          </div>

          <%!-- Flash message --%>
          <%= if @flash_msg do %>
            <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:8px 14px;margin-bottom:12px;font-size:11px;color:#60a5fa">
              <%= @flash_msg %>
            </div>
          <% end %>

          <%!-- Decisions list --%>
          <%= if @decisions == [] do %>
            <div style="text-align:center;padding:60px 20px;color:#475569">
              <div style="font-size:24px;margin-bottom:8px">No decisions</div>
              <div style="font-size:12px">Commit a decision from the Trading Desk to see it here.</div>
            </div>
          <% else %>
            <%= for decision <- @decisions do %>
              <% conflicts = has_conflicts?(decision, @decisions) %>
              <% drift = decision.drift_score || 0.0 %>
              <% drifting = drift >= 0.5 and decision.status in ["applied", "deactivated"] %>
              <div style={"background:#{status_bg(decision.status)};border:1px solid #{cond do conflicts -> "#f59e0b"; drifting -> drift_color(drift); true -> "#1e293b" end};border-radius:8px;padding:16px;margin-bottom:12px;#{if conflicts, do: "box-shadow:0 0 12px rgba(245,158,11,0.15);", else: ""}#{if drifting, do: "box-shadow:0 0 12px #{drift_color(drift)}22;", else: ""}"}>
                <%!-- Header row --%>
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
                  <div style="display:flex;align-items:center;gap:10px">
                    <span style={"background:#{status_color(decision.status)}22;color:#{status_color(decision.status)};padding:2px 8px;border-radius:3px;font-size:10px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase"}><%= decision.status %></span>
                    <span style="font-size:13px;font-weight:600;color:#e2e8f0"><%= decision.trader_name %></span>
                    <span style="font-size:10px;color:#475569">#<%= decision.id %></span>
                    <%= if conflicts do %>
                      <span style="background:#f59e0b22;color:#f59e0b;padding:2px 6px;border-radius:3px;font-size:9px;font-weight:700;letter-spacing:0.5px">CONFLICT</span>
                    <% end %>
                    <%!-- Drift badge --%>
                    <%= if drifting do %>
                      <span style={"background:#{drift_color(drift)}22;color:#{drift_color(drift)};padding:2px 6px;border-radius:3px;font-size:9px;font-weight:700;letter-spacing:0.5px"}>
                        DRIFT <%= round(drift * 100) %>%
                      </span>
                    <% end %>
                  </div>
                  <div style="display:flex;align-items:center;gap:8px">
                    <%!-- Active/Deactivate toggle for applied or deactivated decisions --%>
                    <%= if decision.status == "applied" do %>
                      <button phx-click="deactivate_decision" phx-value-id={decision.id}
                        style="background:#0a1f17;border:1px solid #10b98155;border-radius:12px;padding:3px 10px;cursor:pointer;display:flex;align-items:center;gap:6px"
                        title="Deactivate — temporarily remove from effective state">
                        <div style="width:8px;height:8px;border-radius:50%;background:#10b981"></div>
                        <span style="font-size:9px;color:#10b981;font-weight:700;letter-spacing:0.5px">ACTIVE</span>
                      </button>
                    <% end %>
                    <%= if decision.status == "deactivated" do %>
                      <button phx-click="reactivate_decision" phx-value-id={decision.id}
                        style="background:#1a120a;border:1px solid #f9731655;border-radius:12px;padding:3px 10px;cursor:pointer;display:flex;align-items:center;gap:6px"
                        title="Reactivate — put back into effective state">
                        <div style="width:8px;height:8px;border-radius:50%;background:#f97316;opacity:0.5"></div>
                        <span style="font-size:9px;color:#f97316;font-weight:700;letter-spacing:0.5px">INACTIVE</span>
                      </button>
                    <% end %>
                    <span style="font-size:10px;color:#475569"><%= format_time(decision.inserted_at) %></span>
                  </div>
                </div>

                <%!-- Reason --%>
                <%= if decision.reason do %>
                  <div style="font-size:12px;color:#94a3b8;margin-bottom:10px;padding:6px 10px;background:#0d111766;border-radius:4px;border-left:2px solid #2563eb">
                    <%= decision.reason %>
                  </div>
                <% end %>

                <%!-- Variable changes --%>
                <div style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px">
                  <%= for {key_str, value} <- decision.variable_changes do %>
                    <% mode = Map.get(decision.change_modes || %{}, key_str, "absolute") %>
                    <% baseline_val = Map.get(decision.baseline_snapshot || %{}, key_str) %>
                    <div style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:4px 8px;display:flex;align-items:center;gap:6px">
                      <span style="font-size:10px;color:#7b8fa4"><%= var_label(key_str, @variable_meta) %></span>
                      <span style={"font-size:9px;color:#{mode_color(mode)};font-weight:600;padding:1px 4px;border:1px solid #{mode_color(mode)}44;border-radius:2px"}><%= mode_label(mode) %></span>
                      <span style="font-size:11px;color:#e2e8f0;font-weight:700;font-family:monospace">
                        <%= if mode == "relative" do %><%= if value >= 0, do: "+", else: "" %><% end %><%= format_val(value) %>
                      </span>
                      <span style="font-size:9px;color:#475569"><%= var_unit(key_str, @variable_meta) %></span>
                      <%!-- Baseline indicator --%>
                      <%= if baseline_val != nil do %>
                        <span style="font-size:9px;color:#475569;border-left:1px solid #1e293b;padding-left:6px" title="Baseline when applied">was <%= format_val(baseline_val) %></span>
                      <% end %>
                    </div>
                  <% end %>
                </div>

                <%!-- Drift details (for applied/deactivated with baseline) --%>
                <%= if drifting and map_size(decision.baseline_snapshot || %{}) > 0 do %>
                  <div style={"background:#{drift_color(drift)}11;border:1px solid #{drift_color(drift)}33;border-radius:4px;padding:8px 10px;margin-bottom:10px;font-size:10px;color:#{drift_color(drift)}"}>
                    <strong>Reality has drifted <%= round(drift * 100) %>% from when this decision was applied.</strong>
                    <%= if drift >= 1.0 do %>
                      Live data has moved past the override — this decision may no longer reflect reality.
                    <% else %>
                      Live data is moving toward the override value.
                    <% end %>
                    <%= if decision.drift_revoked_at do %>
                      <div style="margin-top:4px;font-weight:600">Auto-deactivated at <%= format_time(decision.drift_revoked_at) %></div>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Conflict details --%>
                <%= if conflicts do %>
                  <div style="background:#1c1a0f;border:1px solid #f59e0b33;border-radius:4px;padding:8px 10px;margin-bottom:10px;font-size:10px;color:#f59e0b">
                    Conflicts with:
                    <%= for c <- conflicting_decisions(decision, @decisions) do %>
                      <span style="font-weight:600"> #<%= c.id %> (<%= c.trader_name %>)</span>
                    <% end %>
                    — coordinate with other traders before applying.
                  </div>
                <% end %>

                <%!-- Review info --%>
                <%= if decision.reviewed_by do %>
                  <div style="font-size:10px;color:#475569;margin-bottom:8px">
                    Reviewed at <%= format_time(decision.reviewed_at) %>
                    <%= if decision.review_note do %>
                      — "<%= decision.review_note %>"
                    <% end %>
                  </div>
                <% end %>

                <%!-- Deactivation info --%>
                <%= if decision.deactivated_at do %>
                  <div style="font-size:10px;color:#f97316;margin-bottom:8px">
                    Deactivated at <%= format_time(decision.deactivated_at) %>
                    <%= if decision.drift_revoked_at do %>
                      (auto — drift exceeded threshold)
                    <% end %>
                  </div>
                <% end %>

                <%!-- Expiry --%>
                <%= if decision.expires_at do %>
                  <div style="font-size:10px;color:#7c3aed;margin-bottom:8px">
                    Expires: <%= format_time(decision.expires_at) %>
                  </div>
                <% end %>

                <%!-- Supersedes --%>
                <%= if decision.supersedes_id do %>
                  <div style="font-size:10px;color:#7c3aed;margin-bottom:8px">
                    Supersedes decision #<%= decision.supersedes_id %>
                  </div>
                <% end %>

                <%!-- Action buttons --%>
                <div style="display:flex;gap:8px;margin-top:8px">
                  <%= if decision.status == "proposed" do %>
                    <button phx-click="apply_decision" phx-value-id={decision.id}
                      style="padding:6px 14px;border:1px solid #10b98155;border-radius:4px;background:#0a1f17;color:#10b981;font-size:11px;font-weight:700;cursor:pointer;letter-spacing:0.5px">
                      APPLY TO STATE
                    </button>
                    <button phx-click="reject_decision" phx-value-id={decision.id}
                      style="padding:6px 14px;border:1px solid #f8717155;border-radius:4px;background:#1f0a0a;color:#f87171;font-size:11px;font-weight:700;cursor:pointer;letter-spacing:0.5px">
                      REJECT
                    </button>
                  <% end %>
                  <%= if decision.status in ["draft", "proposed", "applied", "deactivated"] and decision.trader_id == @trader_id do %>
                    <button phx-click="revoke_decision" phx-value-id={decision.id}
                      style="padding:6px 14px;border:1px solid #94a3b855;border-radius:4px;background:#111827;color:#94a3b8;font-size:11px;font-weight:600;cursor:pointer;letter-spacing:0.5px">
                      REVOKE
                    </button>
                  <% end %>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- === NOTIFICATIONS PANEL (slide-out) === --%>
      <%= if @show_notifications do %>
        <div style="position:fixed;top:0;right:0;width:400px;height:100vh;background:#0d1117;border-left:1px solid #1e293b;z-index:1000;overflow-y:auto;box-shadow:-4px 0 20px rgba(0,0,0,0.5)">
          <div style="padding:16px;border-bottom:1px solid #1e293b;display:flex;justify-content:space-between;align-items:center">
            <span style="font-size:13px;font-weight:700;color:#e2e8f0;letter-spacing:1px">NOTIFICATIONS</span>
            <div style="display:flex;gap:8px;align-items:center">
              <%= if @unread_count > 0 do %>
                <button phx-click="mark_all_read"
                  style="background:none;border:1px solid #1e293b;color:#60a5fa;padding:3px 8px;border-radius:3px;cursor:pointer;font-size:10px;font-weight:600">
                  MARK ALL READ
                </button>
              <% end %>
              <button phx-click="toggle_notifications" style="background:none;border:none;color:#94a3b8;cursor:pointer;font-size:16px">X</button>
            </div>
          </div>

          <%= if @notifications == [] do %>
            <div style="padding:40px 20px;text-align:center;color:#475569;font-size:12px">
              No notifications yet.
            </div>
          <% else %>
            <%= for notif <- @notifications do %>
              <div style={"padding:12px 16px;border-bottom:1px solid #1e293b11;background:#{if notif.read, do: "transparent", else: "#111827"}"}>
                <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">
                  <span style={"background:#{notif_color(notif.type)}22;color:#{notif_color(notif.type)};padding:1px 6px;border-radius:2px;font-size:9px;font-weight:700;letter-spacing:0.5px"}><%= notif_icon(notif.type) %></span>
                  <span style="font-size:10px;color:#475569"><%= format_time(notif.inserted_at) %></span>
                  <%= if not notif.read do %>
                    <div style="width:6px;height:6px;border-radius:50%;background:#3b82f6"></div>
                  <% end %>
                </div>
                <div style="font-size:12px;color:#c8d6e5;margin-bottom:6px"><%= notif.message %></div>

                <%!-- Action buttons for deactivation requests --%>
                <%= if notif.type == "deactivate_requested" and is_nil(notif.response) do %>
                  <div style="display:flex;gap:8px;margin-top:8px">
                    <button phx-click="accept_deactivation" phx-value-id={notif.id}
                      style="padding:5px 12px;border:1px solid #10b98155;border-radius:4px;background:#0a1f17;color:#10b981;font-size:10px;font-weight:700;cursor:pointer">
                      ACCEPT
                    </button>
                    <button phx-click="reject_deactivation" phx-value-id={notif.id}
                      style="padding:5px 12px;border:1px solid #f8717155;border-radius:4px;background:#1f0a0a;color:#f87171;font-size:10px;font-weight:700;cursor:pointer">
                      REJECT
                    </button>
                  </div>
                <% end %>

                <%!-- Show response if already responded --%>
                <%= if notif.type == "deactivate_requested" and notif.response do %>
                  <div style={"font-size:10px;margin-top:4px;color:#{if notif.response == "accepted", do: "#10b981", else: "#f87171"}"}>
                    You <%= notif.response %> this request
                  </div>
                <% end %>

                <%!-- Mark as read button --%>
                <%= if not notif.read and notif.type != "deactivate_requested" do %>
                  <button phx-click="mark_read" phx-value-id={notif.id}
                    style="background:none;border:none;color:#475569;cursor:pointer;font-size:9px;padding:0;margin-top:4px">
                    dismiss
                  </button>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
