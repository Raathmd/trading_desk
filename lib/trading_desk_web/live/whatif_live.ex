defmodule TradingDesk.WhatifLive do
  @moduledoc """
  Simplified What-If Analysis workflow for traders.

  A guided 5-step wizard:
    1. VARIABLES — current state of all variables by group
    2. CONTRACTS — contracts table for the selected product group
    3. SOLVE     — what-if prompt input + "Frame" button to send to LLM
    4. FRAMED    — LLM framing responses (one per model)
    5. RESULTS   — solver output per model + LLM explanations

  Each page has a back button to navigate to the previous step.
  """
  use Phoenix.LiveView
  require Logger

  alias TradingDesk.ProductGroup
  alias TradingDesk.Data.LiveState
  alias TradingDesk.Decisions.DecisionLedger
  alias TradingDesk.Traders
  alias TradingDesk.LLM.{PresolvePipeline, ModelRegistry}

  @steps [:variables, :contracts, :solve, :framed, :results]

  # ── Mount ────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    current_user_email = Map.get(session, "authenticated_email")

    available_traders = Traders.list_active()
    selected_trader = List.first(available_traders)
    trader_id = if selected_trader, do: to_string(selected_trader.id), else: "trader_1"

    product_group = if selected_trader,
      do: Traders.primary_product_group(selected_trader),
      else: :ammonia_domestic

    current_vars = safe_call(fn -> DecisionLedger.effective_state(product_group) end,
      safe_call(fn -> LiveState.get() end, ProductGroup.default_values(product_group)))

    current_vars = if is_map(current_vars), do: current_vars, else: ProductGroup.default_values(product_group)

    frame = ProductGroup.frame(product_group)
    metadata = ProductGroup.variable_metadata(product_group)
    variable_groups = TradingDesk.VariablesDynamic.groups(product_group)
    available_groups = ProductGroup.list_with_info()
    contracts_data = load_contracts(product_group)

    socket =
      socket
      |> assign(:current_user_email, current_user_email)
      |> assign(:available_traders, available_traders)
      |> assign(:selected_trader, selected_trader)
      |> assign(:trader_id, trader_id)
      |> assign(:product_group, product_group)
      |> assign(:frame, frame)
      |> assign(:current_vars, current_vars)
      |> assign(:metadata, metadata)
      |> assign(:variable_groups, variable_groups)
      |> assign(:available_groups, available_groups)
      |> assign(:contracts_data, contracts_data)
      # Wizard state
      |> assign(:step, :variables)
      |> assign(:whatif_prompt, "")
      |> assign(:objective_mode, :max_profit)
      # Framing / solve state
      |> assign(:framing, false)
      |> assign(:framing_results, [])
      |> assign(:model_progress, %{})
      # Results state
      |> assign(:solving, false)
      |> assign(:solve_results, [])

    {:ok, socket}
  end

  # ── Navigation events ─────────────────────────────────────

  @impl true
  def handle_event("nav", %{"step" => step_str}, socket) do
    step = String.to_existing_atom(step_str)
    {:noreply, assign(socket, :step, step)}
  end

  @impl true
  def handle_event("back", _params, socket) do
    current = socket.assigns.step
    idx = Enum.find_index(@steps, &(&1 == current))
    prev = if idx && idx > 0, do: Enum.at(@steps, idx - 1), else: current
    {:noreply, assign(socket, :step, prev)}
  end

  # ── Product group / trader switching ───────────────────────

  @impl true
  def handle_event("switch_product_group", %{"group" => pg}, socket) do
    pg_atom = String.to_existing_atom(pg)
    frame = ProductGroup.frame(pg_atom)
    metadata = ProductGroup.variable_metadata(pg_atom)
    variable_groups = TradingDesk.VariablesDynamic.groups(pg_atom)

    current_vars = safe_call(fn -> DecisionLedger.effective_state(pg_atom) end,
      ProductGroup.default_values(pg_atom))
    current_vars = if is_map(current_vars), do: current_vars, else: ProductGroup.default_values(pg_atom)
    contracts_data = load_contracts(pg_atom)

    socket =
      socket
      |> assign(:product_group, pg_atom)
      |> assign(:frame, frame)
      |> assign(:current_vars, current_vars)
      |> assign(:metadata, metadata)
      |> assign(:variable_groups, variable_groups)
      |> assign(:contracts_data, contracts_data)

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_trader", %{"trader" => tid}, socket) do
    trader = Enum.find(socket.assigns.available_traders, &(to_string(&1.id) == tid))
    {:noreply, assign(socket, :selected_trader, trader, trader_id: if(trader, do: to_string(trader.id), else: "trader_1"))}
  end

  # ── Solve page events ─────────────────────────────────────

  @impl true
  def handle_event("update_prompt", %{"prompt" => text}, socket) do
    {:noreply, assign(socket, :whatif_prompt, text)}
  end

  @impl true
  def handle_event("set_objective", %{"objective" => obj}, socket) do
    {:noreply, assign(socket, :objective_mode, String.to_existing_atom(obj))}
  end

  @impl true
  def handle_event("frame", _params, socket) do
    # Launch the presolve pipeline across all LLM models
    lv_pid = self()
    vars = socket.assigns.current_vars
    pg = socket.assigns.product_group
    notes = socket.assigns.whatif_prompt
    objective = socket.assigns.objective_mode

    model_ids = ModelRegistry.ids()
    initial_progress = Map.new(model_ids, fn id -> {id, :pending} end)

    socket =
      socket
      |> assign(:framing, true)
      |> assign(:framing_results, [])
      |> assign(:model_progress, initial_progress)
      |> assign(:solve_results, [])
      |> assign(:step, :framed)

    spawn(fn ->
      try do
        PresolvePipeline.run_all(vars,
          caller_pid: lv_pid,
          product_group: pg,
          trader_notes: notes,
          objective: objective,
          solver_opts: [objective: objective]
        )
      rescue
        e ->
          Logger.error("WhatifLive pipeline crashed: #{Exception.message(e)}")
          send(lv_pid, {:presolve_pipeline_done, []})
      catch
        kind, reason ->
          Logger.error("WhatifLive pipeline error: #{kind} #{inspect(reason)}")
          send(lv_pid, {:presolve_pipeline_done, []})
      end
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_event("go_to_results", _params, socket) do
    {:noreply, assign(socket, :step, :results)}
  end

  # ── Pipeline progress messages ─────────────────────────────

  @impl true
  def handle_info({:presolve_model_progress, model_id, phase}, socket) do
    progress = Map.put(socket.assigns.model_progress, model_id, phase)
    {:noreply, assign(socket, :model_progress, progress)}
  end

  @impl true
  def handle_info({:presolve_model_done, model_id, result_map}, socket) do
    progress = Map.put(socket.assigns.model_progress, model_id, :done)
    model = ModelRegistry.get(model_id)
    model_name = if model, do: model.name, else: to_string(model_id)
    results = socket.assigns.framing_results ++ [{model_id, model_name, result_map}]
    {:noreply, socket |> assign(:model_progress, progress) |> assign(:framing_results, results)}
  end

  @impl true
  def handle_info({:presolve_model_error, model_id, phase, reason}, socket) do
    progress = Map.put(socket.assigns.model_progress, model_id, {:error, phase, reason})
    {:noreply, assign(socket, :model_progress, progress)}
  end

  @impl true
  def handle_info({:presolve_pipeline_done, _all_results}, socket) do
    {:noreply, assign(socket, :framing, false)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # ── Render ────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace">
      <%!-- Top bar --%>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:10px 20px;display:flex;justify-content:space-between;align-items:center">
        <div style="display:flex;align-items:center;gap:12px">
          <a href="/home" style="color:#7b8fa4;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px">HOME</a>
          <span style="font-size:14px;font-weight:700;color:#10b981;letter-spacing:1px">WHAT-IF ANALYSIS</span>
          <select phx-change="switch_product_group" name="group"
            style="background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:3px 8px;border-radius:4px;font-size:12px;font-weight:600;cursor:pointer">
            <%= for g <- @available_groups do %>
              <option value={g.id} selected={g.id == @product_group}><%= g.name %></option>
            <% end %>
          </select>
        </div>
        <div style="display:flex;align-items:center;gap:12px;font-size:11px">
          <%= if @current_user_email do %>
            <span style="color:#475569;font-size:10px"><%= @current_user_email %></span>
            <a href="/logout" style="background:none;border:1px solid #2d3748;color:#7b8fa4;padding:3px 9px;border-radius:4px;font-size:11px;cursor:pointer;font-weight:600;text-decoration:none">LOGOUT</a>
          <% end %>
        </div>
      </div>

      <%!-- Step indicator --%>
      <div style="background:#0a0f18;border-bottom:1px solid #1b2838;padding:12px 20px;display:flex;gap:4px;align-items:center">
        <%= for {step, i} <- Enum.with_index([:variables, :contracts, :solve, :framed, :results]) do %>
          <% active = step == @step %>
          <% step_idx = Enum.find_index([:variables, :contracts, :solve, :framed, :results], &(&1 == @step)) %>
          <% completed = i < step_idx %>
          <% clickable = i <= step_idx %>
          <%= if i > 0 do %>
            <div style={"width:32px;height:1px;background:#{if completed, do: "#10b981", else: "#1e293b"}"}></div>
          <% end %>
          <button
            phx-click={if clickable, do: "nav"}
            phx-value-step={step}
            disabled={not clickable}
            style={"display:flex;align-items:center;gap:6px;padding:6px 14px;border-radius:6px;font-size:11px;font-weight:700;letter-spacing:0.5px;cursor:#{if clickable, do: "pointer", else: "default"};border:1px solid #{cond do active -> "#10b981"; completed -> "#10b98155"; true -> "#1e293b" end};background:#{if active, do: "#071a12", else: "transparent"};color:#{cond do active -> "#10b981"; completed -> "#34d399"; true -> "#475569" end}"}>
            <span style={"width:18px;height:18px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:700;background:#{cond do active -> "#10b981"; completed -> "#10b98144"; true -> "#1e293b" end};color:#{cond do active -> "#080c14"; completed -> "#10b981"; true -> "#475569" end}"}><%= i + 1 %></span>
            <%= step |> to_string() |> String.upcase() %>
          </button>
        <% end %>
      </div>

      <%!-- Step content --%>
      <div style="padding:20px;max-width:1200px;margin:0 auto">
        <%= case @step do %>
          <% :variables -> %>
            <%= render_variables(assigns) %>
          <% :contracts -> %>
            <%= render_contracts(assigns) %>
          <% :solve -> %>
            <%= render_solve(assigns) %>
          <% :framed -> %>
            <%= render_framed(assigns) %>
          <% :results -> %>
            <%= render_results(assigns) %>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Step 1: Variables ──────────────────────────────────────

  defp render_variables(assigns) do
    ~H"""
    <div>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
        <div>
          <h2 style="font-size:18px;font-weight:700;color:#e2e8f0;margin:0">Current State</h2>
          <p style="font-size:12px;color:#7b8fa4;margin-top:4px">Live variable values for <span style="color:#10b981"><%= (@frame || %{})[:name] || "—" %></span></p>
        </div>
        <button phx-click="nav" phx-value-step="contracts"
          style="padding:8px 20px;border:1px solid #10b981;border-radius:6px;background:#071a12;color:#10b981;font-size:12px;font-weight:700;cursor:pointer;letter-spacing:0.5px">
          NEXT: CONTRACTS &rarr;
        </button>
      </div>

      <%= for {group, vars_in_group} <- group_variables(@metadata, @current_vars) do %>
        <div style="margin-bottom:20px">
          <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1.5px;margin-bottom:8px;text-transform:uppercase"><%= group %></div>
          <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:8px">
            <%= for {meta, val} <- vars_in_group do %>
              <div style="background:#0d1117;border:1px solid #1e293b;border-radius:6px;padding:10px 14px;display:flex;justify-content:space-between;align-items:center">
                <div>
                  <div style="font-size:11px;color:#94a3b8;font-weight:600"><%= meta.label %></div>
                  <div style="font-size:9px;color:#475569"><%= meta.unit %></div>
                </div>
                <div style="font-size:16px;font-weight:700;color:#e2e8f0;font-family:monospace"><%= format_val(val, meta) %></div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Step 2: Contracts ──────────────────────────────────────

  defp render_contracts(assigns) do
    ~H"""
    <div>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
        <div style="display:flex;align-items:center;gap:12px">
          <button phx-click="back"
            style="padding:8px 16px;border:1px solid #1e293b;border-radius:6px;background:transparent;color:#7b8fa4;font-size:12px;font-weight:700;cursor:pointer">&larr; BACK</button>
          <div>
            <h2 style="font-size:18px;font-weight:700;color:#e2e8f0;margin:0">Contracts</h2>
            <p style="font-size:12px;color:#7b8fa4;margin-top:4px">Active contracts for this product group</p>
          </div>
        </div>
        <button phx-click="nav" phx-value-step="solve"
          style="padding:8px 20px;border:1px solid #10b981;border-radius:6px;background:#071a12;color:#10b981;font-size:12px;font-weight:700;cursor:pointer;letter-spacing:0.5px">
          NEXT: SOLVE &rarr;
        </button>
      </div>

      <%= if @contracts_data == [] do %>
        <div style="text-align:center;padding:60px 20px;color:#475569">
          <div style="font-size:20px;margin-bottom:8px">No contracts loaded</div>
          <div style="font-size:12px">Contracts will appear here once ingested via the full Trading Desk.</div>
        </div>
      <% else %>
        <div style="background:#0d1117;border:1px solid #1e293b;border-radius:8px;overflow:hidden">
          <table style="width:100%;border-collapse:collapse;font-size:12px">
            <thead>
              <tr style="background:#111827;border-bottom:1px solid #1e293b">
                <th style="text-align:left;padding:10px 14px;color:#60a5fa;font-weight:700;font-size:10px;letter-spacing:0.5px">COUNTERPARTY</th>
                <th style="text-align:left;padding:10px 14px;color:#60a5fa;font-weight:700;font-size:10px;letter-spacing:0.5px">DIRECTION</th>
                <th style="text-align:left;padding:10px 14px;color:#60a5fa;font-weight:700;font-size:10px;letter-spacing:0.5px">STATUS</th>
                <th style="text-align:right;padding:10px 14px;color:#60a5fa;font-weight:700;font-size:10px;letter-spacing:0.5px">QTY (MT)</th>
                <th style="text-align:left;padding:10px 14px;color:#60a5fa;font-weight:700;font-size:10px;letter-spacing:0.5px">INCOTERM</th>
                <th style="text-align:left;padding:10px 14px;color:#60a5fa;font-weight:700;font-size:10px;letter-spacing:0.5px">PRODUCT</th>
              </tr>
            </thead>
            <tbody>
              <%= for c <- @contracts_data do %>
                <tr style="border-bottom:1px solid #1e293b11">
                  <td style="padding:10px 14px;color:#e2e8f0;font-weight:600"><%= c.counterparty %></td>
                  <td style="padding:10px 14px">
                    <span style={"color:#{if c.direction == :purchase, do: "#34d399", else: "#f59e0b"};font-weight:600"}>
                      <%= if c.direction == :purchase, do: "BUY", else: "SELL" %>
                    </span>
                  </td>
                  <td style="padding:10px 14px">
                    <span style={"background:#{status_bg_color(c.status)};color:#{status_fg_color(c.status)};padding:2px 8px;border-radius:3px;font-size:10px;font-weight:700"}><%= c.status |> to_string() |> String.upcase() %></span>
                  </td>
                  <td style="padding:10px 14px;text-align:right;font-family:monospace;color:#94a3b8"><%= format_number(c.quantity) %></td>
                  <td style="padding:10px 14px;color:#94a3b8"><%= c.incoterm %></td>
                  <td style="padding:10px 14px;color:#7b8fa4"><%= c.product %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Step 3: Solve ──────────────────────────────────────────

  defp render_solve(assigns) do
    ~H"""
    <div>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
        <div style="display:flex;align-items:center;gap:12px">
          <button phx-click="back"
            style="padding:8px 16px;border:1px solid #1e293b;border-radius:6px;background:transparent;color:#7b8fa4;font-size:12px;font-weight:700;cursor:pointer">&larr; BACK</button>
          <div>
            <h2 style="font-size:18px;font-weight:700;color:#e2e8f0;margin:0">What-If Solve</h2>
            <p style="font-size:12px;color:#7b8fa4;margin-top:4px">Describe your scenario and let the LLM frame the solver input</p>
          </div>
        </div>
      </div>

      <%!-- Objective selector --%>
      <div style="margin-bottom:20px">
        <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1.5px;margin-bottom:8px">OBJECTIVE</div>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <%= for {label, val} <- [{"MAX PROFIT", "max_profit"}, {"MIN COST", "min_cost"}, {"MAX ROI", "max_roi"}, {"CVaR ADJUSTED", "cvar_adjusted"}, {"MIN RISK", "min_risk"}] do %>
            <button phx-click="set_objective" phx-value-objective={val}
              style={"padding:6px 14px;border:1px solid #{if to_string(@objective_mode) == val, do: "#10b981", else: "#1e293b"};border-radius:4px;background:#{if to_string(@objective_mode) == val, do: "#071a12", else: "transparent"};color:#{if to_string(@objective_mode) == val, do: "#10b981", else: "#7b8fa4"};font-size:11px;font-weight:700;cursor:pointer;letter-spacing:0.5px"}>
              <%= label %>
            </button>
          <% end %>
        </div>
      </div>

      <%!-- What-if prompt --%>
      <div style="margin-bottom:20px">
        <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1.5px;margin-bottom:8px">WHAT-IF SCENARIO</div>
        <textarea phx-blur="update_prompt" name="prompt" rows="5"
          style="width:100%;background:#0d1117;border:1px solid #1e293b;border-radius:8px;color:#e2e8f0;padding:14px;font-size:13px;font-family:inherit;resize:vertical;line-height:1.6"
          placeholder="Describe your what-if scenario... e.g. 'What if a barge breaks down and we lose 2 barges, with river stage dropping to 12ft?'"><%= @whatif_prompt %></textarea>
        <div style="font-size:10px;color:#475569;margin-top:6px">
          Leave empty to use current variables as-is. The LLM will frame the solver input from the current product group state.
        </div>
      </div>

      <%!-- Current state summary --%>
      <div style="background:#0d1117;border:1px solid #1e293b;border-radius:8px;padding:16px;margin-bottom:20px">
        <div style="font-size:10px;font-weight:700;color:#475569;letter-spacing:1.5px;margin-bottom:10px">CURRENT STATE SUMMARY</div>
        <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:6px;font-size:11px">
          <%= for meta <- Enum.take(@metadata, 12) do %>
            <% val = Map.get(@current_vars, meta.key) %>
            <div style="display:flex;justify-content:space-between;padding:2px 0">
              <span style="color:#7b8fa4"><%= meta.label %></span>
              <span style="color:#94a3b8;font-family:monospace"><%= format_val(val, meta) %> <span style="color:#475569"><%= meta.unit %></span></span>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Frame button --%>
      <div style="text-align:center">
        <button phx-click="frame"
          style="padding:14px 40px;border:2px solid #10b981;border-radius:8px;background:#071a12;color:#10b981;font-size:14px;font-weight:700;cursor:pointer;letter-spacing:1px;transition:background 0.2s"
          onmouseover="this.style.background='#0d2b1e'" onmouseout="this.style.background='#071a12'">
          FRAME WITH LLM &rarr;
        </button>
        <div style="font-size:10px;color:#475569;margin-top:8px">
          Each registered LLM model will independently frame, solve, and explain the scenario
        </div>
      </div>
    </div>
    """
  end

  # ── Step 4: Framed ─────────────────────────────────────────

  defp render_framed(assigns) do
    ~H"""
    <div>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
        <div style="display:flex;align-items:center;gap:12px">
          <button phx-click="back"
            style="padding:8px 16px;border:1px solid #1e293b;border-radius:6px;background:transparent;color:#7b8fa4;font-size:12px;font-weight:700;cursor:pointer">&larr; BACK</button>
          <div>
            <h2 style="font-size:18px;font-weight:700;color:#e2e8f0;margin:0">LLM Framing</h2>
            <p style="font-size:12px;color:#7b8fa4;margin-top:4px">
              <%= if @framing do %>
                Models are framing, solving, and explaining your scenario...
              <% else %>
                All models have completed. Review the framed results below.
              <% end %>
            </p>
          </div>
        </div>
        <%= if not @framing and length(@framing_results) > 0 do %>
          <button phx-click="go_to_results"
            style="padding:8px 20px;border:1px solid #10b981;border-radius:6px;background:#071a12;color:#10b981;font-size:12px;font-weight:700;cursor:pointer;letter-spacing:0.5px">
            VIEW SOLVE RESULTS &rarr;
          </button>
        <% end %>
      </div>

      <%!-- Model progress cards --%>
      <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:16px">
        <%= for {model_id, progress} <- @model_progress do %>
          <% model = TradingDesk.LLM.ModelRegistry.get(model_id) %>
          <% model_name = if model, do: model.name, else: to_string(model_id) %>
          <% result = Enum.find(@framing_results, fn {mid, _, _} -> mid == model_id end) %>
          <div style={"background:#0d1117;border:1px solid #{cond do progress == :done -> "#10b98155"; match?({:error, _, _}, progress) -> "#ef444455"; true -> "#1e293b" end};border-radius:8px;padding:20px"}>
            <%!-- Model header --%>
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px">
              <span style="font-size:13px;font-weight:700;color:#e2e8f0"><%= model_name %></span>
              <span style={"font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;letter-spacing:0.5px;#{phase_style(progress)}"}>
                <%= phase_label(progress) %>
              </span>
            </div>

            <%!-- Phase progress bar --%>
            <div style="display:flex;gap:4px;margin-bottom:14px">
              <%= for phase <- [:framing, :solving, :explaining, :done] do %>
                <% completed = phase_completed?(progress, phase) %>
                <% active = phase_active?(progress, phase) %>
                <div style={"flex:1;height:3px;border-radius:2px;background:#{cond do completed -> "#10b981"; active -> "#10b98188"; true -> "#1e293b" end}"}></div>
              <% end %>
            </div>

            <%!-- Framing details (if done) --%>
            <%= if result do %>
              <% {_, _, result_map} = result %>
              <%= if Map.has_key?(result_map, :framing) do %>
                <% framing = result_map.framing %>
                <% adjustments = framing.adjustments || [] %>
                <%= if length(adjustments) > 0 do %>
                  <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1px;margin-bottom:6px">ADJUSTMENTS</div>
                  <div style="display:flex;flex-wrap:wrap;gap:4px;margin-bottom:10px">
                    <%= for adj <- adjustments do %>
                      <span style="background:#111827;border:1px solid #1e293b;border-radius:3px;padding:2px 6px;font-size:10px;color:#94a3b8;font-family:monospace">
                        <%= adj.variable %>: <%= adj.original %> &rarr; <span style="color:#10b981;font-weight:700"><%= adj.adjusted %></span>
                      </span>
                    <% end %>
                  </div>
                <% else %>
                  <div style="font-size:11px;color:#475569;margin-bottom:10px">No variable adjustments — using current values as-is.</div>
                <% end %>

                <%= if framing.framing_notes do %>
                  <div style="font-size:11px;color:#7b8fa4;line-height:1.5;background:#0a0f18;border-radius:4px;padding:8px 10px;border-left:2px solid #2563eb">
                    <%= framing.framing_notes %>
                  </div>
                <% end %>
              <% end %>
            <% end %>

            <%!-- Error display --%>
            <%= if match?({:error, _, _}, progress) do %>
              <% {:error, phase, reason} = progress %>
              <div style="font-size:11px;color:#ef4444;background:#1f0a0a;border-radius:4px;padding:8px 10px;margin-top:8px">
                Failed at <%= phase %>: <%= inspect(reason) %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Step 5: Results ────────────────────────────────────────

  defp render_results(assigns) do
    ~H"""
    <div>
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
        <div style="display:flex;align-items:center;gap:12px">
          <button phx-click="back"
            style="padding:8px 16px;border:1px solid #1e293b;border-radius:6px;background:transparent;color:#7b8fa4;font-size:12px;font-weight:700;cursor:pointer">&larr; BACK</button>
          <div>
            <h2 style="font-size:18px;font-weight:700;color:#e2e8f0;margin:0">Solve Results</h2>
            <p style="font-size:12px;color:#7b8fa4;margin-top:4px">Each model's optimized allocation and AI explanation</p>
          </div>
        </div>
        <button phx-click="nav" phx-value-step="solve"
          style="padding:8px 20px;border:1px solid #2563eb;border-radius:6px;background:#111827;color:#60a5fa;font-size:12px;font-weight:700;cursor:pointer;letter-spacing:0.5px">
          NEW SCENARIO
        </button>
      </div>

      <%= if @framing_results == [] do %>
        <div style="text-align:center;padding:60px 20px;color:#475569">
          <div style="font-size:20px;margin-bottom:8px">No results yet</div>
          <div style="font-size:12px">Go back and run the framing pipeline first.</div>
        </div>
      <% else %>
        <%= for {model_id, model_name, result_map} <- @framing_results do %>
          <%= if Map.has_key?(result_map, :solver_result) do %>
            <% sr = result_map.solver_result %>
            <% explanation = result_map[:explanation] %>
            <div style="background:#0d1117;border:1px solid #1e293b;border-radius:8px;padding:20px;margin-bottom:20px">
              <%!-- Model header --%>
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
                <div style="display:flex;align-items:center;gap:10px">
                  <span style="font-size:14px;font-weight:700;color:#e2e8f0"><%= model_name %></span>
                  <span style={"background:#{if sr.status == :optimal, do: "#10b98122", else: "#ef444422"};color:#{if sr.status == :optimal, do: "#10b981", else: "#ef4444"};padding:2px 8px;border-radius:3px;font-size:10px;font-weight:700;letter-spacing:0.5px"}>
                    <%= sr.status |> to_string() |> String.upcase() %>
                  </span>
                </div>
              </div>

              <%!-- Key metrics --%>
              <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px;margin-bottom:16px">
                <div style="background:#111827;border-radius:6px;padding:12px;text-align:center">
                  <div style="font-size:9px;color:#475569;font-weight:600;letter-spacing:1px;margin-bottom:4px">PROFIT</div>
                  <div style="font-size:18px;font-weight:700;color:#10b981;font-family:monospace">$<%= format_number(sr.profit) %></div>
                </div>
                <div style="background:#111827;border-radius:6px;padding:12px;text-align:center">
                  <div style="font-size:9px;color:#475569;font-weight:600;letter-spacing:1px;margin-bottom:4px">TONS</div>
                  <div style="font-size:18px;font-weight:700;color:#e2e8f0;font-family:monospace"><%= format_number(sr.tons) %></div>
                </div>
                <div style="background:#111827;border-radius:6px;padding:12px;text-align:center">
                  <div style="font-size:9px;color:#475569;font-weight:600;letter-spacing:1px;margin-bottom:4px">ROI</div>
                  <div style="font-size:18px;font-weight:700;color:#60a5fa;font-family:monospace"><%= format_roi(sr.roi) %>%</div>
                </div>
                <div style="background:#111827;border-radius:6px;padding:12px;text-align:center">
                  <div style="font-size:9px;color:#475569;font-weight:600;letter-spacing:1px;margin-bottom:4px">CAPITAL</div>
                  <div style="font-size:18px;font-weight:700;color:#f59e0b;font-family:monospace">$<%= format_number(sr.cost) %></div>
                </div>
              </div>

              <%!-- Route allocation --%>
              <%= if length(sr.route_tons || []) > 0 do %>
                <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1px;margin-bottom:8px">ROUTE ALLOCATION</div>
                <% routes = ProductGroup.routes(@product_group) %>
                <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:8px;margin-bottom:16px">
                  <%= for {route, i} <- Enum.with_index(routes) do %>
                    <% tons = Enum.at(sr.route_tons || [], i, 0.0) %>
                    <% margin = Enum.at(sr.margins || [], i, 0.0) %>
                    <% active = tons > 0.5 %>
                    <div style={"background:#{if active, do: "#111827", else: "#0a0f18"};border:1px solid #{if active, do: "#10b98133", else: "#1e293b"};border-radius:4px;padding:8px 12px;display:flex;justify-content:space-between;align-items:center"}>
                      <span style={"font-size:11px;color:#{if active, do: "#e2e8f0", else: "#475569"};font-weight:#{if active, do: "600", else: "400"}"}><%= route[:name] || "Route #{i+1}" %></span>
                      <div style="text-align:right">
                        <div style={"font-size:12px;font-family:monospace;font-weight:700;color:#{if active, do: "#10b981", else: "#475569"}"}><%= format_number(tons) %> t</div>
                        <div style="font-size:9px;color:#7b8fa4">$<%= format_margin(margin) %>/t</div>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- LLM Explanation --%>
              <%= case explanation do %>
                <% {:ok, text} -> %>
                  <div style="font-size:10px;font-weight:700;color:#c4b5fd;letter-spacing:1px;margin-bottom:8px">AI ANALYSIS</div>
                  <div style="font-size:12px;color:#94a3b8;line-height:1.7;background:#0a0f18;border-radius:6px;padding:14px 16px;border-left:3px solid #7c3aed">
                    <%= text %>
                  </div>
                <% {:error, reason} -> %>
                  <div style="font-size:11px;color:#ef4444;margin-top:8px">Explanation failed: <%= inspect(reason) %></div>
                <% _ -> %>
              <% end %>
            </div>
          <% else %>
            <%!-- Error result --%>
            <div style="background:#0d1117;border:1px solid #ef444444;border-radius:8px;padding:20px;margin-bottom:20px">
              <div style="font-size:14px;font-weight:700;color:#e2e8f0;margin-bottom:8px"><%= model_name %></div>
              <div style="font-size:12px;color:#ef4444">
                Pipeline error at <%= result_map[:phase] || "unknown" %> phase: <%= inspect(result_map[:reason] || "unknown error") %>
              </div>
            </div>
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ── Helpers ────────────────────────────────────────────────

  defp group_variables(metadata, current_vars) do
    metadata
    |> Enum.map(fn meta -> {meta, Map.get(current_vars, meta.key)} end)
    |> Enum.group_by(fn {meta, _} -> meta.group |> to_string() |> String.upcase() end)
    |> Enum.sort_by(fn {group, _} -> group end)
  end

  defp format_val(val, %{type: :boolean}), do: if(val in [true, 1, 1.0], do: "YES", else: "NO")
  defp format_val(val, _meta) when is_float(val) and abs(val) >= 1000 do
    val |> round() |> format_number()
  end
  defp format_val(val, _meta) when is_float(val), do: :erlang.float_to_binary(val, decimals: 1)
  defp format_val(val, _meta) when is_integer(val), do: Integer.to_string(val)
  defp format_val(val, _meta), do: to_string(val)

  defp format_number(val) when is_float(val), do: val |> round() |> format_number()
  defp format_number(val) when is_integer(val) do
    val
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end
  defp format_number(nil), do: "N/A"
  defp format_number(val), do: to_string(val)

  defp format_roi(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 1)
  defp format_roi(val) when is_number(val), do: to_string(val)
  defp format_roi(_), do: "0.0"

  defp format_margin(val) when is_float(val), do: :erlang.float_to_binary(val, decimals: 1)
  defp format_margin(_), do: "0.0"

  defp load_contracts(product_group) do
    store_key = case product_group do
      :ammonia_domestic -> :ammonia
      other -> other
    end

    try do
      TradingDesk.Contracts.Store.get_active_set(store_key)
      |> Enum.map(fn c ->
        %{
          counterparty: c.counterparty || "Unknown",
          direction: c.counterparty_type || :unknown,
          status: c.status || :pending,
          quantity: c.quantity_mt || 0,
          incoterm: (c.incoterm || "") |> to_string() |> String.upcase(),
          product: c.product || ""
        }
      end)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp status_bg_color(:approved), do: "#10b98122"
  defp status_bg_color(:pending), do: "#f59e0b22"
  defp status_bg_color(:rejected), do: "#ef444422"
  defp status_bg_color(_), do: "#47556922"

  defp status_fg_color(:approved), do: "#10b981"
  defp status_fg_color(:pending), do: "#f59e0b"
  defp status_fg_color(:rejected), do: "#ef4444"
  defp status_fg_color(_), do: "#475569"

  defp phase_label(:pending), do: "PENDING"
  defp phase_label(:framing), do: "FRAMING"
  defp phase_label(:solving), do: "SOLVING"
  defp phase_label(:explaining), do: "EXPLAINING"
  defp phase_label(:done), do: "DONE"
  defp phase_label({:error, _, _}), do: "ERROR"
  defp phase_label(_), do: "..."

  defp phase_style(:pending), do: "background:#1e293b;color:#475569"
  defp phase_style(:framing), do: "background:#1c1a0f;color:#f59e0b"
  defp phase_style(:solving), do: "background:#0f1a2e;color:#60a5fa"
  defp phase_style(:explaining), do: "background:#130d27;color:#c4b5fd"
  defp phase_style(:done), do: "background:#071a12;color:#10b981"
  defp phase_style({:error, _, _}), do: "background:#1f0a0a;color:#ef4444"
  defp phase_style(_), do: "background:#1e293b;color:#475569"

  defp phase_completed?(current, target) do
    order = [:framing, :solving, :explaining, :done]
    current_idx = if current == :done, do: 3, else: Enum.find_index(order, &(&1 == current)) || -1
    target_idx = Enum.find_index(order, &(&1 == target)) || -1
    target_idx < current_idx
  end

  defp phase_active?(current, target), do: current == target

  defp safe_call(fun, default) do
    try do
      fun.()
    rescue
      _ -> default
    catch
      :exit, _ -> default
    end
  end
end
