defmodule TradingDesk.ScenarioLive do
  @moduledoc """
  Interactive scenario desk for commodity traders.

  Supports all product groups (ammonia domestic, sulphur international,
  petcoke, ammonia international, etc.) with frame-driven UI that
  dynamically renders variables, routes, and constraints from the
  ProductGroup registry.

  Two modes:
    - SOLVE: tweak variables, get instant result
    - MONTE CARLO: run N scenarios around current values

  Two tabs:
    - TRADER: Manual scenario exploration with solve and Monte Carlo
    - AGENT: Automated agent monitoring with delta-based triggering
  """
  use Phoenix.LiveView
  require Logger

  alias TradingDesk.Variables
  alias TradingDesk.Solver.Port, as: Solver
  alias TradingDesk.Solver.Pipeline
  alias TradingDesk.Data.LiveState
  alias TradingDesk.Scenarios.Store
  alias TradingDesk.ProductGroup
  alias TradingDesk.Traders
  alias TradingDesk.Data.History.{Ingester, Stats}
  alias TradingDesk.Fleet.TrackedVessel

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "live_data")
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "auto_runner")
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "solve_pipeline")
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "sap_events")
    end

    # Load traders from DB; default to first active trader
    available_traders = Traders.list_active()
    selected_trader   = List.first(available_traders)

    # Product group defaults from trader's primary assignment
    product_group =
      if selected_trader,
        do: Traders.primary_product_group(selected_trader),
        else: :ammonia_domestic

    trader_id = if selected_trader, do: to_string(selected_trader.id), else: "trader_1"

    # Defensive: GenServer calls may fail if services haven't started yet
    live_vars = safe_call(fn -> LiveState.get() end, ProductGroup.default_values(product_group))
    auto_result = safe_call(fn -> TradingDesk.Scenarios.AutoRunner.latest() end, nil)
    vessel_data = safe_call(fn -> LiveState.get_supplementary(:vessel_tracking) end, nil)
    tides_data = safe_call(fn -> LiveState.get_supplementary(:tides) end, nil)
    saved = safe_call(fn -> Store.list(trader_id) end, [])

    # Load frame-driven metadata (pure functions — safe)
    frame = ProductGroup.frame(product_group)
    metadata = ProductGroup.variable_metadata(product_group)
    route_names = ProductGroup.route_names(product_group)
    constraint_names = ProductGroup.constraint_names(product_group)
    variable_groups = TradingDesk.VariablesDynamic.groups(product_group)
    available_groups = ProductGroup.list_with_info()

    # Ensure current_vars is always a plain map
    default_vars = ProductGroup.default_values(product_group)
    current_vars = if is_map(live_vars), do: live_vars, else: default_vars

    socket =
      socket
      |> assign(:available_traders, available_traders)
      |> assign(:selected_trader, selected_trader)
      |> assign(:product_group, product_group)
      |> assign(:frame, frame)
      |> assign(:live_vars, current_vars)
      |> assign(:current_vars, current_vars)
      |> assign(:overrides, MapSet.new())
      |> assign(:result, nil)
      |> assign(:distribution, nil)
      |> assign(:auto_result, auto_result)
      |> assign(:saved_scenarios, saved)
      |> assign(:trader_id, trader_id)
      |> assign(:metadata, metadata)
      |> assign(:route_names, route_names)
      |> assign(:constraint_names, constraint_names)
      |> assign(:variable_groups, variable_groups)
      |> assign(:available_groups, available_groups)
      |> assign(:solving, false)
      |> assign(:active_tab, :trader)
      |> assign(:objective_mode, :max_profit)
      |> assign(:agent_history, [])
      |> assign(:explanation, nil)
      |> assign(:explaining, false)
      |> assign(:pipeline_phase, nil)
      |> assign(:pipeline_detail, nil)
      |> assign(:contracts_stale, false)
      |> assign(:vessel_data, vessel_data)
      |> assign(:tides_data, tides_data)
      # Trader intent + pre-solve review
      |> assign(:trader_action, "")
      |> assign(:intent, nil)
      |> assign(:intent_loading, false)
      |> assign(:show_review, false)
      |> assign(:review_mode, nil)
      |> assign(:sap_positions, nil)
      |> assign(:post_solve_impact, nil)
      |> assign(:delivery_impact, nil)
      |> assign(:ops_sent, false)
      |> assign(:ammonia_prices, TradingDesk.Data.AmmoniaPrices.price_summary())
      |> assign(:contracts_data, load_contracts_data())
      |> assign(:api_status, load_api_status())
      |> assign(:solve_history, [])
      |> assign(:history_stats, nil)
      |> assign(:ingestion_running, false)
      |> assign(:seed_ingestion_running, false)
      |> assign(:seed_ingestion_result, nil)
      |> assign(:seed_files, TradingDesk.Contracts.SeedLoader.list_seed_files())
      |> assign(:anon_model_preview, nil)
      |> assign(:show_anon_preview, false)
      |> assign(:history_source, :river)
      |> assign(:history_year_from, Date.utc_today().year - 1)
      |> assign(:history_year_to, Date.utc_today().year)
      # Fleet tab
      |> assign(:fleet_vessels, [])
      |> assign(:fleet_pg_filter, to_string(product_group))
      # Model summary (always computed) + scenario description (trader narrative)
      |> assign(:model_summary, "")
      |> assign(:scenario_description, "")
      |> assign(:show_explanation_popup, false)

    # Build the initial model summary from the fully-assigned socket
    socket = assign(socket, :model_summary, build_model_summary_text(socket.assigns))

    {:ok, socket}
  end

  @impl true
  def handle_event("solve", _params, socket) do
    # Show pre-solve review popup instead of solving immediately
    book = TradingDesk.Contracts.SapPositions.book_summary()
    anon_preview = build_anon_model_preview(socket.assigns.model_summary, book)
    socket =
      socket
      |> assign(:show_review, true)
      |> assign(:review_mode, :solve)
      |> assign(:sap_positions, book)
      |> assign(:anon_model_preview, anon_preview)
      |> assign(:show_anon_preview, false)
    # If trader has typed an action, parse intent in background
    socket = maybe_parse_intent(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("monte_carlo", _params, socket) do
    book = TradingDesk.Contracts.SapPositions.book_summary()
    anon_preview = build_anon_model_preview(socket.assigns.model_summary, book)
    socket =
      socket
      |> assign(:show_review, true)
      |> assign(:review_mode, :monte_carlo)
      |> assign(:sap_positions, book)
      |> assign(:anon_model_preview, anon_preview)
      |> assign(:show_anon_preview, false)
    socket = maybe_parse_intent(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_anon_preview", _params, socket) do
    {:noreply, assign(socket, :show_anon_preview, !socket.assigns.show_anon_preview)}
  end

  @impl true
  def handle_event("update_action", %{"action" => text}, socket) do
    {:noreply, assign(socket, :trader_action, text)}
  end

  @impl true
  def handle_event("confirm_solve", _params, socket) do
    # Apply intent variable adjustments if any, then solve.
    # Objective is set by the trader in the popup — not auto-applied from AI suggestion.
    vars = apply_intent_adjustments(socket.assigns.current_vars, socket.assigns.intent)
    mode = socket.assigns.review_mode

    socket =
      socket
      |> assign(:current_vars, vars)
      |> assign(:show_review, false)
      |> assign(:solving, true)
      |> assign(:pipeline_phase, :checking_contracts)
      |> assign(:pipeline_detail, nil)
      |> assign(:contracts_stale, false)
      |> assign(:post_solve_impact, nil)

    case mode do
      :monte_carlo -> send(self(), :do_monte_carlo)
      _ -> send(self(), :do_solve)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_review", _params, socket) do
    socket =
      socket
      |> assign(:show_review, false)
      |> assign(:review_mode, nil)
      |> assign(:intent, nil)
    {:noreply, socket}
  end

  # Stops click propagation from the modal body reaching the backdrop dismiss handler.
  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("update_scenario_description", %{"description" => text}, socket) do
    socket = assign(socket, :scenario_description, text)
    summary = build_model_summary_text(socket.assigns)
    {:noreply, assign(socket, :model_summary, summary)}
  end

  @impl true
  def handle_event("show_explanation_popup", _params, socket) do
    {:noreply, assign(socket, :show_explanation_popup, true)}
  end

  @impl true
  def handle_event("close_explanation_popup", _params, socket) do
    {:noreply, assign(socket, :show_explanation_popup, false)}
  end

  @impl true
  def handle_event("save_explanation", _params, socket) do
    # Embed explanation in the result map and save as a scenario
    result = socket.assigns.result
    explanation = socket.assigns.explanation
    if result && is_binary(explanation) do
      ts = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")
      name = "Analysis #{ts}"
      result_with_note = Map.put(result, :analyst_note, explanation)
      try do
        Store.save(socket.assigns.trader_id, name,
          socket.assigns.current_vars, result_with_note, nil)
      rescue
        _ -> :ok
      end
      saved = safe_call(fn -> Store.list(socket.assigns.trader_id) end, [])
      {:noreply, assign(socket, show_explanation_popup: false, saved_scenarios: saved)}
    else
      {:noreply, assign(socket, :show_explanation_popup, false)}
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    pg = socket.assigns.product_group
    live = safe_call(fn -> LiveState.get() end, ProductGroup.default_values(pg))
    live = if is_map(live), do: live, else: ProductGroup.default_values(pg)
    socket =
      socket
      |> assign(:current_vars, live)
      |> assign(:live_vars, live)
      |> assign(:overrides, MapSet.new())
      |> assign(:result, nil)
      |> assign(:distribution, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_var", %{"key" => key, "value" => value}, socket) do
    key_atom = String.to_existing_atom(key)
    parsed = parse_value(key_atom, value)

    socket =
      socket
      |> assign(:current_vars, Map.put(socket.assigns.current_vars, key_atom, parsed))
      |> assign(:overrides, MapSet.put(socket.assigns.overrides, key_atom))

    {:noreply, assign(socket, :model_summary, build_model_summary_text(socket.assigns))}
  end

  @impl true
  def handle_event("toggle_override", %{"key" => key}, socket) do
    key_atom = String.to_existing_atom(key)

    {new_vars, new_overrides} =
      if MapSet.member?(socket.assigns.overrides, key_atom) do
        live_val = Map.get(socket.assigns.live_vars, key_atom)
        {Map.put(socket.assigns.current_vars, key_atom, live_val),
         MapSet.delete(socket.assigns.overrides, key_atom)}
      else
        {socket.assigns.current_vars, MapSet.put(socket.assigns.overrides, key_atom)}
      end

    socket =
      socket
      |> assign(:current_vars, new_vars)
      |> assign(:overrides, new_overrides)

    {:noreply, assign(socket, :model_summary, build_model_summary_text(socket.assigns))}
  end

  @impl true
  def handle_event("toggle_bool", %{"key" => key}, socket) do
    key_atom = String.to_existing_atom(key)
    current = Map.get(socket.assigns.current_vars, key_atom)
    new_vars = Map.put(socket.assigns.current_vars, key_atom, !current)
    new_overrides = MapSet.put(socket.assigns.overrides, key_atom)

    socket =
      socket
      |> assign(:current_vars, new_vars)
      |> assign(:overrides, new_overrides)

    {:noreply, assign(socket, :model_summary, build_model_summary_text(socket.assigns))}
  end

  @impl true
  def handle_event("save_scenario", %{"name" => name}, socket) do
    case socket.assigns.result do
      nil -> {:noreply, socket}
      result ->
        {:ok, _} = Store.save(
          socket.assigns.trader_id,
          name,
          socket.assigns.current_vars,
          result,
          nil,
          to_string(socket.assigns.product_group)
        )
        scenarios = Store.list(socket.assigns.trader_id)
        {:noreply, assign(socket, :saved_scenarios, scenarios)}
    end
  end

  @impl true
  @impl true
  def handle_event("save_and_send_ops", _params, socket) do
    case socket.assigns.result do
      nil ->
        {:noreply, socket}

      result ->
        trader_id    = socket.assigns.trader_id
        action       = socket.assigns.trader_action || ""
        intent       = socket.assigns.intent
        objective    = socket.assigns.objective_mode
        delivery_impact = socket.assigns.delivery_impact

        timestamp_str = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M")
        preview = if action != "", do: " — #{String.slice(action, 0, 42)}", else: ""
        name = "#{timestamp_str}#{preview}"

        {:ok, _} = Store.save(trader_id, name, socket.assigns.current_vars, result, nil)
        scenarios = Store.list(trader_id)

        ops_ctx = %{
          trader_id:       trader_id,
          trader_action:   action,
          intent:          intent,
          objective:       objective,
          result:          result,
          delivery_impact: delivery_impact,
          variables:       socket.assigns.current_vars,
          timestamp:       timestamp_str,
          summary:         (intent && intent.summary) || action || "Scenario solve"
        }
        Task.start(fn -> TradingDesk.Ops.EmailPipeline.send(ops_ctx) end)

        {:noreply, socket |> assign(:ops_sent, true) |> assign(:saved_scenarios, scenarios)}
    end
  end

  @impl true
  def handle_event("load_scenario", %{"id" => id}, socket) do
    id = String.to_integer(id)
    case Enum.find(socket.assigns.saved_scenarios, &(&1.id == id)) do
      nil -> {:noreply, socket}
      scenario ->
        # Restore analyst note if it was saved in the result
        analyst_note = Map.get(scenario.result, :analyst_note)
        socket =
          socket
          |> assign(:current_vars, scenario.variables)
          |> assign(:result, scenario.result)
          |> assign(:overrides, MapSet.new(Map.keys(scenario.variables)))
          |> assign(:active_tab, :trader)
          |> assign(:explanation, analyst_note)
          |> assign(:explaining, false)

        # Rebuild model summary from restored variables
        socket = assign(socket, :model_summary, build_model_summary_text(socket.assigns))

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_trader", %{"trader" => trader_id_str}, socket) do
    trader_id = String.to_integer(trader_id_str)
    trader = Enum.find(socket.assigns.available_traders, &(&1.id == trader_id))

    if trader do
      product_group = Traders.primary_product_group(trader)
      frame = ProductGroup.frame(product_group)

      if frame do
        socket =
          socket
          |> assign(:selected_trader, trader)
          |> assign(:trader_id, to_string(trader.id))
          |> assign(:product_group, product_group)
          |> assign(:frame, frame)
          |> assign(:metadata, ProductGroup.variable_metadata(product_group))
          |> assign(:route_names, ProductGroup.route_names(product_group))
          |> assign(:constraint_names, ProductGroup.constraint_names(product_group))
          |> assign(:variable_groups, TradingDesk.VariablesDynamic.groups(product_group))
          |> assign(:current_vars, ProductGroup.default_values(product_group))
          |> assign(:live_vars, ProductGroup.default_values(product_group))
          |> assign(:overrides, MapSet.new())
          |> assign(:result, nil)
          |> assign(:distribution, nil)
          |> assign(:saved_scenarios, safe_call(fn -> Store.list(to_string(trader.id)) end, []))

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_product_group", %{"group" => group}, socket) do
    pg = String.to_existing_atom(group)
    frame = ProductGroup.frame(pg)

    if frame do
      metadata = ProductGroup.variable_metadata(pg)
      route_names = ProductGroup.route_names(pg)
      constraint_names = ProductGroup.constraint_names(pg)
      variable_groups = TradingDesk.VariablesDynamic.groups(pg)
      default_vars = ProductGroup.default_values(pg)

      socket =
        socket
        |> assign(:product_group, pg)
        |> assign(:frame, frame)
        |> assign(:metadata, metadata)
        |> assign(:route_names, route_names)
        |> assign(:constraint_names, constraint_names)
        |> assign(:variable_groups, variable_groups)
        |> assign(:current_vars, default_vars)
        |> assign(:live_vars, default_vars)
        |> assign(:overrides, MapSet.new())
        |> assign(:result, nil)
        |> assign(:distribution, nil)
        |> assign(:explanation, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_objective", %{"objective" => obj}, socket) do
    objective = String.to_existing_atom(obj)
    {:noreply, assign(socket, :objective_mode, objective)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    socket = assign(socket, :active_tab, tab_atom)

    # Fetch fresh data when switching to specific tabs
    socket =
      case tab_atom do
        :agent ->
          history = TradingDesk.Scenarios.AutoRunner.history()
          assign(socket, :agent_history, history)
        :apis ->
          assign(socket, api_status: load_api_status())
        :contracts ->
          assign(socket, contracts_data: load_contracts_data())
        :solves ->
          assign(socket, solve_history: load_solve_history(socket.assigns.product_group, socket.assigns.trader_id))
        :history ->
          assign(socket, history_stats: Stats.all(history_filter_opts(socket.assigns)))
        :fleet ->
          assign(socket, fleet_vessels: load_fleet_vessels(socket.assigns.fleet_pg_filter))
        _ ->
          socket
      end

    {:noreply, socket}
  end

  # ── Fleet tab events ──

  @impl true
  def handle_event("fleet_filter_pg", %{"pg" => pg}, socket) do
    socket =
      socket
      |> assign(:fleet_pg_filter, pg)
      |> assign(:fleet_vessels, load_fleet_vessels(pg))
    {:noreply, socket}
  end

  @impl true
  def handle_event("fleet_toggle_tracking", %{"id" => id}, socket) do
    vessel = TradingDesk.Repo.get(TrackedVessel, id)
    if vessel do
      new_status = if vessel.status in ["active", "in_transit"], do: "cancelled", else: "active"
      TrackedVessel.update(vessel, %{status: new_status})
      # Refresh AIS subscription with updated MMSI list
      TradingDesk.Data.AIS.AISStreamConnector.refresh_tracked()
    end
    {:noreply, assign(socket, fleet_vessels: load_fleet_vessels(socket.assigns.fleet_pg_filter))}
  end

  @impl true
  def handle_event("fleet_add_vessel", params, socket) do
    attrs = %{
      vessel_name: String.trim(params["vessel_name"] || ""),
      mmsi: nilify(params["mmsi"]),
      imo: nilify(params["imo"]),
      sap_shipping_number: nilify(params["sap_shipping"]),
      sap_contract_id: nilify(params["sap_contract"]),
      product_group: socket.assigns.fleet_pg_filter,
      cargo: nilify(params["cargo"]),
      loading_port: nilify(params["loading_port"]),
      discharge_port: nilify(params["discharge_port"]),
      eta: parse_date(params["eta"]),
      status: "active"
    }

    case TrackedVessel.create(attrs) do
      {:ok, _} ->
        TradingDesk.Data.AIS.AISStreamConnector.refresh_tracked()
        {:noreply, assign(socket, fleet_vessels: load_fleet_vessels(socket.assigns.fleet_pg_filter))}
      {:error, _cs} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("fleet_delete_vessel", %{"id" => id}, socket) do
    vessel = TradingDesk.Repo.get(TrackedVessel, id)
    if vessel, do: TrackedVessel.delete(vessel)
    TradingDesk.Data.AIS.AISStreamConnector.refresh_tracked()
    {:noreply, assign(socket, fleet_vessels: load_fleet_vessels(socket.assigns.fleet_pg_filter))}
  end

  # ── History tab events ──

  @impl true
  def handle_event("filter_history", params, socket) do
    source = params["source"] && String.to_existing_atom(params["source"])
    year_from = params["year_from"] && String.to_integer(params["year_from"])
    year_to   = params["year_to"]   && String.to_integer(params["year_to"])

    socket =
      socket
      |> then(fn s -> if source,    do: assign(s, :history_source, source),         else: s end)
      |> then(fn s -> if year_from, do: assign(s, :history_year_from, year_from),   else: s end)
      |> then(fn s -> if year_to,   do: assign(s, :history_year_to, year_to),       else: s end)

    socket = assign(socket, :history_stats, Stats.all(history_filter_opts(socket.assigns)))
    {:noreply, socket}
  end

  @impl true
  def handle_event("trigger_backfill", _params, socket) do
    pid = self()
    Task.Supervisor.start_child(TradingDesk.Contracts.TaskSupervisor, fn ->
      Ingester.run_full_backfill()
      send(pid, :history_ingestion_complete)
    end)
    {:noreply, assign(socket, :ingestion_running, true)}
  end

  @impl true
  def handle_event("snapshot_today", _params, socket) do
    pid = self()
    Task.Supervisor.start_child(TradingDesk.Contracts.TaskSupervisor, fn ->
      Ingester.snapshot_today()
      send(pid, :history_ingestion_complete)
    end)
    {:noreply, assign(socket, :ingestion_running, true)}
  end

  # --- Seed contract ingestion ---

  @impl true
  def handle_event("ingest_seed_contracts", _params, socket) do
    pid = self()
    Task.Supervisor.start_child(TradingDesk.Contracts.TaskSupervisor, fn ->
      result = TradingDesk.Contracts.SeedLoader.reload_all()
      send(pid, {:seed_ingestion_complete, result})
    end)
    {:noreply, assign(socket, seed_ingestion_running: true, seed_ingestion_result: nil)}
  end

  # --- Async solve handlers ---

  @impl true
  def handle_info(:do_solve, socket) do
    vars = socket.assigns.current_vars
    pg = socket.assigns.product_group
    obj = socket.assigns.objective_mode
    solver_opts = [objective: obj]
    Pipeline.solve_async(vars, product_group: pg, caller_ref: :trader_solve, solver_opts: solver_opts)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_monte_carlo, socket) do
    vars = socket.assigns.current_vars
    pg = socket.assigns.product_group
    obj = socket.assigns.objective_mode
    solver_opts = [objective: obj]
    Pipeline.monte_carlo_async(vars, product_group: pg, caller_ref: :trader_mc, solver_opts: solver_opts)
    {:noreply, socket}
  end

  # --- Pipeline phase events ---

  @impl true
  def handle_info({:pipeline_event, :pipeline_started, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :checking_contracts)}
  end

  def handle_info({:pipeline_event, :pipeline_contracts_ok, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving, pipeline_detail: nil)}
  end

  def handle_info({:pipeline_event, :pipeline_ingesting, %{changed: n, caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :ingesting, pipeline_detail: "#{n} contract#{if n != 1, do: "s", else: ""} changed — Copilot ingesting")}
  end

  def handle_info({:pipeline_event, :pipeline_ingest_done, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving, pipeline_detail: nil)}
  end

  def handle_info({:pipeline_event, :pipeline_contracts_stale, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving, contracts_stale: true)}
  end

  def handle_info({:pipeline_event, :pipeline_solving, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, pipeline_phase: :solving)}
  end

  def handle_info({:pipeline_event, :pipeline_solve_done, %{mode: :solve, result: result, caller_ref: :trader_solve} = payload}, socket) do
    contracts_stale = Map.get(payload, :contracts_stale, false) or socket.assigns.contracts_stale
    delivery_impact = compute_delivery_impact(socket.assigns.intent, socket.assigns.product_group)
    socket = assign(socket,
      result: result,
      solving: false,
      pipeline_phase: nil,
      pipeline_detail: nil,
      contracts_stale: contracts_stale,
      explanation: nil,
      explaining: true,
      delivery_impact: delivery_impact,
      ops_sent: false
    )
    vars = socket.assigns.current_vars
    intent = socket.assigns.intent
    # Use scenario_description as the primary narrative; fall back to trader_action
    scenario_desc = socket.assigns.scenario_description || ""
    trader_action  = socket.assigns.trader_action || ""
    trader_scenario = if scenario_desc != "", do: scenario_desc, else: trader_action
    objective = socket.assigns.objective_mode
    lv_pid = self()

    # Spawn explanation + post-solve impact analysis
    spawn(fn ->
      try do
        case TradingDesk.Analyst.explain_solve_with_impact(vars, result, intent, trader_scenario, objective) do
          {:ok, text, impact} ->
            send(lv_pid, {:explanation_result, text})
            send(lv_pid, {:post_solve_impact, impact})
          {:ok, text} ->
            send(lv_pid, {:explanation_result, text})
          {:error, reason} ->
            Logger.warning("Analyst explain_solve failed: #{inspect(reason)}")
            send(lv_pid, {:explanation_result, {:error, reason}})
        end
      catch
        kind, reason ->
          Logger.error("Analyst explain_solve crashed: #{kind} #{inspect(reason)}")
          send(lv_pid, {:explanation_result, {:error, "#{kind}: #{inspect(reason)}"}})
      end
    end)
    {:noreply, socket}
  end

  def handle_info({:pipeline_event, :pipeline_solve_done, %{mode: :monte_carlo, result: dist, caller_ref: :trader_mc} = payload}, socket) do
    contracts_stale = Map.get(payload, :contracts_stale, false) or socket.assigns.contracts_stale
    socket = assign(socket,
      distribution: dist,
      solving: false,
      pipeline_phase: nil,
      pipeline_detail: nil,
      contracts_stale: contracts_stale,
      explanation: nil,
      explaining: true
    )
    vars = socket.assigns.current_vars
    lv_pid = self()
    spawn(fn ->
      try do
        case TradingDesk.Analyst.explain_distribution(vars, dist) do
          {:ok, text} -> send(lv_pid, {:explanation_result, text})
          {:error, reason} ->
            Logger.warning("Analyst explain_distribution failed: #{inspect(reason)}")
            send(lv_pid, {:explanation_result, {:error, reason}})
        end
      catch
        kind, reason ->
          Logger.error("Analyst explain_distribution crashed: #{kind} #{inspect(reason)}")
          send(lv_pid, {:explanation_result, {:error, "#{kind}: #{inspect(reason)}"}})
      end
    end)
    {:noreply, socket}
  end

  def handle_info({:pipeline_event, :pipeline_error, %{caller_ref: ref}}, socket) when ref in [:trader_solve, :trader_mc] do
    {:noreply, assign(socket, solving: false, pipeline_phase: nil, pipeline_detail: nil)}
  end

  # Catch-all for pipeline events not relevant to this LV (e.g. AutoRunner's)
  def handle_info({:pipeline_event, _, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sap_position_changed, _payload}, socket) do
    # SAP pushed a position update — refresh API status and contracts data
    {:noreply, assign(socket, api_status: load_api_status(), contracts_data: load_contracts_data())}
  end

  @impl true
  def handle_info({:data_updated, _source}, socket) do
    pg = socket.assigns.product_group
    live = LiveState.get()

    # Refresh API status on the APIs tab if it's active
    socket = if socket.assigns.active_tab == :apis do
      assign(socket, api_status: load_api_status())
    else
      socket
    end

    # Only merge live data for ammonia_domestic (which uses the Variables struct).
    # Other product groups use frame defaults and manual overrides.
    if pg == :ammonia_domestic do
      overrides = socket.assigns.overrides
      current = socket.assigns.current_vars
      valid_keys = MapSet.new(ProductGroup.variable_keys(pg))

      updated_current =
        Enum.reduce(Map.from_struct(live), current, fn {key, val}, acc ->
          if MapSet.member?(overrides, key) or not MapSet.member?(valid_keys, key) do
            acc
          else
            Map.put(acc, key, val)
          end
        end)

      socket = assign(socket, live_vars: live, current_vars: updated_current)
      socket = assign(socket, :model_summary, build_model_summary_text(socket.assigns))
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:supplementary_updated, :vessel_tracking}, socket) do
    vessel_data = LiveState.get_supplementary(:vessel_tracking)
    {:noreply, assign(socket, :vessel_data, vessel_data)}
  end

  @impl true
  def handle_info({:supplementary_updated, :tides}, socket) do
    tides_data = LiveState.get_supplementary(:tides)
    {:noreply, assign(socket, :tides_data, tides_data)}
  end

  @impl true
  def handle_info({:supplementary_updated, _}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:auto_result, result}, socket) do
    history = TradingDesk.Scenarios.AutoRunner.history()
    socket =
      socket
      |> assign(:auto_result, result)
      |> assign(:agent_history, history)

    # Refresh solve history if on the Solves tab
    socket = if socket.assigns.active_tab == :solves do
      assign(socket, solve_history: load_solve_history(socket.assigns.product_group, socket.assigns.trader_id))
    else
      socket
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:intent_result, intent}, socket) do
    {:noreply, assign(socket, intent: intent, intent_loading: false)}
  end

  @impl true
  def handle_info({:post_solve_impact, impact}, socket) do
    {:noreply, assign(socket, post_solve_impact: impact)}
  end

  @impl true
  def handle_info({:explanation_result, {:error, reason}}, socket) do
    error_text = analyst_error_text(reason)
    {:noreply, assign(socket, explanation: {:error, error_text}, explaining: false)}
  end

  def handle_info({:explanation_result, text}, socket) do
    {:noreply, assign(socket, explanation: text, explaining: false)}
  end

  @impl true
  def handle_info(:history_ingestion_complete, socket) do
    socket =
      socket
      |> assign(:ingestion_running, false)
      |> assign(:history_stats, Stats.all(history_filter_opts(socket.assigns)))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:seed_ingestion_complete, result}, socket) do
    socket =
      socket
      |> assign(:seed_ingestion_running, false)
      |> assign(:seed_ingestion_result, result)
      |> assign(:contracts_data, load_contracts_data())
      |> assign(:seed_files, TradingDesk.Contracts.SeedLoader.list_seed_files())
    {:noreply, socket}
  end

  @impl true
  def handle_info({:auto_explanation, text}, socket) do
    auto_result =
      if socket.assigns.auto_result do
        Map.put(socket.assigns.auto_result, :explanation, text)
      else
        nil
      end
    {:noreply, assign(socket, :auto_result, auto_result)}
  end

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace">
      <%!-- === TOP BAR === --%>
      <div style="background:#0d1117;border-bottom:1px solid #1b2838;padding:10px 20px;display:flex;justify-content:space-between;align-items:center">
        <div style="display:flex;align-items:center;gap:12px">
          <div style={"width:8px;height:8px;border-radius:50%;background:#{if @auto_result, do: "#10b981", else: "#64748b"};box-shadow:0 0 8px #{if @auto_result, do: "#10b981", else: "transparent"}"}></div>
          <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px"><%= (@frame && @frame[:name]) || "SCENARIO DESK" %></span>
          <select phx-change="switch_trader" name="trader"
            style="background:#111827;border:1px solid #2563eb;color:#60a5fa;padding:3px 8px;border-radius:4px;font-size:10px;font-weight:600;cursor:pointer"
            title="Active trader">
            <%= for t <- @available_traders do %>
              <option value={t.id} selected={@selected_trader && t.id == @selected_trader.id}><%= t.name %></option>
            <% end %>
          </select>
          <select phx-change="switch_product_group" name="group"
            style="background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:3px 8px;border-radius:4px;font-size:10px;font-weight:600;cursor:pointer">
            <%= for pg <- @available_groups do %>
              <option value={pg.id} selected={pg.id == @product_group}><%= pg.name %></option>
            <% end %>
          </select>
          <a href="/contracts" style="color:#a78bfa;text-decoration:none;font-size:11px;font-weight:600;padding:4px 10px;border:1px solid #1e293b;border-radius:4px">CONTRACTS</a>
        </div>
        <div style="display:flex;align-items:center;gap:12px;font-size:11px">
          <%!-- Theme toggle --%>
          <button onclick="window.toggleTheme()"
            style="background:none;border:1px solid #2d3748;color:#64748b;padding:3px 9px;border-radius:4px;font-size:10px;cursor:pointer;font-weight:600;letter-spacing:0.5px"
            title="Toggle light / dark theme">
            ◐ THEME
          </button>
          <%!-- Ammonia Prices Ticker --%>
          <div style="display:flex;align-items:center;gap:8px;padding-right:12px;border-right:1px solid #1b2838">
            <%= for p <- Enum.take(@ammonia_prices, 4) do %>
              <span style="color:#475569"><%= p.label %></span>
              <span style={"color:#{if p.direction == :buy, do: "#60a5fa", else: "#f59e0b"};font-weight:700;font-family:monospace"}>$<%= round(p.price) %></span>
            <% end %>
          </div>
          <%= if @auto_result do %>
            <span style="color:#64748b">AUTO</span>
            <span style={"background:#0f2a1f;color:#{signal_color(@auto_result.distribution.signal)};padding:3px 10px;border-radius:4px;font-weight:700;font-size:11px"}><%= signal_text(@auto_result.distribution.signal) %></span>
            <span style="color:#64748b">E[V]</span>
            <span style="color:#10b981;font-weight:700;font-family:monospace">$<%= format_number(@auto_result.distribution.mean) %></span>
            <span style="color:#64748b">VaR₅</span>
            <span style="color:#f59e0b;font-weight:700;font-family:monospace">$<%= format_number(@auto_result.distribution.p5) %></span>
          <% else %>
            <span style="color:#475569">AUTO: waiting...</span>
          <% end %>
        </div>
      </div>

      <div style="display:grid;grid-template-columns:400px 1fr;height:calc(100vh - 45px)">
        <%!-- === LEFT: VARIABLES === --%>
        <div style="background:#0a0f18;border-right:1px solid #1b2838;overflow-y:auto;padding:14px">
          <%= for group <- @variable_groups do %>
            <div style="margin-bottom:14px">
              <div style="display:flex;justify-content:space-between;margin-bottom:8px;padding-bottom:6px;border-bottom:1px solid #1b283833">
                <span style={"font-size:11px;font-weight:700;color:#{group_color(group)};letter-spacing:1.2px;text-transform:uppercase"}>
                  <%= group_icon(group) %> <%= to_string(group) %>
                </span>
              </div>
              <%= for meta <- Enum.filter(@metadata, & &1.group == group) do %>
                <div style={"display:grid;grid-template-columns:130px 1fr 68px 24px;align-items:center;gap:6px;padding:4px 6px;border-radius:4px;margin-bottom:1px;border-left:2px solid #{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: "transparent"};background:#{if MapSet.member?(@overrides, meta.key), do: "#111827", else: "transparent"}"}>
                  <span style="font-size:11px;color:#8899aa;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= meta.label %></span>
                  <%= if Map.get(meta, :type) == :boolean do %>
                    <button phx-click="toggle_bool" phx-value-key={meta.key}
                      style={"padding:2px 0;border:1px solid #{if Map.get(@current_vars, meta.key), do: "#991b1b", else: "#1e3a5f"};border-radius:3px;background:#{if Map.get(@current_vars, meta.key), do: "#7f1d1d", else: "#0f2a3d"};color:#{if Map.get(@current_vars, meta.key), do: "#fca5a5", else: "#67e8f9"};font-weight:700;font-size:10px;cursor:pointer;letter-spacing:1px"}>
                      <%= if Map.get(@current_vars, meta.key), do: "⬤ OUTAGE", else: "◯ ONLINE" %>
                    </button>
                  <% else %>
                    <input type="range" min={meta.min} max={meta.max} step={meta.step}
                      value={Map.get(@current_vars, meta.key)}
                      phx-hook="Slider" id={"slider-#{meta.key}"} data-key={meta.key}
                      style={"width:100%;accent-color:#{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: group_color(group)};height:3px;cursor:pointer"} />
                  <% end %>
                  <span style={"font-size:11px;font-family:monospace;text-align:right;color:#{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: group_color(group)};font-weight:600"}>
                    <%= if Map.get(meta, :type) != :boolean, do: format_var(meta, Map.get(@current_vars, meta.key)), else: "" %>
                  </span>
                  <button phx-click="toggle_override" phx-value-key={meta.key}
                    style={"background:none;border:none;cursor:pointer;font-size:12px;padding:0;opacity:#{if MapSet.member?(@overrides, meta.key), do: "0.9", else: "0.4"}"}>
                    <%= if MapSet.member?(@overrides, meta.key), do: "⚡", else: "📡" %>
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>

          <div style="border-top:1px solid #1b2838;padding-top:12px;margin-top:8px">
            <%!-- Trader Action Input --%>
            <div style="margin-bottom:10px">
              <div style="font-size:10px;color:#a78bfa;letter-spacing:0.8px;margin-bottom:4px">TRADER ACTION</div>
              <textarea phx-blur="update_action" name="action"
                placeholder="Describe what you want to test... e.g. 'Redirect March Yuzhnyy cargo to India' or 'Simulate river drop to 15ft'"
                style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:8px;border-radius:6px;font-size:11px;font-family:inherit;resize:vertical;min-height:48px;max-height:120px"><%= @trader_action %></textarea>
            </div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
              <button phx-click="solve" disabled={@solving}
                style="padding:10px;border:none;border-radius:6px;font-weight:700;font-size:12px;background:linear-gradient(135deg,#0891b2,#06b6d4);color:#fff;cursor:pointer;letter-spacing:1px">
                <%= pipeline_button_text(@solving, @pipeline_phase, "SOLVE") %>
              </button>
              <button phx-click="monte_carlo" disabled={@solving}
                style="padding:10px;border:none;border-radius:6px;font-weight:700;font-size:12px;background:linear-gradient(135deg,#7c3aed,#8b5cf6);color:#fff;cursor:pointer;letter-spacing:1px">
                <%= pipeline_button_text(@solving, @pipeline_phase, "MONTE CARLO") %>
              </button>
            </div>
            <div style="margin-top:8px">
              <div style="font-size:10px;color:#64748b;letter-spacing:0.8px;margin-bottom:4px">OBJECTIVE</div>
              <select phx-change="switch_objective" name="objective"
                style="width:100%;background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:6px 8px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer">
                <%= for {val, label} <- [max_profit: "Maximize Profit", min_cost: "Minimize Cost", max_roi: "Maximize ROI", cvar_adjusted: "CVaR-Adjusted", min_risk: "Minimize Risk"] do %>
                  <option value={val} selected={val == @objective_mode}><%= label %></option>
                <% end %>
              </select>
            </div>
            <button phx-click="reset"
              style="width:100%;padding:7px;border:1px solid #1e293b;border-radius:6px;font-weight:600;font-size:11px;background:transparent;color:#64748b;cursor:pointer;margin-top:8px">
              📡 RESET TO LIVE
            </button>
            <div style="text-align:center;margin-top:6px;font-size:10px;color:#334155">
              <%= MapSet.size(@overrides) %> override<%= if MapSet.size(@overrides) != 1, do: "s", else: "" %> active
            </div>
          </div>

          <%!-- === FLEET & TIDES COMPACT === --%>
          <%= if @vessel_data || @tides_data do %>
            <div style="border-top:1px solid #1b2838;padding-top:10px;margin-top:10px">
              <div style="font-size:10px;font-weight:700;color:#60a5fa;letter-spacing:1.2px;margin-bottom:6px">FLEET & TIDES</div>
              <%= if @vessel_data && @vessel_data[:vessels] do %>
                <div style="font-size:11px;color:#94a3b8;margin-bottom:4px">
                  <%= length(@vessel_data[:vessels]) %> vessel<%= if length(@vessel_data[:vessels]) != 1, do: "s", else: "" %> tracked
                </div>
                <%= for vessel <- Enum.take(@vessel_data[:vessels] || [], 3) do %>
                  <div style="display:flex;align-items:center;gap:6px;font-size:10px;padding:2px 0">
                    <span style={"color:#{vessel_status_color(vessel[:status])}"}><%= vessel_status_icon(vessel[:direction]) %></span>
                    <span style="color:#c8d6e5;font-weight:600;max-width:90px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= vessel[:name] || "Unknown" %></span>
                    <span style="color:#64748b;font-size:9px">mi <%= vessel[:river_mile] || "?" %></span>
                    <span style="color:#475569;font-size:9px"><%= vessel[:nearest_waypoint] || "" %></span>
                  </div>
                <% end %>
              <% else %>
                <div style="font-size:10px;color:#475569">No AIS data</div>
              <% end %>
              <%= if @tides_data do %>
                <div style="display:flex;gap:8px;margin-top:4px;font-size:10px">
                  <%= if @tides_data[:water_level_ft] do %>
                    <span style="color:#60a5fa">WL: <%= Float.round(@tides_data[:water_level_ft], 1) %>ft</span>
                  <% end %>
                  <%= if @tides_data[:tidal_range_ft] do %>
                    <span style="color:#818cf8">Range: <%= Float.round(@tides_data[:tidal_range_ft], 1) %>ft</span>
                  <% end %>
                  <%= if @tides_data[:current_speed_kn] do %>
                    <span style="color:#38bdf8">Current: <%= Float.round(@tides_data[:current_speed_kn], 1) %>kn</span>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- === RIGHT: TABS === --%>
        <div style="overflow-y:auto;padding:16px">
          <%!-- Tab buttons --%>
          <div style="display:flex;gap:2px;margin-bottom:16px">
            <%= for {tab, label, color} <- [{:trader, "Trader", "#38bdf8"}, {:contracts, "Contracts", "#a78bfa"}, {:solves, "Solves", "#eab308"}, {:map, "Map", "#60a5fa"}, {:fleet, "Fleet", "#22d3ee"}, {:agent, "Agent", "#10b981"}, {:apis, "APIs", "#f97316"}, {:history, "History", "#06b6d4"}] do %>
              <button phx-click="switch_tab" phx-value-tab={tab}
                style={"padding:8px 16px;border:none;border-radius:6px 6px 0 0;font-size:12px;font-weight:600;cursor:pointer;background:#{if @active_tab == tab, do: "#111827", else: "transparent"};color:#{if @active_tab == tab, do: "#e2e8f0", else: "#475569"};border-bottom:2px solid #{if @active_tab == tab, do: color, else: "transparent"}"}>
                <%= label %>
              </button>
            <% end %>
          </div>

          <%!-- Pipeline status banner — always rendered to prevent layout shift --%>
          <div style={"margin-bottom:12px;#{if is_nil(@pipeline_phase), do: "visibility:hidden", else: ""}"}>
            <div style={"background:#{pipeline_bg(@pipeline_phase || :solving)};border:1px solid #{pipeline_border(@pipeline_phase || :solving)};border-radius:8px;padding:10px 14px;display:flex;align-items:center;gap:10px;font-size:12px"}>
              <div style={"width:8px;height:8px;border-radius:50%;background:#{pipeline_dot(@pipeline_phase || :solving)};#{if @pipeline_phase, do: "animation:pulse 1.5s infinite", else: ""}"}></div>
              <span style="color:#e2e8f0;font-weight:600"><%= if @pipeline_phase, do: pipeline_phase_text(@pipeline_phase), else: "Ready" %></span>
              <%= if @pipeline_detail do %>
                <span style="color:#94a3b8">— <%= @pipeline_detail %></span>
              <% end %>
            </div>
          </div>
          <%= if @contracts_stale and not @solving do %>
            <div style="background:#1c1917;border:1px solid #78350f;border-radius:8px;padding:8px 14px;margin-bottom:12px;font-size:11px;color:#fbbf24">
              ⚠ Contract data may be stale — scanner was unavailable during this solve
            </div>
          <% end %>

          <%!-- === TRADER TAB === --%>
          <%= if @active_tab == :trader do %>
            <%!-- === SCENARIO MODEL FORM === --%>
            <div style="background:#0a0318;border:1px solid #2d1b69;border-radius:10px;padding:16px;margin-bottom:16px">
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                <span style="font-size:11px;color:#a78bfa;font-weight:700;letter-spacing:1.2px">SCENARIO MODEL</span>
                <span style="font-size:10px;color:#475569">Objective: <%= objective_label(@objective_mode) %></span>
              </div>

              <%!-- Scenario description --%>
              <div style="margin-bottom:14px">
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:5px;font-weight:600">WHAT DO YOU WANT TO TEST?</div>
                <textarea phx-change="update_scenario_description" phx-debounce="blur" name="description"
                  rows="3"
                  placeholder="e.g. One barge in for repair — assess impact on D+3 delivery schedule"
                  style="width:100%;background:#060a11;border:1px solid #2d1b69;color:#c8d6e5;padding:10px;border-radius:6px;font-size:12px;font-family:inherit;resize:vertical;line-height:1.5;box-sizing:border-box"><%= @scenario_description %></textarea>
              </div>

              <%!-- Variable groups (editable) --%>
              <%= for {group, defs} <- Enum.group_by(@frame[:variables] || [], &(&1[:group])) |> Enum.sort_by(fn {g, _} -> to_string(g) end) do %>
                <% {booleans, numerics} = Enum.split_with(defs, &(&1[:type] == :boolean)) %>
                <div style="margin-bottom:12px">
                  <div style="font-size:9px;color:#475569;letter-spacing:1.4px;font-weight:700;margin-bottom:6px;text-transform:uppercase;padding-bottom:4px;border-bottom:1px solid #1e293b">
                    <%= to_string(group) |> String.upcase() %>
                  </div>

                  <%!-- Numeric variables grid --%>
                  <%= if numerics != [] do %>
                    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:6px;margin-bottom:6px">
                      <%= for v <- numerics do %>
                        <% val = Map.get(@current_vars, v[:key]) %>
                        <% is_override = MapSet.member?(@overrides, v[:key]) %>
                        <% live_val = Map.get(@live_vars, v[:key]) %>
                        <% display_val = case val do
                              fv when is_float(fv) -> :erlang.float_to_binary(fv, [{:decimals, 1}])
                              iv when is_integer(iv) -> to_string(iv)
                              _ -> to_string(val)
                            end %>
                        <div style={"background:#{if is_override, do: "#0d1a0d", else: "#060a11"};border:1px solid #{if is_override, do: "#166534", else: "#1e293b"};border-radius:6px;padding:7px 9px"}>
                          <div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:4px">
                            <span style="font-size:10px;color:#64748b;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:110px" title={v[:label]}><%= v[:label] %></span>
                            <%= if is_override do %>
                              <button phx-click="toggle_override" phx-value-key={v[:key]}
                                style="font-size:8px;color:#4ade80;background:none;border:none;cursor:pointer;padding:0;letter-spacing:0.5px">
                                ↺ LIVE
                              </button>
                            <% else %>
                              <span style="font-size:8px;color:#334155">LIVE</span>
                            <% end %>
                          </div>
                          <div style="display:flex;align-items:center;gap:4px">
                            <input type="number"
                              phx-change="update_var" phx-debounce="400"
                              phx-value-key={v[:key]}
                              name="value"
                              value={display_val}
                              min={v[:min]} max={v[:max]} step={v[:step] || "any"}
                              style={"flex:1;min-width:0;background:#0a0f18;border:1px solid #{if is_override, do: "#166534", else: "#1e293b"};color:#{if is_override, do: "#4ade80", else: "#c8d6e5"};padding:4px 6px;border-radius:4px;font-size:12px;font-family:monospace;font-weight:700;width:100%;box-sizing:border-box"} />
                            <%= if v[:unit] && v[:unit] != "" do %>
                              <span style="font-size:9px;color:#475569;white-space:nowrap"><%= v[:unit] %></span>
                            <% end %>
                          </div>
                          <%= if is_override and live_val != nil do %>
                            <div style="font-size:8px;color:#4ade80;margin-top:2px">
                              live: <%= case live_val do
                                fv when is_float(fv) -> :erlang.float_to_binary(fv, [{:decimals, 1}])
                                _ -> to_string(live_val)
                              end %>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>

                  <%!-- Boolean variables row --%>
                  <%= if booleans != [] do %>
                    <div style="display:flex;flex-wrap:wrap;gap:6px">
                      <%= for v <- booleans do %>
                        <% val = Map.get(@current_vars, v[:key]) %>
                        <% is_outage = val in [true, 1.0] %>
                        <button phx-click="toggle_bool" phx-value-key={v[:key]}
                          style={"display:flex;align-items:center;gap:6px;padding:5px 10px;border-radius:6px;border:1px solid #{if is_outage, do: "#991b1b", else: "#1e3a5f"};background:#{if is_outage, do: "#7f1d1d22", else: "#0f2a3d22"};cursor:pointer"}>
                          <span style={"font-size:10px;color:#{if is_outage, do: "#fca5a5", else: "#67e8f9"};font-weight:700"}>
                            <%= if is_outage, do: "⬤ OUTAGE", else: "◯ ONLINE" %>
                          </span>
                          <span style="font-size:10px;color:#64748b"><%= v[:label] %></span>
                        </button>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- Collapsible: full model context sent to Claude --%>
              <details style="margin-top:8px">
                <summary style="font-size:9px;color:#334155;cursor:pointer;letter-spacing:1px;font-weight:600;user-select:none">
                  MODEL CONTEXT (sent to Claude) ▸
                </summary>
                <pre style="font-size:9px;color:#475569;line-height:1.5;white-space:pre-wrap;margin:6px 0 0;background:#060a11;border:1px solid #1e293b;border-radius:4px;padding:8px;max-height:240px;overflow-y:auto"><%= @model_summary %></pre>
              </details>
            </div>

            <%!-- Solve result --%>
            <%= if @result && @result.status == :optimal do %>
              <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:flex-start">
                  <div>
                    <div style="font-size:11px;color:#64748b;letter-spacing:1px;text-transform:uppercase">Gross Profit</div>
                    <div style="font-size:36px;font-weight:800;color:#10b981;font-family:monospace">$<%= format_number(@result.profit) %></div>
                  </div>
                  <div style="background:#0f2a1f;padding:6px 14px;border-radius:6px;text-align:center">
                    <div style="font-size:10px;color:#64748b">STATUS</div>
                    <div style="font-size:13px;font-weight:700;color:#10b981">OPTIMAL</div>
                  </div>
                </div>
                <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-top:14px">
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">Tons</div><div style="font-size:15px;font-weight:700;font-family:monospace"><%= format_number(@result.tons) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">Barges</div><div style="font-size:15px;font-weight:700;font-family:monospace"><%= Float.round(@result.barges, 1) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">ROI</div><div style="font-size:15px;font-weight:700;font-family:monospace"><%= Float.round(@result.roi, 1) %>%</div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px"><div style="font-size:10px;color:#64748b">Capital</div><div style="font-size:15px;font-weight:700;font-family:monospace">$<%= format_number(@result.cost) %></div></div>
                </div>
                <%!-- Routes --%>
                <table style="width:100%;border-collapse:collapse;font-size:12px;margin-top:12px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px;color:#64748b;font-size:11px">Route</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:11px">Tons</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:11px">Margin</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:11px">Profit</th>
                  </tr></thead>
                  <tbody>
                    <%= for {name, idx} <- Enum.with_index(@route_names) do %>
                      <% tons = Enum.at(@result.route_tons, idx, 0) %>
                      <%= if tons > 0.5 do %>
                        <tr><td style="padding:6px;font-weight:600"><%= name %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace"><%= format_number(tons) %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#38bdf8">$<%= Float.round(Enum.at(@result.margins, idx, 0), 1) %>/t</td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#10b981;font-weight:700">$<%= format_number(Enum.at(@result.route_profits, idx, 0)) %></td></tr>
                      <% end %>
                    <% end %>
                  </tbody>
                </table>

                <%!-- Percentile rank if MC has been run --%>
                <%= if @distribution do %>
                  <% {pct, desc} = percentile_rank(@result.profit, @distribution) %>
                  <div style="margin-top:12px;padding:10px;background:#0a0f18;border-radius:6px;font-size:12px">
                    <div style="display:flex;align-items:center;gap:8px">
                      <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;position:relative;overflow:visible">
                        <div style={"width:#{pct}%;height:100%;background:linear-gradient(90deg,#ef4444,#f59e0b,#10b981);border-radius:3px"}></div>
                        <div style={"position:absolute;top:-3px;left:#{pct}%;width:2px;height:12px;background:#fff;border-radius:1px"}></div>
                      </div>
                    </div>
                    <div style="color:#94a3b8;margin-top:6px">
                      Your scenario ($<%= format_number(@result.profit) %>) is at the <span style="color:#38bdf8;font-weight:700"><%= pct %>th</span> percentile — <%= desc %>
                    </div>
                  </div>
                <% end %>

                <div style="display:flex;gap:8px;margin-top:12px">
                  <form phx-submit="save_scenario" style="display:flex;gap:8px;flex:1">
                    <input type="text" name="name" placeholder="Scenario name..." style="flex:1;background:#0a0f18;border:1px solid #1e293b;color:#c8d6e5;padding:8px;border-radius:6px;font-size:12px" />
                    <button type="submit" style="background:#1e293b;border:none;color:#94a3b8;padding:8px 14px;border-radius:6px;cursor:pointer;font-size:12px">💾 Save</button>
                  </form>
                  <button phx-click="show_explanation_popup" disabled={is_nil(@explanation) or @explaining}
                    style={"padding:8px 14px;border:1px solid #4c1d95;border-radius:6px;background:#1e1030;color:#{if is_nil(@explanation) or @explaining, do: "#475569", else: "#a78bfa"};cursor:#{if is_nil(@explanation) or @explaining, do: "default", else: "pointer"};font-size:12px;font-weight:600;white-space:nowrap"}>
                    🧠 Full Analysis
                  </button>
                </div>
              </div>
            <% end %>

            <%!-- AI Explanation --%>
            <div style="background:#0f1729;border:1px solid #1e293b;border-radius:8px;padding:12px;margin-bottom:16px">
              <div style="display:flex;align-items:center;gap:6px;margin-bottom:6px">
                <span style="font-size:11px;color:#8b5cf6;font-weight:700;letter-spacing:1px">🧠 ANALYST</span>
                <%= if @explaining do %>
                  <span style="font-size:10px;color:#475569">thinking...</span>
                <% end %>
              </div>
              <%= case @explanation do %>
                <% {:error, err_text} -> %>
                  <div style="font-size:12px;color:#f87171;line-height:1.5"><%= err_text %></div>
                <% text when is_binary(text) -> %>
                  <div style="font-size:13px;color:#c8d6e5;line-height:1.5"><%= text %></div>
                <% _ -> %>
                  <div style="font-size:12px;color:#475569;font-style:italic">Run SOLVE or MONTE CARLO to get analysis</div>
              <% end %>
            </div>

            <%!-- Monte Carlo distribution --%>
            <%= if @distribution do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                  <span style="font-size:11px;color:#64748b;letter-spacing:1px">MONTE CARLO — <%= @distribution.n_feasible %>/<%= @distribution.n_scenarios %> feasible</span>
                  <span style={"color:#{signal_color(@distribution.signal)};font-weight:700;font-size:12px"}><%= signal_text(@distribution.signal) %></span>
                </div>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:12px">
                  <div style="background:#0a0f18;padding:8px;border-radius:4px"><div style="font-size:10px;color:#64748b">Mean</div><div style="color:#10b981;font-weight:700;font-family:monospace">$<%= format_number(@distribution.mean) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:4px"><div style="font-size:10px;color:#64748b">VaR₅</div><div style="color:#f59e0b;font-weight:700;font-family:monospace">$<%= format_number(@distribution.p5) %></div></div>
                  <div style="background:#0a0f18;padding:8px;border-radius:4px"><div style="font-size:10px;color:#64748b">P95</div><div style="color:#10b981;font-weight:700;font-family:monospace">$<%= format_number(@distribution.p95) %></div></div>
                </div>

                <%!-- Sensitivity --%>
                <%= if length(@distribution.sensitivity) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px;margin-top:12px">TOP RISK DRIVERS</div>
                  <%= for {key, corr} <- @distribution.sensitivity do %>
                    <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;font-size:12px">
                      <span style="width:120px;color:#94a3b8"><%= sensitivity_label(key) %></span>
                      <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;overflow:hidden">
                        <div style={"width:#{round(abs(corr) * 100)}%;height:100%;border-radius:3px;background:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}></div>
                      </div>
                      <span style={"width:50px;text-align:right;font-family:monospace;font-size:11px;color:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}><%= if corr > 0, do: "+", else: "" %><%= Float.round(corr, 2) %></span>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>

            <%!-- === TIDES & CURRENTS (Trader tab) === --%>
            <%= if @tides_data do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#818cf8;letter-spacing:1px;font-weight:700;margin-bottom:10px">TIDES & CURRENTS</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:10px">
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Water Level</div>
                    <div style="font-size:16px;font-weight:700;color:#60a5fa;font-family:monospace">
                      <%= if @tides_data[:water_level_ft], do: "#{Float.round(@tides_data[:water_level_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Tidal Range</div>
                    <div style="font-size:16px;font-weight:700;color:#818cf8;font-family:monospace">
                      <%= if @tides_data[:tidal_range_ft], do: "#{Float.round(@tides_data[:tidal_range_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Current</div>
                    <div style="font-size:16px;font-weight:700;color:#38bdf8;font-family:monospace">
                      <%= if @tides_data[:current_speed_kn], do: "#{Float.round(@tides_data[:current_speed_kn], 1)}kn", else: "—" %>
                    </div>
                  </div>
                </div>
                <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_high] do %>
                  <div style="font-size:10px;color:#475569;margin-top:4px">
                    Next high: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_high][:time] %></span>
                    (<span style="color:#60a5fa"><%= Float.round(@tides_data[:tidal_predictions][:next_high][:level], 1) %>ft</span>)
                  </div>
                <% end %>
                <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_low] do %>
                  <div style="font-size:10px;color:#475569">
                    Next low: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_low][:time] %></span>
                    (<span style="color:#f59e0b"><%= Float.round(@tides_data[:tidal_predictions][:next_low][:level], 1) %>ft</span>)
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- Saved scenarios --%>
            <%= if length(@saved_scenarios) > 0 do %>
              <div style="background:#111827;border-radius:10px;padding:16px">
                <div style="font-size:11px;color:#64748b;letter-spacing:1px;margin-bottom:8px">SAVED SCENARIOS</div>
                <table style="width:100%;border-collapse:collapse;font-size:12px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:4px;color:#64748b;font-size:11px">Name</th>
                    <th style="text-align:right;padding:4px;color:#64748b;font-size:11px">Profit</th>
                    <th style="text-align:right;padding:4px;color:#64748b;font-size:11px">ROI</th>
                    <th style="text-align:right;padding:4px;color:#64748b;font-size:11px">Tons</th>
                  </tr></thead>
                  <tbody>
                    <%= for sc <- @saved_scenarios do %>
                      <tr phx-click="load_scenario" phx-value-id={sc.id} style="cursor:pointer;border-bottom:1px solid #1e293b11">
                        <td style="padding:6px 4px;font-weight:600"><%= sc.name %></td>
                        <td style="text-align:right;padding:6px 4px;font-family:monospace;color:#10b981">$<%= format_number(sc.result.profit) %></td>
                        <td style="text-align:right;padding:6px 4px;font-family:monospace"><%= Float.round(sc.result.roi, 1) %>%</td>
                        <td style="text-align:right;padding:6px 4px;font-family:monospace"><%= format_number(sc.result.tons) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>

          <%!-- Post-solve impact --%>
            <%= if @post_solve_impact do %>
              <div style="background:#0d1a0d;border:1px solid #166534;border-radius:8px;padding:14px;margin-bottom:16px">
                <div style="font-size:11px;color:#4ade80;font-weight:700;letter-spacing:1px;margin-bottom:8px">POSITION IMPACT</div>
                <%= if @post_solve_impact[:summary] do %>
                  <div style="font-size:12px;color:#c8d6e5;line-height:1.5;margin-bottom:10px"><%= @post_solve_impact[:summary] %></div>
                <% end %>
                <%= if @post_solve_impact[:by_contract] do %>
                  <table style="width:100%;border-collapse:collapse;font-size:11px">
                    <thead><tr style="border-bottom:1px solid #1e293b">
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Counterparty</th>
                      <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:10px">Dir</th>
                      <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Open Qty</th>
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Impact</th>
                    </tr></thead>
                    <tbody>
                      <%= for cp <- @post_solve_impact[:by_contract] do %>
                        <tr style="border-bottom:1px solid #1e293b11">
                          <td style="padding:4px 6px;font-weight:600;color:#e2e8f0"><%= cp[:counterparty] %></td>
                          <td style={"text-align:center;padding:4px 6px;color:#{if cp[:direction] == "purchase", do: "#60a5fa", else: "#f59e0b"};font-size:10px;font-weight:600"}><%= if cp[:direction] == "purchase", do: "BUY", else: "SELL" %></td>
                          <td style="text-align:right;padding:4px 6px;font-family:monospace;color:#c8d6e5"><%= format_number(cp[:open_qty] || 0) %></td>
                          <td style="padding:4px 6px;color:#94a3b8;font-size:10px"><%= cp[:impact] %></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                <% end %>
                <%= if @post_solve_impact[:net_position_after] do %>
                  <div style="margin-top:8px;padding-top:8px;border-top:1px solid #166534;font-size:11px;color:#94a3b8">
                    Net position after: <span style={"font-weight:700;color:#{if @post_solve_impact[:net_position_after] > 0, do: "#4ade80", else: "#f87171"}"}>
                      <%= if @post_solve_impact[:net_position_after] > 0, do: "+", else: "" %><%= format_number(@post_solve_impact[:net_position_after]) %> MT
                    </span>
                  </div>
                <% end %>
              </div>
            <% end %>

          <%!-- Delivery Impact (populated after solve when delivery schedules are loaded) --%>
          <%= if @delivery_impact do %>
            <div style="background:#111827;border-radius:8px;padding:14px;margin-bottom:16px;border:1px solid #1e293b">
              <div style="font-size:10px;font-weight:700;letter-spacing:1.2px;margin-bottom:10px;color:#a78bfa">DELIVERY SCHEDULE IMPACT</div>
              <%= for c <- @delivery_impact.by_customer do %>
                <div style="display:flex;align-items:center;justify-content:space-between;padding:6px 0;border-bottom:1px solid #1e293b33">
                  <div style="display:flex;align-items:center;gap:10px">
                    <span style={"font-size:14px;width:18px;text-align:center;#{delivery_impact_style(c.status)}"}>
                      <%= delivery_impact_icon(c.status) %>
                    </span>
                    <div>
                      <div style={"font-size:11px;font-weight:600;#{delivery_impact_style(c.status)}"}>
                        <%= c.counterparty |> String.split(",") |> List.first() |> String.split(" ") |> Enum.take(2) |> Enum.join(" ") %>
                      </div>
                      <div style="font-size:10px;color:#64748b">
                        <%= format_number(round(c.scheduled_qty_mt)) %> MT
                        · <%= c.frequency %>
                        · <%= if c.next_window_days == 0, do: "window open", else: "opens in #{c.next_window_days}d" %>
                      </div>
                    </div>
                  </div>
                  <div style="text-align:right">
                    <%= if c.penalty_estimate > 0 do %>
                      <div style="font-size:11px;font-weight:700;font-family:monospace;color:#fca5a5">
                        ~$<%= format_number(round(c.penalty_estimate)) %>
                      </div>
                      <div style="font-size:9px;color:#64748b">est. penalty</div>
                    <% else %>
                      <div style="font-size:10px;color:#475569"><%= delivery_impact_note(c.status) %></div>
                    <% end %>
                  </div>
                </div>
              <% end %>
              <%= if @delivery_impact.deferred_count > 0 do %>
                <div style="margin-top:8px;padding-top:8px;border-top:1px solid #a78bfa33;display:flex;justify-content:space-between;font-size:11px">
                  <span style="color:#94a3b8"><%= @delivery_impact.deferred_count %> <%= if @delivery_impact.deferred_count == 1, do: "delivery", else: "deliveries" %> deferred</span>
                  <span style="color:#fdba74;font-weight:700;font-family:monospace">~$<%= format_number(round(@delivery_impact.total_penalty_exposure)) %> exposure</span>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Save & Send to Ops --%>
          <%= if @result do %>
            <div style="margin-bottom:16px">
              <%= if @ops_sent do %>
                <div style="background:#0d1a0d;border:1px solid #166534;border-radius:8px;padding:12px;text-align:center">
                  <div style="font-size:12px;color:#4ade80;font-weight:700">✓ Saved and sent to ops team</div>
                  <div style="font-size:10px;color:#64748b;margin-top:2px">Email queued for ops@trammo.com · Scenario saved</div>
                </div>
              <% else %>
                <button phx-click="save_and_send_ops"
                  style="width:100%;padding:11px;border:1px solid #a78bfa;border-radius:8px;background:#0a0318;color:#c4b5fd;font-weight:700;font-size:12px;cursor:pointer;letter-spacing:0.5px">
                  📋 SAVE SCENARIO &amp; SEND TO OPS
                </button>
                <div style="text-align:center;font-size:10px;color:#475569;margin-top:4px">
                  Saves to database · Emails instructions to ops team for SAP data entry
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- === CONTRACTS TAB === --%>
          <%= if @active_tab == :contracts do %>

            <%!-- Seed Contract Ingestion Panel --%>
            <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                <div>
                  <div style="font-size:10px;color:#a78bfa;letter-spacing:1px;font-weight:700">CONTRACT INGESTION</div>
                  <div style="font-size:10px;color:#475569;margin-top:2px">
                    Seed files in <code style="color:#94a3b8">priv/contracts/seed/</code> — parsed and loaded into the solver
                  </div>
                </div>
                <%= if @seed_ingestion_running do %>
                  <span style="font-size:11px;color:#a78bfa;padding:8px 18px;border:1px solid #a78bfa;border-radius:6px;opacity:0.6">Ingesting…</span>
                <% else %>
                  <button phx-click="ingest_seed_contracts"
                    style="font-size:11px;font-weight:600;color:#111;background:#a78bfa;padding:8px 18px;border:none;border-radius:6px;cursor:pointer">
                    ↻ Refresh Contracts
                  </button>
                <% end %>
              </div>

              <%!-- File list --%>
              <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:4px">
                <thead><tr style="border-bottom:1px solid #1e293b">
                  <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:9px">FILE</th>
                  <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:9px">COUNTERPARTY</th>
                  <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:9px">TYPE</th>
                  <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:9px">OPEN QTY</th>
                  <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:9px">STATUS</th>
                </tr></thead>
                <tbody>
                  <%= for sf <- @seed_files do %>
                    <tr style="border-bottom:1px solid #1e293b22">
                      <td style="padding:4px 6px;font-family:monospace;font-size:9px;color:#64748b"><%= sf.file || sf.prefix %></td>
                      <td style="padding:4px 6px;color:#e2e8f0;font-weight:600"><%= sf.counterparty %></td>
                      <td style={"text-align:center;padding:4px 6px;font-size:9px;font-weight:600;color:#{if sf.counterparty_type == :supplier, do: "#60a5fa", else: "#f59e0b"}"}>
                        <%= if sf.counterparty_type == :supplier, do: "PURCHASE", else: "SALE" %>
                      </td>
                      <td style="text-align:right;padding:4px 6px;font-family:monospace;color:#94a3b8"><%= sf.open_qty |> round() |> Integer.to_string() |> String.replace(~r/(\d{3})(?=\d)/, "\\1,") %> MT</td>
                      <td style="text-align:center;padding:4px 6px">
                        <%= if sf.found do %>
                          <span style="font-size:9px;color:#4ade80">✓ found</span>
                        <% else %>
                          <span style="font-size:9px;color:#f87171">✗ missing</span>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <%!-- Ingestion Result Summary --%>
            <%= if @seed_ingestion_result do %>
              <%!-- assign a local for convenience --%>
              <% r = @seed_ingestion_result %>
              <div style="background:#0a130a;border:1px solid #166534;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#4ade80;letter-spacing:1px;font-weight:700;margin-bottom:10px">
                  INGESTION COMPLETE — <%= r.loaded %> contracts loaded, <%= r.errors %> errors
                </div>
                <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px">
                  <div style="background:#0a1f0a;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Contracts</div>
                    <div style="font-size:20px;font-weight:800;color:#4ade80;font-family:monospace"><%= r.loaded %></div>
                  </div>
                  <div style="background:#0a1f0a;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Total Clauses</div>
                    <div style="font-size:20px;font-weight:800;color:#34d399;font-family:monospace"><%= r.total_clauses %></div>
                  </div>
                  <div style="background:#0a1f0a;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Penalty Clauses</div>
                    <div style="font-size:20px;font-weight:800;color:#fb923c;font-family:monospace"><%= r.total_penalty_clauses %></div>
                  </div>
                  <div style="background:#0a1f0a;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Net Position</div>
                    <div style={"font-size:16px;font-weight:800;font-family:monospace;color:#{if r.net_position > 0, do: "#4ade80", else: "#f87171"}"}>
                      <%= if r.net_position > 0, do: "+", else: "" %><%= format_number(r.net_position / 1) %> MT
                    </div>
                  </div>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:10px">
                  <thead><tr style="border-bottom:1px solid #166534">
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:9px">COUNTERPARTY</th>
                    <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:9px">TYPE</th>
                    <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:9px">INCOTERM</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:9px">OPEN MT</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:9px">CLAUSES</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:9px">PENALTIES</th>
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:9px">FILE</th>
                  </tr></thead>
                  <tbody>
                    <%= for c <- r.contracts do %>
                      <tr style="border-bottom:1px solid #1e293b22">
                        <td style="padding:4px 6px;color:#e2e8f0;font-weight:600"><%= c.counterparty %></td>
                        <td style={"text-align:center;padding:4px 6px;font-size:9px;font-weight:600;color:#{if c.counterparty_type == :supplier, do: "#60a5fa", else: "#f59e0b"}"}>
                          <%= if c.counterparty_type == :supplier, do: "BUY", else: "SELL" %>
                        </td>
                        <td style="text-align:center;padding:4px 6px;color:#94a3b8"><%= c.incoterm |> to_string() |> String.upcase() %></td>
                        <td style="text-align:right;padding:4px 6px;font-family:monospace;color:#e2e8f0"><%= format_number(c.open_qty / 1) %></td>
                        <td style="text-align:right;padding:4px 6px;font-family:monospace;color:#94a3b8"><%= c.clauses %></td>
                        <td style={"text-align:right;padding:4px 6px;font-family:monospace;color:#{if c.penalties > 0, do: "#fb923c", else: "#475569"}"}><%= c.penalties %></td>
                        <td style="padding:4px 6px;font-size:9px;color:#475569;font-family:monospace"><%= c.file %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- Ammonia Price Board --%>
            <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
              <div style="font-size:10px;color:#a78bfa;letter-spacing:1px;font-weight:700;margin-bottom:10px">AMMONIA BENCHMARK PRICES</div>
              <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:8px">
                <%= for p <- @ammonia_prices do %>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b"><%= p.label %></div>
                    <div style={"font-size:16px;font-weight:700;font-family:monospace;color:#{if p.direction == :buy, do: "#60a5fa", else: "#f59e0b"};"}>$<%= round(p.price) %></div>
                    <div style="font-size:8px;color:#475569"><%= p.source %></div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Open Book Summary --%>
            <%= if @contracts_data do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                  <span style="font-size:10px;color:#a78bfa;letter-spacing:1px;font-weight:700">OPEN BOOK</span>
                  <span style={"font-size:12px;font-weight:700;font-family:monospace;color:#{if @contracts_data.net_position > 0, do: "#4ade80", else: "#f87171"}"}>
                    NET: <%= if @contracts_data.net_position > 0, do: "+", else: "" %><%= format_number(@contracts_data.net_position) %> MT
                  </span>
                </div>
                <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:16px">
                  <div style="background:#0a1628;padding:12px;border-radius:8px;border-left:3px solid #60a5fa">
                    <div style="font-size:10px;color:#64748b">Purchase Open</div>
                    <div style="font-size:22px;font-weight:800;color:#60a5fa;font-family:monospace"><%= format_number(@contracts_data.total_purchase_open) %> MT</div>
                    <div style="font-size:10px;color:#475569"><%= length(Enum.filter(@contracts_data.contracts, & &1.direction == :purchase)) %> contracts</div>
                  </div>
                  <div style="background:#1a1400;padding:12px;border-radius:8px;border-left:3px solid #f59e0b">
                    <div style="font-size:10px;color:#64748b">Sale Open</div>
                    <div style="font-size:22px;font-weight:800;color:#f59e0b;font-family:monospace"><%= format_number(@contracts_data.total_sale_open) %> MT</div>
                    <div style="font-size:10px;color:#475569"><%= length(Enum.filter(@contracts_data.contracts, & &1.direction == :sale)) %> contracts</div>
                  </div>
                </div>

                <%!-- Contract Detail Table --%>
                <table style="width:100%;border-collapse:collapse;font-size:11px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px;color:#64748b;font-size:10px">Counterparty</th>
                    <th style="text-align:center;padding:6px;color:#64748b;font-size:10px">Dir</th>
                    <th style="text-align:center;padding:6px;color:#64748b;font-size:10px">Incoterm</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:10px">Total</th>
                    <th style="text-align:right;padding:6px;color:#64748b;font-size:10px">Open</th>
                    <th style="text-align:center;padding:6px;color:#64748b;font-size:10px">Progress</th>
                    <th style="text-align:left;padding:6px;color:#64748b;font-size:10px">Penalties</th>
                  </tr></thead>
                  <tbody>
                    <%= for c <- @contracts_data.contracts do %>
                      <tr style="border-bottom:1px solid #1e293b11">
                        <td style="padding:6px">
                          <div style="font-weight:600;color:#e2e8f0"><%= c.counterparty %></div>
                          <div style="font-size:9px;color:#475569"><%= c.contract_number %></div>
                        </td>
                        <td style={"text-align:center;padding:6px;font-weight:600;color:#{if c.direction == :purchase, do: "#60a5fa", else: "#f59e0b"}"}><%= if c.direction == :purchase, do: "BUY", else: "SELL" %></td>
                        <td style="text-align:center;padding:6px;color:#94a3b8;font-weight:600"><%= c.incoterm |> to_string() |> String.upcase() %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#94a3b8"><%= format_number(c.total_qty) %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#e2e8f0;font-weight:700"><%= format_number(c.open_qty) %></td>
                        <td style="padding:6px">
                          <div style="display:flex;align-items:center;gap:4px">
                            <div style="flex:1;height:4px;background:#1e293b;border-radius:2px;overflow:hidden">
                              <div style={"width:#{c.pct_complete}%;height:100%;background:#{if c.pct_complete > 50, do: "#10b981", else: "#38bdf8"};border-radius:2px"}></div>
                            </div>
                            <span style="font-size:9px;color:#64748b;width:28px;text-align:right"><%= c.pct_complete %>%</span>
                          </div>
                        </td>
                        <td style="padding:6px">
                          <%= for p <- c.penalties do %>
                            <div style="font-size:9px;padding:1px 0">
                              <span style="color:#fca5a5"><%= p.type %></span>
                              <span style="color:#64748b"> — </span>
                              <span style="color:#f59e0b;font-family:monospace"><%= p.rate %></span>
                            </div>
                          <% end %>
                          <%= if length(c.penalties) == 0 do %>
                            <span style="font-size:9px;color:#475569">—</span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>

          <%!-- === MAP TAB === --%>
          <%= if @active_tab == :map do %>
            <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
              <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700;margin-bottom:8px">ROUTE MAP</div>
              <div id={"map-tab-#{@product_group}"} phx-hook="VesselMap" phx-update="ignore"
                data-mapdata={map_data_json(@product_group, @frame, @result, @vessel_data)}
                style="height:450px;border-radius:8px;background:#0a0f18"></div>
            </div>

            <%!-- Fleet Tracking --%>
            <%= if @vessel_data && @vessel_data[:vessels] && length(@vessel_data[:vessels]) > 0 do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
                  <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700">FLEET TRACKING</div>
                  <div style="font-size:10px;color:#475569">
                    <%= if @vessel_data[:fleet_summary] do %>
                      <%= @vessel_data[:fleet_summary][:total_vessels] %> vessels
                      — <%= @vessel_data[:fleet_summary][:underway] || 0 %> underway
                    <% end %>
                  </div>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:11px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Vessel</th>
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Near</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Mile</th>
                    <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Speed</th>
                    <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:10px">Dir</th>
                    <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Status</th>
                  </tr></thead>
                  <tbody>
                    <%= for vessel <- @vessel_data[:vessels] do %>
                      <tr style="border-bottom:1px solid #1e293b11">
                        <td style="padding:5px 6px;font-weight:600;color:#e2e8f0;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= vessel[:name] || "Unknown" %></td>
                        <td style="padding:5px 6px;color:#94a3b8"><%= vessel[:nearest_waypoint] || "—" %></td>
                        <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#38bdf8"><%= vessel[:river_mile] || "—" %></td>
                        <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#c8d6e5"><%= if vessel[:speed], do: "#{Float.round(vessel[:speed], 1)}kn", else: "—" %></td>
                        <td style="text-align:center;padding:5px 6px"><%= vessel_status_icon(vessel[:direction]) %></td>
                        <td style={"padding:5px 6px;color:#{vessel_status_color(vessel[:status])};font-size:10px;font-weight:600"}><%= vessel_status_text(vessel[:status]) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- Tides & Currents on Map tab --%>
            <%= if @tides_data do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#818cf8;letter-spacing:1px;font-weight:700;margin-bottom:10px">TIDES & CURRENTS</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px">
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Water Level</div>
                    <div style="font-size:16px;font-weight:700;color:#60a5fa;font-family:monospace">
                      <%= if @tides_data[:water_level_ft], do: "#{Float.round(@tides_data[:water_level_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Tidal Range</div>
                    <div style="font-size:16px;font-weight:700;color:#818cf8;font-family:monospace">
                      <%= if @tides_data[:tidal_range_ft], do: "#{Float.round(@tides_data[:tidal_range_ft], 1)}ft", else: "—" %>
                    </div>
                  </div>
                  <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                    <div style="font-size:9px;color:#64748b">Current</div>
                    <div style="font-size:16px;font-weight:700;color:#38bdf8;font-family:monospace">
                      <%= if @tides_data[:current_speed_kn], do: "#{Float.round(@tides_data[:current_speed_kn], 1)}kn", else: "—" %>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>

          <%!-- === AGENT TAB === --%>
          <%= if @active_tab == :agent do %>
            <%= if @auto_result do %>
              <%!-- Agent header --%>
              <div style="background:#111827;border-radius:10px;padding:20px;margin-bottom:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
                  <div style="display:flex;align-items:center;gap:10px">
                    <div style={"width:10px;height:10px;border-radius:50%;background:#{signal_color(@auto_result.distribution.signal)};box-shadow:0 0 10px #{signal_color(@auto_result.distribution.signal)}"}></div>
                    <span style="font-size:16px;font-weight:700;color:#e2e8f0">AGENT MODE</span>
                  </div>
                  <span style="font-size:11px;color:#475569">
                    Last run: <%= Calendar.strftime(@auto_result.timestamp, "%H:%M:%S") %>
                  </span>
                </div>

                <%!-- Signal + key metrics --%>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;margin-bottom:16px">
                  <div style="background:#0a0f18;padding:12px;border-radius:8px;text-align:center">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px">SIGNAL</div>
                    <div style={"font-size:20px;font-weight:800;color:#{signal_color(@auto_result.distribution.signal)}"}><%= signal_text(@auto_result.distribution.signal) %></div>
                  </div>
                  <div style="background:#0a0f18;padding:12px;border-radius:8px;text-align:center">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px">EXPECTED VALUE</div>
                    <div style="font-size:20px;font-weight:800;color:#10b981;font-family:monospace">$<%= format_number(@auto_result.distribution.mean) %></div>
                  </div>
                  <div style="background:#0a0f18;padding:12px;border-radius:8px;text-align:center">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px">VALUE AT RISK</div>
                    <div style="font-size:20px;font-weight:800;color:#f59e0b;font-family:monospace">$<%= format_number(@auto_result.distribution.p5) %></div>
                  </div>
                </div>

                <%!-- Current live values --%>
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">CURRENT LIVE VALUES</div>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin-bottom:16px;font-size:12px">
                  <span>🌊 River: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :river_stage, 0.0), 1) %>ft</span></span>
                  <span>🌡 Temp: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :temp_f, 0.0), 0) %>°F</span></span>
                  <span>⛽ Gas: <span style="color:#38bdf8;font-weight:600">$<%= Float.round(Map.get(@auto_result.center, :nat_gas, 0.0), 2) %></span></span>
                  <span>🔒 Lock: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :lock_hrs, 0.0), 0) %>hrs</span></span>
                  <span>💨 Wind: <span style="color:#38bdf8;font-weight:600"><%= Float.round(Map.get(@auto_result.center, :wind_mph, 0.0), 0) %>mph</span></span>
                  <span>🏭 StL: <span style={"font-weight:600;color:#{if Map.get(@auto_result.center, :stl_outage), do: "#ef4444", else: "#10b981"}"}><%= if Map.get(@auto_result.center, :stl_outage), do: "OUTAGE", else: "ONLINE" %></span></span>
                </div>

                <%!-- What triggered this run --%>
                <%= if Map.has_key?(@auto_result, :triggers) and length(@auto_result.triggers) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">TRIGGERED BY</div>
                  <%= for trigger <- @auto_result.triggers do %>
                    <div style="display:flex;align-items:center;gap:8px;padding:4px 0;font-size:12px">
                      <div style="width:6px;height:6px;border-radius:50%;background:#f59e0b"></div>
                      <span style="color:#e2e8f0"><%= format_trigger(trigger) %></span>
                    </div>
                  <% end %>
                <% end %>
              </div>

              <%!-- Agent AI explanation --%>
              <%= if @auto_result[:explanation] do %>
                <div style="background:#0f1729;border:1px solid #1e293b;border-radius:8px;padding:12px;margin-top:12px;margin-bottom:16px">
                  <div style="font-size:11px;color:#8b5cf6;font-weight:700;letter-spacing:1px;margin-bottom:6px">🧠 AGENT ANALYSIS</div>
                  <div style="font-size:13px;color:#c8d6e5;line-height:1.5"><%= @auto_result.explanation %></div>
                </div>
              <% end %>

              <%!-- Distribution --%>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:10px">PROFIT DISTRIBUTION — <%= @auto_result.distribution.n_feasible %>/<%= @auto_result.distribution.n_scenarios %> feasible</div>
                <%= for {label, val, color} <- [{"P95", @auto_result.distribution.p95, "#10b981"}, {"P75", @auto_result.distribution.p75, "#34d399"}, {"Mean", @auto_result.distribution.mean, "#38bdf8"}, {"P50", @auto_result.distribution.p50, "#38bdf8"}, {"P25", @auto_result.distribution.p25, "#f59e0b"}, {"VaR₅", @auto_result.distribution.p5, "#ef4444"}] do %>
                  <div style="display:flex;align-items:center;gap:8px;font-size:12px;margin-bottom:5px">
                    <span style="width:40px;color:#64748b;text-align:right"><%= label %></span>
                    <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;overflow:hidden">
                      <div style={"width:#{if @auto_result.distribution.p95 > 0, do: round(val / @auto_result.distribution.p95 * 100), else: 0}%;height:100%;background:#{color};border-radius:3px"}></div>
                    </div>
                    <span style={"width:70px;font-family:monospace;color:#{color};font-weight:600;text-align:right;font-size:11px"}>$<%= format_number(val) %></span>
                  </div>
                <% end %>
              </div>

              <%!-- Sensitivity --%>
              <%= if length(@auto_result.distribution.sensitivity) > 0 do %>
                <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">TOP RISK DRIVERS</div>
                  <%= for {key, corr} <- @auto_result.distribution.sensitivity do %>
                    <div style="display:flex;align-items:center;gap:8px;margin-bottom:5px;font-size:12px">
                      <span style="width:120px;color:#94a3b8"><%= sensitivity_label(key) %></span>
                      <div style="flex:1;height:6px;background:#1e293b;border-radius:3px;overflow:hidden">
                        <div style={"width:#{round(abs(corr) * 100)}%;height:100%;border-radius:3px;background:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}></div>
                      </div>
                      <span style={"width:50px;text-align:right;font-family:monospace;font-size:11px;color:#{if corr > 0, do: "#10b981", else: "#ef4444"}"}><%= if corr > 0, do: "+", else: "" %><%= Float.round(corr, 2) %></span>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- History --%>
              <%= if length(@agent_history) > 0 do %>
                <div style="background:#111827;border-radius:10px;padding:16px">
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">RUN HISTORY</div>
                  <%= for entry <- @agent_history do %>
                    <div style="display:flex;align-items:center;gap:10px;padding:5px 0;border-bottom:1px solid #1e293b11;font-size:12px">
                      <span style="color:#475569;width:50px"><%= Calendar.strftime(entry.timestamp, "%H:%M") %></span>
                      <span style={"font-weight:700;width:60px;color:#{signal_color(entry.distribution.signal)}"}><%= signal_text(entry.distribution.signal) %></span>
                      <span style="font-family:monospace;color:#e2e8f0;width:80px">$<%= format_number(entry.distribution.mean) %></span>
                      <span style="color:#475569;flex:1;font-size:11px">
                        <%= Enum.map(entry.triggers, &trigger_label(&1.key)) |> Enum.join(", ") %>
                      </span>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- === AGENT ROUTE MAP === --%>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700;margin-bottom:8px">ROUTE MAP</div>
                <div id={"agent-map-#{@product_group}"} phx-hook="VesselMap" phx-update="ignore"
                  data-mapdata={map_data_json(@product_group, @frame, nil, @vessel_data)}
                  style="height:280px;border-radius:8px;background:#0a0f18"></div>
              </div>

              <%!-- === FLEET TRACKING === --%>
              <%= if @vessel_data && @vessel_data[:vessels] && length(@vessel_data[:vessels]) > 0 do %>
                <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px">
                    <div style="font-size:10px;color:#60a5fa;letter-spacing:1px;font-weight:700">FLEET TRACKING</div>
                    <div style="font-size:10px;color:#475569">
                      <%= if @vessel_data[:fleet_summary] do %>
                        <%= @vessel_data[:fleet_summary][:total_vessels] %> vessels
                        — <%= @vessel_data[:fleet_summary][:underway] || 0 %> underway
                      <% end %>
                    </div>
                  </div>
                  <table style="width:100%;border-collapse:collapse;font-size:11px">
                    <thead><tr style="border-bottom:1px solid #1e293b">
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Vessel</th>
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Near</th>
                      <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Mile</th>
                      <th style="text-align:right;padding:4px 6px;color:#64748b;font-size:10px">Speed</th>
                      <th style="text-align:center;padding:4px 6px;color:#64748b;font-size:10px">Dir</th>
                      <th style="text-align:left;padding:4px 6px;color:#64748b;font-size:10px">Status</th>
                    </tr></thead>
                    <tbody>
                      <%= for vessel <- @vessel_data[:vessels] do %>
                        <tr style="border-bottom:1px solid #1e293b11">
                          <td style="padding:5px 6px;font-weight:600;color:#e2e8f0;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><%= vessel[:name] || "Unknown" %></td>
                          <td style="padding:5px 6px;color:#94a3b8"><%= vessel[:nearest_waypoint] || "—" %></td>
                          <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#38bdf8"><%= vessel[:river_mile] || "—" %></td>
                          <td style="text-align:right;padding:5px 6px;font-family:monospace;color:#c8d6e5"><%= if vessel[:speed], do: "#{Float.round(vessel[:speed], 1)}kn", else: "—" %></td>
                          <td style="text-align:center;padding:5px 6px"><%= vessel_status_icon(vessel[:direction]) %></td>
                          <td style={"padding:5px 6px;color:#{vessel_status_color(vessel[:status])};font-size:10px;font-weight:600"}><%= vessel_status_text(vessel[:status]) %></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                  <%!-- Fleet weather from vessel positions --%>
                  <%= if @vessel_data[:fleet_weather] && @vessel_data[:fleet_weather][:source] == :fleet_aggregate do %>
                    <div style="margin-top:10px;padding-top:8px;border-top:1px solid #1e293b">
                      <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:4px">FLEET WEATHER (worst-case across positions)</div>
                      <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:6px;font-size:11px">
                        <%= if @vessel_data[:fleet_weather][:wind_mph] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Wind</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:wind_mph], 0) %> mph</div>
                          </div>
                        <% end %>
                        <%= if @vessel_data[:fleet_weather][:vis_mi] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Visibility</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:vis_mi], 1) %> mi</div>
                          </div>
                        <% end %>
                        <%= if @vessel_data[:fleet_weather][:temp_f] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Temp</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:temp_f], 0) %>°F</div>
                          </div>
                        <% end %>
                        <%= if @vessel_data[:fleet_weather][:precip_in] do %>
                          <div style="background:#0a0f18;padding:6px;border-radius:4px">
                            <div style="font-size:9px;color:#64748b">Precip</div>
                            <div style="font-weight:700;color:#38bdf8;font-family:monospace"><%= Float.round(@vessel_data[:fleet_weather][:precip_in], 1) %> in</div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <%!-- === TIDES & CURRENTS === --%>
              <%= if @tides_data do %>
                <div style="background:#111827;border-radius:10px;padding:16px;margin-bottom:16px">
                  <div style="font-size:10px;color:#818cf8;letter-spacing:1px;font-weight:700;margin-bottom:10px">TIDES & CURRENTS</div>
                  <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:10px">
                    <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Water Level</div>
                      <div style="font-size:16px;font-weight:700;color:#60a5fa;font-family:monospace">
                        <%= if @tides_data[:water_level_ft], do: "#{Float.round(@tides_data[:water_level_ft], 1)}ft", else: "—" %>
                      </div>
                      <div style="font-size:9px;color:#475569">Pilottown</div>
                    </div>
                    <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Tidal Range</div>
                      <div style="font-size:16px;font-weight:700;color:#818cf8;font-family:monospace">
                        <%= if @tides_data[:tidal_range_ft], do: "#{Float.round(@tides_data[:tidal_range_ft], 1)}ft", else: "—" %>
                      </div>
                      <div style="font-size:9px;color:#475569">24h predicted</div>
                    </div>
                    <div style="background:#0a0f18;padding:8px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Current</div>
                      <div style="font-size:16px;font-weight:700;color:#38bdf8;font-family:monospace">
                        <%= if @tides_data[:current_speed_kn], do: "#{Float.round(@tides_data[:current_speed_kn], 1)}kn", else: "—" %>
                      </div>
                      <div style="font-size:9px;color:#475569">SW Pass</div>
                    </div>
                  </div>
                  <%= if @tides_data[:nola_water_level_ft] do %>
                    <div style="font-size:11px;color:#94a3b8;margin-bottom:4px">
                      NOLA (New Canal): <span style="color:#60a5fa;font-weight:600;font-family:monospace"><%= Float.round(@tides_data[:nola_water_level_ft], 1) %>ft</span>
                    </div>
                  <% end %>
                  <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_high] do %>
                    <div style="font-size:10px;color:#475569;margin-top:4px">
                      Next high: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_high][:time] %></span>
                      (<span style="color:#60a5fa"><%= Float.round(@tides_data[:tidal_predictions][:next_high][:level], 1) %>ft</span>)
                    </div>
                  <% end %>
                  <%= if @tides_data[:tidal_predictions] && @tides_data[:tidal_predictions][:next_low] do %>
                    <div style="font-size:10px;color:#475569">
                      Next low: <span style="color:#94a3b8"><%= @tides_data[:tidal_predictions][:next_low][:time] %></span>
                      (<span style="color:#f59e0b"><%= Float.round(@tides_data[:tidal_predictions][:next_low][:level], 1) %>ft</span>)
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% else %>
              <div style="background:#111827;border-radius:10px;padding:40px;text-align:center;color:#475569">
                Agent is initializing...
              </div>
            <% end %>
          <% end %>

          <%!-- ═══════ APIs TAB ═══════ --%>
          <%= if @active_tab == :apis do %>
            <div style="background:#111827;border-radius:10px;padding:16px">
              <div style="font-size:12px;font-weight:700;color:#f97316;letter-spacing:1px;margin-bottom:12px">
                API DATA SOURCES
              </div>

              <%!-- Data Polling APIs --%>
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">LIVE DATA FEEDS</div>
              <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:16px">
                <thead>
                  <tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Source</th>
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Status</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Last Called</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Interval</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for api <- @api_status.poller_sources do %>
                    <tr style="border-bottom:1px solid #0f172a">
                      <td style="padding:6px 8px;color:#e2e8f0;font-weight:500"><%= api.label %></td>
                      <td style="padding:6px 8px">
                        <span style={"display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#{if api.status == :ok, do: "#10b981", else: "#ef4444"}"}>
                          <span style={"width:6px;height:6px;border-radius:50%;background:#{if api.status == :ok, do: "#10b981", else: "#ef4444"}"}></span>
                          <%= if api.status == :ok, do: "OK", else: "ERROR" %>
                        </span>
                        <%= if api.error do %>
                          <span style="color:#ef4444;font-size:9px;margin-left:4px">(<%= inspect(api.error) %>)</span>
                        <% end %>
                      </td>
                      <td style="padding:6px 8px;text-align:right;color:#94a3b8;font-family:monospace;font-size:10px">
                        <%= format_api_timestamp(api.last_poll_at) %>
                      </td>
                      <td style="padding:6px 8px;text-align:right;color:#64748b;font-family:monospace;font-size:10px">
                        <%= format_interval(api.interval_ms) %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>

              <%!-- SAP Integration --%>
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">SAP S/4HANA OData</div>
              <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:16px">
                <thead>
                  <tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Endpoint</th>
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Status</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Last Called</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Interval</th>
                  </tr>
                </thead>
                <tbody>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Position Refresh (GET)</td>
                    <td style="padding:6px 8px">
                      <span style={"display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#{if @api_status.sap.sap_connected, do: "#10b981", else: "#f59e0b"}"}>
                        <span style={"width:6px;height:6px;border-radius:50%;background:#{if @api_status.sap.sap_connected, do: "#10b981", else: "#f59e0b"}"}></span>
                        <%= if @api_status.sap.sap_connected, do: "CONNECTED", else: "STUB" %>
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#94a3b8;font-family:monospace;font-size:10px">
                      <%= format_api_timestamp(@api_status.sap.last_refresh_at) %>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#64748b;font-family:monospace;font-size:10px">
                      <%= format_interval(@api_status.sap.refresh_interval_ms) %>
                    </td>
                  </tr>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Create Contract (POST)</td>
                    <td style="padding:6px 8px">
                      <span style="display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#f59e0b">
                        <span style="width:6px;height:6px;border-radius:50%;background:#f59e0b"></span>
                        STUB
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#475569;font-family:monospace;font-size:10px">—</td>
                    <td style="padding:6px 8px;text-align:right;color:#475569;font-family:monospace;font-size:10px">on demand</td>
                  </tr>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Create Delivery (POST)</td>
                    <td style="padding:6px 8px">
                      <span style="display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#f59e0b">
                        <span style="width:6px;height:6px;border-radius:50%;background:#f59e0b"></span>
                        STUB
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#475569;font-family:monospace;font-size:10px">—</td>
                    <td style="padding:6px 8px;text-align:right;color:#475569;font-family:monospace;font-size:10px">on demand</td>
                  </tr>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Webhook Ping (POST /api/sap/ping)</td>
                    <td style="padding:6px 8px">
                      <span style="display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#10b981">
                        <span style="width:6px;height:6px;border-radius:50%;background:#10b981"></span>
                        READY
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#475569;font-family:monospace;font-size:10px">—</td>
                    <td style="padding:6px 8px;text-align:right;color:#475569;font-family:monospace;font-size:10px">SAP push</td>
                  </tr>
                </tbody>
              </table>

              <%!-- Ammonia Pricing --%>
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">AMMONIA PRICING</div>
              <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:16px">
                <thead>
                  <tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Source</th>
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Status</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Last Updated</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Interval</th>
                  </tr>
                </thead>
                <tbody>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Fertecon/FMB Benchmarks</td>
                    <td style="padding:6px 8px">
                      <span style="display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#10b981">
                        <span style="width:6px;height:6px;border-radius:50%;background:#10b981"></span>
                        SEEDED
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#94a3b8;font-family:monospace;font-size:10px">
                      <%= format_api_timestamp(@api_status.prices_updated_at) %>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#64748b;font-family:monospace;font-size:10px">15m</td>
                  </tr>
                </tbody>
              </table>

              <%!-- Claude API --%>
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">AI / LLM</div>
              <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:16px">
                <thead>
                  <tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Service</th>
                    <th style="text-align:left;padding:6px 8px;color:#64748b;font-weight:600">Status</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Model</th>
                    <th style="text-align:right;padding:6px 8px;color:#64748b;font-weight:600">Usage</th>
                  </tr>
                </thead>
                <tbody>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Analyst (Explanations)</td>
                    <td style="padding:6px 8px">
                      <span style={"display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#{if @api_status.claude_configured, do: "#10b981", else: "#ef4444"}"}>
                        <span style={"width:6px;height:6px;border-radius:50%;background:#{if @api_status.claude_configured, do: "#10b981", else: "#ef4444"}"}></span>
                        <%= if @api_status.claude_configured, do: "CONFIGURED", else: "NO API KEY" %>
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#94a3b8;font-family:monospace;font-size:10px">claude-sonnet-4-5</td>
                    <td style="padding:6px 8px;text-align:right;color:#64748b;font-family:monospace;font-size:10px">on solve</td>
                  </tr>
                  <tr style="border-bottom:1px solid #0f172a">
                    <td style="padding:6px 8px;color:#e2e8f0;font-weight:500">Intent Mapper</td>
                    <td style="padding:6px 8px">
                      <span style={"display:inline-flex;align-items:center;gap:4px;font-size:10px;font-weight:600;color:#{if @api_status.claude_configured, do: "#10b981", else: "#ef4444"}"}>
                        <span style={"width:6px;height:6px;border-radius:50%;background:#{if @api_status.claude_configured, do: "#10b981", else: "#ef4444"}"}></span>
                        <%= if @api_status.claude_configured, do: "CONFIGURED", else: "NO API KEY" %>
                      </span>
                    </td>
                    <td style="padding:6px 8px;text-align:right;color:#94a3b8;font-family:monospace;font-size:10px">claude-sonnet-4-5</td>
                    <td style="padding:6px 8px;text-align:right;color:#64748b;font-family:monospace;font-size:10px">on action</td>
                  </tr>
                </tbody>
              </table>

              <%!-- Auto-Solve Thresholds --%>
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:8px">AUTO-SOLVE DELTA THRESHOLDS</div>
              <div style="font-size:10px;color:#475569;margin-bottom:8px">
                Auto-runner triggers a new Monte Carlo when |current - baseline| exceeds threshold.
                Cooldown: <span style="color:#94a3b8;font-weight:600"><%= format_interval(@api_status.delta_config.min_solve_interval_ms) %></span>
                &middot; Scenarios: <span style="color:#94a3b8;font-weight:600"><%= @api_status.delta_config.n_scenarios %></span>
                &middot; Status: <span style={"color:#{if @api_status.delta_config.enabled, do: "#10b981", else: "#ef4444"};font-weight:600"}><%= if @api_status.delta_config.enabled, do: "ENABLED", else: "DISABLED" %></span>
              </div>
              <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:4px;margin-bottom:16px">
                <%= for {key, threshold} <- Enum.sort_by(@api_status.delta_config.thresholds, fn {k, _} -> to_string(k) end) do %>
                  <div style="background:#0a0f18;padding:6px 8px;border-radius:4px;display:flex;justify-content:space-between;align-items:center">
                    <span style="font-size:10px;color:#94a3b8"><%= format_threshold_key(key) %></span>
                    <span style="font-size:10px;font-family:monospace;color:#f59e0b;font-weight:600"><%= format_threshold_value(key, threshold) %></span>
                  </div>
                <% end %>
              </div>

              <%!-- Summary --%>
              <div style="display:flex;gap:16px;padding:12px;background:#0a0f18;border-radius:8px;font-size:11px">
                <div>
                  <span style="color:#64748b">Total sources:</span>
                  <span style="color:#e2e8f0;font-weight:600;margin-left:4px"><%= length(@api_status.poller_sources) + 4 %></span>
                </div>
                <div>
                  <span style="color:#64748b">SAP refreshes:</span>
                  <span style="color:#f97316;font-weight:600;margin-left:4px"><%= @api_status.sap.refresh_count %></span>
                </div>
                <div>
                  <span style="color:#64748b">Errors:</span>
                  <span style={"color:#{if @api_status.error_count > 0, do: "#ef4444", else: "#10b981"};font-weight:600;margin-left:4px"}><%= @api_status.error_count %></span>
                </div>
              </div>
            </div>
          <% end %>

          <%!-- ═══════ FLEET TAB ═══════ --%>
          <%= if @active_tab == :fleet do %>
            <div style="background:#111827;border-radius:10px;padding:16px">
              <%!-- Header --%>
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                <div style="font-size:12px;font-weight:700;color:#22d3ee;letter-spacing:1px">FLEET MANAGEMENT</div>
                <div style="font-size:10px;color:#475569"><%= length(@fleet_vessels) %> vessel<%= if length(@fleet_vessels) != 1, do: "s" %></div>
              </div>

              <%!-- Product group filter — defaults to user's product group --%>
              <div style="display:flex;align-items:center;gap:8px;margin-bottom:16px;padding:10px 12px;background:#0a0f18;border-radius:8px">
                <span style="font-size:10px;color:#64748b;font-weight:600">PRODUCT GROUP</span>
                <div style="display:flex;gap:2px">
                  <%= for {pg, label} <- [{"ammonia_domestic", "NH3 Domestic"}, {"ammonia_international", "NH3 Intl"}, {"sulphur_international", "Sulphur"}, {"petcoke", "Petcoke"}, {"all", "All"}] do %>
                    <button phx-click="fleet_filter_pg" phx-value-pg={pg}
                      style={"font-size:10px;font-weight:600;padding:4px 10px;border:none;border-radius:4px;cursor:pointer;#{if @fleet_pg_filter == pg, do: "background:#22d3ee;color:#0a0f18;", else: "background:#1e293b;color:#64748b;"}"}>
                      <%= label %>
                    </button>
                  <% end %>
                </div>
              </div>

              <%!-- Vessel table --%>
              <table style="width:100%;border-collapse:collapse;font-size:11px;margin-bottom:16px">
                <thead>
                  <tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:center;padding:5px 6px;color:#64748b;font-weight:600;width:50px">Track</th>
                    <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Vessel</th>
                    <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">MMSI</th>
                    <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">SAP Ship#</th>
                    <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Cargo</th>
                    <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Route</th>
                    <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">ETA</th>
                    <th style="text-align:center;padding:5px 6px;color:#64748b;font-weight:600;width:40px"></th>
                  </tr>
                </thead>
                <tbody>
                  <%= if length(@fleet_vessels) == 0 do %>
                    <tr>
                      <td colspan="8" style="padding:24px;text-align:center;color:#475569;font-size:12px">
                        No vessels registered for this product group yet. Add one below.
                      </td>
                    </tr>
                  <% end %>
                  <%= for v <- @fleet_vessels do %>
                    <tr style={"border-bottom:1px solid #0f172a;#{if v.status in ["discharged", "cancelled"], do: "opacity:0.4;", else: ""}"}>
                      <td style="padding:5px 6px;text-align:center">
                        <button phx-click="fleet_toggle_tracking" phx-value-id={v.id}
                          style={"width:28px;height:16px;border-radius:8px;border:none;cursor:pointer;position:relative;#{if v.status in ["active", "in_transit"], do: "background:#22d3ee;", else: "background:#334155;"}"}>
                          <span style={"display:block;width:12px;height:12px;border-radius:50%;background:#fff;position:absolute;top:2px;transition:left 0.15s;#{if v.status in ["active", "in_transit"], do: "left:14px;", else: "left:2px;"}"}></span>
                        </button>
                      </td>
                      <td style="padding:5px 8px;color:#e2e8f0;font-weight:500"><%= v.vessel_name %></td>
                      <td style="padding:5px 8px;color:#94a3b8;font-family:monospace;font-size:10px"><%= v.mmsi || "—" %></td>
                      <td style="padding:5px 8px;color:#94a3b8;font-size:10px"><%= v.sap_shipping_number || "—" %></td>
                      <td style="padding:5px 8px;color:#94a3b8"><%= v.cargo || "—" %></td>
                      <td style="padding:5px 8px;color:#94a3b8;font-size:10px">
                        <%= if v.loading_port || v.discharge_port do %>
                          <%= v.loading_port || "?" %> → <%= v.discharge_port || "?" %>
                        <% else %>
                          —
                        <% end %>
                      </td>
                      <td style="padding:5px 8px;text-align:right;color:#94a3b8;font-family:monospace;font-size:10px"><%= if v.eta, do: v.eta, else: "—" %></td>
                      <td style="padding:5px 6px;text-align:center">
                        <button phx-click="fleet_delete_vessel" phx-value-id={v.id}
                          data-confirm="Remove this vessel from tracking?"
                          style="background:none;border:none;color:#475569;cursor:pointer;font-size:12px;padding:2px 4px">
                          &times;
                        </button>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>

              <%!-- Add vessel form --%>
              <div style="border-top:1px solid #1e293b;padding-top:12px">
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;font-weight:600;margin-bottom:8px">ADD VESSEL</div>
                <form phx-submit="fleet_add_vessel" style="display:grid;grid-template-columns:repeat(4,1fr);gap:6px;align-items:end">
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">Vessel Name *</label>
                    <input name="vessel_name" required placeholder="MT Gas Chem Beluga"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:inherit" />
                  </div>
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">MMSI</label>
                    <input name="mmsi" placeholder="338234567" maxlength="9"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:monospace" />
                  </div>
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">SAP Ship#</label>
                    <input name="sap_shipping" placeholder="80012345"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:inherit" />
                  </div>
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">Cargo</label>
                    <input name="cargo" placeholder="Anhydrous Ammonia"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:inherit" />
                  </div>
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">Loading Port</label>
                    <input name="loading_port" placeholder="Donaldsonville"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:inherit" />
                  </div>
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">Discharge Port</label>
                    <input name="discharge_port" placeholder="Tampa"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:inherit" />
                  </div>
                  <div>
                    <label style="font-size:9px;color:#475569;display:block;margin-bottom:2px">ETA</label>
                    <input name="eta" type="date"
                      style="width:100%;background:#0a0f18;border:1px solid #1e293b;color:#e2e8f0;padding:6px 8px;border-radius:4px;font-size:11px;font-family:inherit" />
                  </div>
                  <div>
                    <button type="submit"
                      style="width:100%;background:#22d3ee;color:#0a0f18;border:none;padding:6px 8px;border-radius:4px;font-size:11px;font-weight:600;cursor:pointer">
                      Add Vessel
                    </button>
                  </div>
                </form>
              </div>
            </div>
          <% end %>

          <%!-- ═══════ HISTORY TAB ═══════ --%>
          <%= if @active_tab == :history do %>
            <div style="background:#111827;border-radius:10px;padding:16px">
              <%!-- Header row --%>
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                <div style="font-size:12px;font-weight:700;color:#06b6d4;letter-spacing:1px">MARKET HISTORY</div>
                <div style="display:flex;gap:8px">
                  <%= if @ingestion_running do %>
                    <span style="font-size:11px;color:#06b6d4;padding:6px 14px;border:1px solid #06b6d4;border-radius:6px;opacity:0.6">Running…</span>
                  <% else %>
                    <%= if @history_stats && (@history_stats.river.count > 0 || @history_stats.prices.count > 0) do %>
                      <button phx-click="snapshot_today"
                        style="font-size:11px;color:#06b6d4;padding:5px 12px;background:transparent;border:1px solid #06b6d4;border-radius:6px;cursor:pointer;font-weight:600">
                        Snapshot Today
                      </button>
                    <% end %>
                    <button phx-click="trigger_backfill"
                      style={"font-size:11px;padding:5px 12px;border-radius:6px;cursor:pointer;font-weight:600;#{if !@history_stats || @history_stats.river.count == 0, do: "background:#06b6d4;color:#0a0f18;border:none;", else: "background:transparent;color:#475569;border:1px solid #1e293b;"}"}>
                      <%= if !@history_stats || @history_stats.river.count == 0, do: "Run Full Backfill", else: "Re-run Backfill" %>
                    </button>
                  <% end %>
                </div>
              </div>

              <%!-- Filter bar --%>
              <div style="display:flex;align-items:center;gap:10px;margin-bottom:16px;padding:10px 12px;background:#0a0f18;border-radius:8px;flex-wrap:wrap">
                <%!-- Source selector --%>
                <div style="display:flex;gap:2px">
                  <%= for {src, label} <- [{:river, "River"}, {:prices, "Prices"}, {:freight, "Freight"}, {:vessels, "Vessels"}] do %>
                    <button phx-click="filter_history" phx-value-source={src}
                      style={"font-size:10px;font-weight:600;padding:4px 10px;border:none;border-radius:4px;cursor:pointer;#{if @history_source == src, do: "background:#06b6d4;color:#0a0f18;", else: "background:#1e293b;color:#64748b;"}"}>
                      <%= label %>
                    </button>
                  <% end %>
                </div>

                <div style="width:1px;height:20px;background:#1e293b"></div>

                <%!-- Year from --%>
                <div style="display:flex;align-items:center;gap:6px;font-size:11px;color:#64748b">
                  <span>From</span>
                  <select phx-change="filter_history" name="year_from"
                    style="background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:3px 6px;border-radius:4px;font-size:10px;cursor:pointer">
                    <%= for yr <- (Date.utc_today().year - 7)..(Date.utc_today().year) do %>
                      <option value={yr} selected={yr == @history_year_from}><%= yr %></option>
                    <% end %>
                  </select>
                  <span>To</span>
                  <select phx-change="filter_history" name="year_to"
                    style="background:#111827;border:1px solid #1e293b;color:#94a3b8;padding:3px 6px;border-radius:4px;font-size:10px;cursor:pointer">
                    <%= for yr <- (Date.utc_today().year - 7)..(Date.utc_today().year) do %>
                      <option value={yr} selected={yr == @history_year_to}><%= yr %></option>
                    <% end %>
                  </select>
                </div>

                <%= if @history_stats do %>
                  <div style="margin-left:auto;font-size:10px;color:#334155">
                    <%= case @history_source do
                      :river   -> "#{@history_stats.river.count} rows"
                      :prices  -> "#{@history_stats.prices.count} rows"
                      :freight -> "#{@history_stats.freight.count} rows"
                      _        -> ""
                    end %>
                  </div>
                <% end %>
              </div>

              <%= if is_nil(@history_stats) do %>
                <div style="text-align:center;padding:40px;color:#475569;font-size:12px">
                  No data loaded yet.
                  <span style="display:block;margin-top:8px;color:#06b6d4">Click Run Full Backfill to seed river history (5 years) and record today's prices and freight rates.</span>
                </div>
              <% else %>
                <%!-- ── RIVER STAGE ── --%>
                <%= if @history_source == :river do %>
                <div style="margin-bottom:20px">
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px;font-weight:600">RIVER STAGE (USGS)</div>
                    <div style="font-size:10px;color:#475569">
                      <%= @history_stats.river.count %> rows
                      <%= if @history_stats.river.min_date do %>
                        &middot; <%= @history_stats.river.min_date %> → <%= @history_stats.river.max_date %>
                      <% end %>
                    </div>
                  </div>
                  <%= if @history_stats.river.count == 0 do %>
                    <div style="padding:12px;background:#0a0f18;border-radius:6px;font-size:11px;color:#475569">
                      No river stage data — backfill will fetch up to 5 years of USGS daily readings for Baton Rouge, Vicksburg, Memphis, and Cairo.
                    </div>
                  <% else %>
                    <table style="width:100%;border-collapse:collapse;font-size:11px">
                      <thead>
                        <tr style="border-bottom:1px solid #1e293b">
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Date</th>
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Gauge</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Stage (ft)</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Flow (cfs)</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for row <- @history_stats.river.recent do %>
                          <tr style="border-bottom:1px solid #0f172a">
                            <td style="padding:5px 8px;color:#94a3b8;font-family:monospace"><%= row.date %></td>
                            <td style="padding:5px 8px;color:#e2e8f0"><%= row.gauge_key %></td>
                            <td style="padding:5px 8px;text-align:right;color:#06b6d4;font-family:monospace;font-weight:600">
                              <%= if row.stage_ft, do: Float.round(row.stage_ft, 1), else: "—" %>
                            </td>
                            <td style="padding:5px 8px;text-align:right;color:#475569;font-family:monospace">
                              <%= if row.flow_cfs, do: :erlang.float_to_binary(row.flow_cfs / 1.0, decimals: 0), else: "—" %>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  <% end %>
                </div>

                <% end %>
                <%!-- ── AMMONIA PRICES ── --%>
                <%= if @history_source == :prices do %>
                <div style="margin-bottom:20px">
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px;font-weight:600">AMMONIA PRICES</div>
                    <div style="font-size:10px;color:#475569">
                      <%= @history_stats.prices.count %> rows
                      <%= if @history_stats.prices.min_date do %>
                        &middot; <%= @history_stats.prices.min_date %> → <%= @history_stats.prices.max_date %>
                      <% end %>
                    </div>
                  </div>
                  <%= if @history_stats.prices.count == 0 do %>
                    <div style="padding:12px;background:#0a0f18;border-radius:6px;font-size:11px;color:#475569">
                      No price history — use Snapshot Today to record current benchmarks, or import a CSV from Argus/Fertecon via <code style="color:#06b6d4">Ingester.import_prices/1</code>.
                    </div>
                  <% else %>
                    <table style="width:100%;border-collapse:collapse;font-size:11px">
                      <thead>
                        <tr style="border-bottom:1px solid #1e293b">
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Date</th>
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Benchmark</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Price</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Source</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for row <- @history_stats.prices.recent do %>
                          <tr style="border-bottom:1px solid #0f172a">
                            <td style="padding:5px 8px;color:#94a3b8;font-family:monospace"><%= row.date %></td>
                            <td style="padding:5px 8px;color:#e2e8f0"><%= row.benchmark_key %></td>
                            <td style="padding:5px 8px;text-align:right;color:#10b981;font-family:monospace;font-weight:600">
                              $<%= Float.round(row.price_usd, 2) %> <span style="color:#475569;font-size:10px"><%= row.unit %></span>
                            </td>
                            <td style="padding:5px 8px;text-align:right;color:#475569;font-size:10px"><%= row.source %></td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  <% end %>
                </div>

                <% end %>
                <%!-- ── FREIGHT RATES ── --%>
                <%= if @history_source == :freight do %>
                <div style="margin-bottom:20px">
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px;font-weight:600">BARGE FREIGHT RATES</div>
                    <div style="font-size:10px;color:#475569">
                      <%= @history_stats.freight.count %> rows
                      <%= if @history_stats.freight.min_date do %>
                        &middot; <%= @history_stats.freight.min_date %> → <%= @history_stats.freight.max_date %>
                      <% end %>
                    </div>
                  </div>
                  <%= if @history_stats.freight.count == 0 do %>
                    <div style="padding:12px;background:#0a0f18;border-radius:6px;font-size:11px;color:#475569">
                      No freight history — Snapshot Today will record current broker rates, or import via <code style="color:#06b6d4">Ingester.import_freight/1</code>.
                    </div>
                  <% else %>
                    <table style="width:100%;border-collapse:collapse;font-size:11px">
                      <thead>
                        <tr style="border-bottom:1px solid #1e293b">
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Date</th>
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Route</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Rate ($/ton)</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Source</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for row <- @history_stats.freight.recent do %>
                          <tr style="border-bottom:1px solid #0f172a">
                            <td style="padding:5px 8px;color:#94a3b8;font-family:monospace"><%= row.date %></td>
                            <td style="padding:5px 8px;color:#e2e8f0"><%= row.route %></td>
                            <td style="padding:5px 8px;text-align:right;color:#f59e0b;font-family:monospace;font-weight:600">
                              $<%= Float.round(row.rate_per_ton, 2) %>
                            </td>
                            <td style="padding:5px 8px;text-align:right;color:#475569;font-size:10px"><%= row.source %></td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  <% end %>
                </div>

                <% end %>
                <%!-- ── VESSEL POSITIONS (AIS) ── --%>
                <%= if @history_source == :vessels do %>
                <div>
                  <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                    <div style="font-size:10px;color:#64748b;letter-spacing:1px;font-weight:600">VESSEL POSITIONS (AIS)</div>
                    <%= if @vessel_data do %>
                      <div style="font-size:10px;color:#475569">
                        <%= @vessel_data.fleet_summary.total_vessels %> tracked
                        &middot; <%= @vessel_data.fleet_summary.northbound %> NB
                        &middot; <%= @vessel_data.fleet_summary.southbound %> SB
                      </div>
                    <% end %>
                  </div>

                  <%= if is_nil(@vessel_data) do %>
                    <div style="padding:12px;background:#0a0f18;border-radius:6px;font-size:11px;color:#475569">
                      No AIS data yet.
                      <span style="display:block;margin-top:6px;color:#06b6d4;font-weight:600">
                        Set AISSTREAM_API_KEY (free at aisstream.io) to enable real-time tracking.
                      </span>
                      <span style="display:block;margin-top:6px;color:#334155;line-height:1.6">
                        Tracks: Mississippi towboats · ocean ammonia carriers · sulphur/petcoke bulk carriers · ocean-going barges (Class B equipped).<br/>
                        River barges don't carry AIS — tracked via their towboat.<br/>
                        <span style="color:#475569">For ocean routes add:</span>
                        <code style="color:#94a3b8;display:block;margin-top:4px">AISSTREAM_EXTRA_BBOX=lat_tl,lon_tl,lat_br,lon_br</code>
                        e.g. Black Sea: <code style="color:#475569">48.0,28.0,40.9,41.0</code> · Persian Gulf: <code style="color:#475569">30.0,48.0,22.0,60.0</code>
                      </span>
                    </div>
                  <% else %>
                    <table style="width:100%;border-collapse:collapse;font-size:11px">
                      <thead>
                        <tr style="border-bottom:1px solid #1e293b">
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Vessel</th>
                          <th style="text-align:left;padding:5px 8px;color:#64748b;font-weight:600">Near</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Mile</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Speed (kn)</th>
                          <th style="text-align:right;padding:5px 8px;color:#64748b;font-weight:600">Status</th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for v <- @vessel_data.vessels do %>
                          <tr style="border-bottom:1px solid #0f172a">
                            <td style="padding:5px 8px;color:#e2e8f0;font-weight:500"><%= v.name %></td>
                            <td style="padding:5px 8px;color:#94a3b8;font-size:10px"><%= v.nearest_waypoint %></td>
                            <td style="padding:5px 8px;text-align:right;color:#06b6d4;font-family:monospace"><%= v.river_mile %></td>
                            <td style="padding:5px 8px;text-align:right;color:#94a3b8;font-family:monospace"><%= v.speed || "—" %></td>
                            <td style="padding:5px 8px;text-align:right">
                              <span style={"font-size:9px;font-weight:700;padding:2px 5px;border-radius:3px;#{case v.status do :underway_engine -> "background:#14532d;color:#4ade80"; :moored -> "background:#1e3a5f;color:#60a5fa"; :at_anchor -> "background:#422006;color:#fb923c"; _ -> "background:#1e293b;color:#64748b" end}"}>
                                <%= v.status |> to_string() |> String.replace("_", " ") |> String.upcase() %>
                              </span>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  <% end %>
                </div>
                <% end %>
              <% end %>
            </div>
          <% end %>

          <%!-- ═══════ SOLVES TAB ═══════ --%>
          <%= if @active_tab == :solves do %>
            <div style="background:#111827;border-radius:10px;padding:16px">
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
                <div style="font-size:12px;font-weight:700;color:#eab308;letter-spacing:1px">
                  SOLVE HISTORY
                </div>
                <div style="font-size:10px;color:#64748b">
                  <%= length(@solve_history) %> solve<%= if length(@solve_history) != 1, do: "s" %> recorded
                </div>
              </div>

              <%= if length(@solve_history) == 0 do %>
                <div style="text-align:center;padding:40px;color:#475569;font-size:12px">
                  No solves recorded yet. Run a solve or wait for the auto-runner.
                </div>
              <% else %>
                <table style="width:100%;border-collapse:collapse;font-size:11px">
                  <thead>
                    <tr style="border-bottom:1px solid #1e293b">
                      <th style="text-align:left;padding:8px;color:#64748b;font-weight:600">Time</th>
                      <th style="text-align:left;padding:8px;color:#64748b;font-weight:600">Source</th>
                      <th style="text-align:left;padding:8px;color:#64748b;font-weight:600">Mode</th>
                      <th style="text-align:right;padding:8px;color:#64748b;font-weight:600">Result</th>
                      <th style="text-align:left;padding:8px;color:#64748b;font-weight:600">Trigger / Adjustments</th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for solve <- @solve_history do %>
                      <tr style={"border-bottom:1px solid #0f172a;background:#{if solve.source == :trader, do: "#0c1629", else: "transparent"}"}>
                        <%!-- Time --%>
                        <td style="padding:8px;color:#94a3b8;font-family:monospace;font-size:10px;white-space:nowrap">
                          <%= format_solve_time(solve.completed_at) %>
                        </td>

                        <%!-- Source --%>
                        <td style="padding:8px">
                          <%= if solve.source == :trader do %>
                            <span style="display:inline-flex;align-items:center;gap:4px">
                              <span style="background:#1e3a5f;color:#38bdf8;font-size:9px;font-weight:700;padding:2px 6px;border-radius:3px;letter-spacing:0.5px">MANUAL</span>
                              <span style="color:#94a3b8;font-size:10px"><%= solve.trader_id || "trader" %></span>
                            </span>
                          <% else %>
                            <span style="background:#14532d;color:#4ade80;font-size:9px;font-weight:700;padding:2px 6px;border-radius:3px;letter-spacing:0.5px">AUTO</span>
                          <% end %>
                        </td>

                        <%!-- Mode --%>
                        <td style="padding:8px">
                          <span style={"color:#{if solve.mode == :monte_carlo, do: "#a78bfa", else: "#38bdf8"};font-size:10px;font-weight:600"}>
                            <%= if solve.mode == :monte_carlo, do: "Monte Carlo", else: "Solve" %>
                          </span>
                        </td>

                        <%!-- Result --%>
                        <td style="padding:8px;text-align:right">
                          <%= cond do %>
                            <% solve.result_status == :optimal -> %>
                              <span style="color:#10b981;font-weight:700;font-family:monospace;font-size:11px">
                                $<%= format_number(solve.profit) %>
                              </span>
                            <% solve.result_status in [:strong_go, :go, :hold, :no_go] -> %>
                              <span style={"font-weight:700;font-size:10px;padding:2px 6px;border-radius:3px;#{signal_style(solve.result_status)}"}>
                                <%= solve.result_status |> to_string() |> String.upcase() |> String.replace("_", " ") %>
                              </span>
                              <span style="color:#94a3b8;font-family:monospace;font-size:10px;margin-left:4px">
                                $<%= format_number(solve.profit) %>
                              </span>
                            <% solve.result_status == :error -> %>
                              <span style="color:#ef4444;font-weight:600;font-size:10px">ERROR</span>
                            <% true -> %>
                              <span style="color:#64748b;font-size:10px"><%= solve.result_status %></span>
                          <% end %>
                        </td>

                        <%!-- Trigger / Adjustments --%>
                        <td style="padding:8px">
                          <%= if solve.source == :trader and length(solve.adjustments) > 0 do %>
                            <div style="display:flex;flex-wrap:wrap;gap:3px">
                              <%= for adj <- Enum.take(solve.adjustments, 5) do %>
                                <span style="background:#1a1400;color:#f59e0b;font-size:9px;padding:1px 5px;border-radius:3px;font-family:monospace">
                                  <%= adj.key %>: <%= adj.from %> &rarr; <%= adj.to %>
                                </span>
                              <% end %>
                              <%= if length(solve.adjustments) > 5 do %>
                                <span style="color:#64748b;font-size:9px">+<%= length(solve.adjustments) - 5 %> more</span>
                              <% end %>
                            </div>
                          <% end %>
                          <%= if solve.source == :auto and length(solve.triggers) > 0 do %>
                            <div style="display:flex;flex-wrap:wrap;gap:3px">
                              <%= for trigger <- Enum.take(solve.triggers, 5) do %>
                                <span style="background:#052e16;color:#4ade80;font-size:9px;padding:1px 5px;border-radius:3px;font-family:monospace">
                                  <%= trigger.key %> &Delta;<%= format_delta(trigger.delta) %>
                                </span>
                              <% end %>
                              <%= if length(solve.triggers) > 5 do %>
                                <span style="color:#64748b;font-size:9px">+<%= length(solve.triggers) - 5 %> more</span>
                              <% end %>
                            </div>
                          <% end %>
                          <%= if length(solve.triggers) == 0 and length(solve.adjustments) == 0 do %>
                            <span style="color:#475569;font-size:10px">
                              <%= if solve.source == :auto, do: "scheduled", else: "no overrides" %>
                            </span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% end %>
            </div>

            <%!-- Saved scenarios section --%>
            <%= if length(@saved_scenarios) > 0 do %>
              <div style="background:#111827;border-radius:10px;padding:16px;margin-top:16px">
                <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:12px">
                  <div style="font-size:12px;font-weight:700;color:#eab308;letter-spacing:1px">SAVED SCENARIOS</div>
                  <div style="font-size:10px;color:#64748b"><%= length(@saved_scenarios) %> saved</div>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:11px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:6px;color:#64748b">Name</th>
                    <th style="text-align:right;padding:6px;color:#64748b">Profit</th>
                    <th style="text-align:right;padding:6px;color:#64748b">ROI</th>
                    <th style="text-align:right;padding:6px;color:#64748b">Tons</th>
                    <th style="text-align:center;padding:6px;color:#64748b">Note</th>
                    <th style="text-align:right;padding:6px;color:#64748b">Saved</th>
                  </tr></thead>
                  <tbody>
                    <%= for sc <- @saved_scenarios do %>
                      <tr phx-click="load_scenario" phx-value-id={sc.id}
                        style="cursor:pointer;border-bottom:1px solid #1e293b22;transition:background 0.1s"
                        onmouseover="this.style.background='#0c1629'" onmouseout="this.style.background='transparent'">
                        <td style="padding:6px;font-weight:600;color:#c8d6e5"><%= sc.name %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace;color:#10b981">$<%= format_number(sc.result.profit) %></td>
                        <td style="text-align:right;padding:6px;font-family:monospace"><%= Float.round(sc.result.roi, 1) %>%</td>
                        <td style="text-align:right;padding:6px;font-family:monospace"><%= format_number(sc.result.tons) %></td>
                        <td style="text-align:center;padding:6px">
                          <%= if Map.get(sc.result, :analyst_note) do %>
                            <span style="font-size:9px;background:#1e1030;color:#a78bfa;padding:2px 6px;border-radius:3px">🧠 has note</span>
                          <% end %>
                        </td>
                        <td style="text-align:right;padding:6px;color:#475569;font-size:10px;white-space:nowrap">
                          <%= if sc.saved_at, do: Calendar.strftime(sc.saved_at, "%m/%d %H:%M"), else: "" %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
                <div style="font-size:10px;color:#334155;margin-top:8px;text-align:center">
                  Click a row to restore the scenario — switches to Trader tab
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <%!-- === PRE-SOLVE REVIEW POPUP === --%>
      <%= if @show_review do %>
        <div style="position:fixed;inset:0;z-index:1000">
          <%!-- Backdrop: sibling to modal, not parent — keeps LiveView event walk from reaching it --%>
          <div style="position:absolute;inset:0;background:rgba(0,0,0,0.7)"
               phx-click="cancel_review"></div>
          <%!-- Modal: centered, pointer-events threaded through wrapper --%>
          <div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;pointer-events:none">
            <div style="background:#111827;border:1px solid #1e293b;border-radius:12px;padding:24px;width:640px;max-height:80vh;overflow-y:auto;box-shadow:0 25px 50px rgba(0,0,0,0.5);pointer-events:auto">

            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
              <span style="font-size:14px;font-weight:700;color:#e2e8f0;letter-spacing:1px">
                PRE-SOLVE REVIEW — <%= if @review_mode == :monte_carlo, do: "MONTE CARLO", else: "SOLVE" %>
              </span>
              <button phx-click="cancel_review" style="background:none;border:none;color:#64748b;cursor:pointer;font-size:16px">X</button>
            </div>

            <%!-- Trader Scenario — with toggle to show what Claude receives (anonymized) --%>
            <div style="background:#0a0318;border-radius:8px;padding:14px;margin-bottom:14px;border-left:3px solid #a78bfa">
              <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
                <div style="font-size:10px;color:#a78bfa;letter-spacing:1.2px;font-weight:700">SCENARIO INPUT</div>
                <%= if @anon_model_preview && @anon_model_preview != "" do %>
                  <button phx-click="toggle_anon_preview"
                    style={"font-size:9px;padding:3px 8px;border-radius:4px;cursor:pointer;font-weight:600;letter-spacing:0.5px;border:1px solid #{if @show_anon_preview, do: "#a78bfa", else: "#374151"};background:#{if @show_anon_preview, do: "#2d1057", else: "transparent"};color:#{if @show_anon_preview, do: "#c4b5fd", else: "#64748b"}"}>
                    <%= if @show_anon_preview, do: "← Show Narrative", else: "🔒 Anonymized (sent to Claude)" %>
                  </button>
                <% end %>
              </div>
              <%= if @show_anon_preview do %>
                <%
                  anon_lines = (@anon_model_preview || "")
                    |> String.split("\n")
                    |> Enum.reject(&(String.starts_with?(String.trim(&1), "#") or String.trim(&1) == ""))
                    |> Enum.take(20)
                  anon_text = Enum.join(anon_lines, "\n")
                %>
                <pre style="font-size:10px;color:#c8d6e5;line-height:1.5;white-space:pre-wrap;margin:0;font-family:'Courier New',monospace;max-height:200px;overflow-y:auto"><%= anon_text %></pre>
                <div style="font-size:9px;color:#7c3aed;margin-top:4px">🔒 Counterparty & vessel names replaced with codes before leaving this server</div>
              <% else %>
                <%-- Show the trader's narrative description prominently --%>
                <%= if (@scenario_description || "") != "" do %>
                  <div style="font-size:13px;color:#e2e8f0;line-height:1.6;white-space:pre-wrap;padding:8px 10px;background:#0d0a20;border-radius:5px;border:1px solid #2d1b69"><%= @scenario_description %></div>
                <% else %>
                  <div style="font-size:12px;color:#475569;font-style:italic">No description entered — variable adjustments only</div>
                <% end %>
                <div style="font-size:9px;color:#475569;margin-top:6px">Full model context (variables, routes, positions) submitted to solver · click <em>Anonymized</em> to preview what Claude sees</div>
              <% end %>
            </div>

            <%!-- AI Interpretation --%>
            <%= if @intent_loading do %>
              <div style="font-size:12px;color:#64748b;padding:8px 0;text-align:center">⏳ Mapping intent to variables...</div>
            <% end %>
            <%= if @intent do %>
              <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:12px">
                <div style="font-size:10px;color:#38bdf8;letter-spacing:1px;margin-bottom:6px;font-weight:700">AI INTERPRETATION</div>
                <div style="font-size:12px;color:#c8d6e5;margin-bottom:10px;line-height:1.5"><%= @intent.summary %></div>

                <%!-- Variable changes --%>
                <%= if map_size(@intent.variable_adjustments) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:4px">VARIABLE CHANGES</div>
                  <div style="background:#080c14;border-radius:4px;padding:8px;margin-bottom:8px">
                    <%= for {key, val} <- @intent.variable_adjustments do %>
                      <div style="display:flex;justify-content:space-between;font-size:11px;padding:2px 0;font-family:monospace">
                        <span style="color:#94a3b8"><%= key %></span>
                        <span style="color:#94a3b8"><%= Map.get(@current_vars, key) %></span>
                        <span style="color:#64748b">→</span>
                        <span style="color:#f59e0b;font-weight:700"><%= val %></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Affected contracts --%>
                <%= if length(@intent.affected_contracts) > 0 do %>
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:4px">AFFECTED CONTRACTS</div>
                  <%= for ac <- @intent.affected_contracts do %>
                    <div style="font-size:11px;padding:3px 0;border-bottom:1px solid #1e293b22;display:flex;gap:6px">
                      <span style={"font-weight:600;color:#{if ac.direction == "purchase", do: "#60a5fa", else: "#f59e0b"}"}>
                        <%= if ac.direction == "purchase", do: "↓", else: "↑" %> <%= ac.counterparty %>
                      </span>
                      <span style="color:#64748b;font-size:10px">— <%= ac.impact %></span>
                    </div>
                  <% end %>
                <% end %>

                <%!-- Risk alerts --%>
                <%= if length(@intent.risk_notes) > 0 do %>
                  <div style="font-size:10px;color:#ef4444;letter-spacing:1px;margin-bottom:4px;margin-top:8px">RISK ALERTS</div>
                  <%= for note <- @intent.risk_notes do %>
                    <div style="font-size:11px;color:#fca5a5;padding:2px 0">⚠ <%= note %></div>
                  <% end %>
                <% end %>

                <%!-- Delivery penalty exposure + priority routing --%>
                <%= if Map.get(@intent, :penalty_exposure, 0) > 0 do %>
                  <div style="background:#1a0a0a;border-radius:6px;padding:10px;margin-top:8px">
                    <div style="display:flex;justify-content:space-between;align-items:baseline">
                      <span style="font-size:10px;color:#f97316;font-weight:700;letter-spacing:1px">DELIVERY PENALTY AT RISK</span>
                      <span style="font-size:14px;font-weight:700;font-family:monospace;color:#fdba74">~$<%= format_number(Map.get(@intent, :penalty_exposure, 0)) %></span>
                    </div>
                    <%= if length(Map.get(@intent, :priority_deliveries, [])) > 0 do %>
                      <div style="font-size:10px;margin-top:6px">
                        <span style="color:#4ade80;font-weight:700">SERVE FIRST: </span>
                        <span style="color:#86efac"><%= Enum.join(Map.get(@intent, :priority_deliveries, []), " · ") %></span>
                      </div>
                    <% end %>
                    <%= if length(Map.get(@intent, :deferred_deliveries, [])) > 0 do %>
                      <div style="font-size:10px;margin-top:3px">
                        <span style="color:#f59e0b;font-weight:700">CAN DEFER: </span>
                        <span style="color:#fcd34d"><%= Enum.join(Map.get(@intent, :deferred_deliveries, []), " · ") %></span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%!-- OBJECTIVE FOR THIS SOLVE — trader sets this, AI suggestion is advisory --%>
            <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:12px">
              <div style="font-size:10px;color:#64748b;letter-spacing:1.2px;margin-bottom:6px;font-weight:700">OBJECTIVE FOR THIS SOLVE</div>
              <select phx-change="switch_objective" name="objective"
                style="width:100%;background:#111827;border:1px solid #1e293b;color:#e2e8f0;padding:8px;border-radius:4px;font-size:12px;font-weight:600;cursor:pointer">
                <%= for {val, label} <- [max_profit: "Maximize Profit", min_cost: "Minimize Cost", max_roi: "Maximize ROI", cvar_adjusted: "CVaR-Adjusted", min_risk: "Minimize Risk"] do %>
                  <option value={val} selected={val == @objective_mode}><%= label %></option>
                <% end %>
              </select>
              <%!-- Show AI recommendation as a clickable suggestion when it differs from current --%>
              <%= if @intent && Map.get(@intent, :objective) && Map.get(@intent, :objective) != @objective_mode do %>
                <button phx-click="switch_objective" phx-value-objective={to_string(Map.get(@intent, :objective))}
                  style="margin-top:6px;width:100%;padding:6px 10px;border:1px solid #3b82f6;border-radius:4px;background:#0a1628;color:#93c5fd;font-size:11px;font-weight:600;cursor:pointer;text-align:left">
                  💡 AI suggests: <%= objective_label(Map.get(@intent, :objective)) %> — click to apply
                </button>
              <% end %>
            </div>

            <%!-- Open Book Positions --%>
            <%= if @sap_positions do %>
              <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:12px">
                <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">OPEN BOOK (SAP)</div>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin-bottom:8px">
                  <div style="text-align:center">
                    <div style="font-size:9px;color:#64748b">Purchase Open</div>
                    <div style="font-size:14px;font-weight:700;color:#60a5fa;font-family:monospace"><%= format_number(@sap_positions.total_purchase_open) %></div>
                  </div>
                  <div style="text-align:center">
                    <div style="font-size:9px;color:#64748b">Sale Open</div>
                    <div style="font-size:14px;font-weight:700;color:#f59e0b;font-family:monospace"><%= format_number(@sap_positions.total_sale_open) %></div>
                  </div>
                  <div style="text-align:center">
                    <div style="font-size:9px;color:#64748b">Net Position</div>
                    <div style={"font-size:14px;font-weight:700;font-family:monospace;color:#{if @sap_positions.net_position > 0, do: "#4ade80", else: "#f87171"}"}><%= if @sap_positions.net_position > 0, do: "+", else: "" %><%= format_number(@sap_positions.net_position) %></div>
                  </div>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:10px">
                  <thead><tr style="border-bottom:1px solid #1e293b">
                    <th style="text-align:left;padding:3px 4px;color:#475569">Counterparty</th>
                    <th style="text-align:center;padding:3px 4px;color:#475569">Dir</th>
                    <th style="text-align:center;padding:3px 4px;color:#475569">Incoterm</th>
                    <th style="text-align:right;padding:3px 4px;color:#475569">Contract</th>
                    <th style="text-align:right;padding:3px 4px;color:#475569">Delivered</th>
                    <th style="text-align:right;padding:3px 4px;color:#475569">Open</th>
                  </tr></thead>
                  <tbody>
                    <%= for {name, pos} <- Enum.sort_by(@sap_positions.positions, fn {_k, v} -> v.open_qty_mt end, :desc) do %>
                      <tr style="border-bottom:1px solid #1e293b11">
                        <td style="padding:3px 4px;color:#c8d6e5;font-weight:600"><%= name %></td>
                        <td style={"text-align:center;padding:3px 4px;color:#{if pos.direction == :purchase, do: "#60a5fa", else: "#f59e0b"};font-weight:600"}><%= if pos.direction == :purchase, do: "BUY", else: "SELL" %></td>
                        <td style="text-align:center;padding:3px 4px;color:#94a3b8"><%= pos.incoterm |> to_string() |> String.upcase() %></td>
                        <td style="text-align:right;padding:3px 4px;font-family:monospace;color:#94a3b8"><%= format_number(pos.total_qty_mt) %></td>
                        <td style="text-align:right;padding:3px 4px;font-family:monospace;color:#64748b"><%= format_number(pos.delivered_qty_mt) %></td>
                        <td style="text-align:right;padding:3px 4px;font-family:monospace;color:#e2e8f0;font-weight:600"><%= format_number(pos.open_qty_mt) %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <%!-- Key Variables Summary --%>
            <div style="background:#0a0f18;border-radius:8px;padding:12px;margin-bottom:16px">
              <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:6px">CURRENT VARIABLES</div>
              <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:4px;font-size:11px">
                <%= for meta <- Enum.take(Enum.filter(@metadata, & Map.get(&1, :type) != :boolean), 12) do %>
                  <div style="display:flex;justify-content:space-between;padding:2px 4px">
                    <span style="color:#64748b;font-size:10px"><%= meta.label %></span>
                    <span style={"color:#{if MapSet.member?(@overrides, meta.key), do: "#f59e0b", else: "#94a3b8"};font-family:monospace;font-size:10px"}><%= format_var(meta, Map.get(@current_vars, meta.key)) %></span>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Action buttons --%>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px">
              <button phx-click="cancel_review"
                style="padding:12px;border:1px solid #1e293b;border-radius:8px;background:transparent;color:#94a3b8;font-weight:700;font-size:13px;cursor:pointer;letter-spacing:1px">
                CANCEL
              </button>
              <button phx-click="confirm_solve"
                style={"padding:12px;border:none;border-radius:8px;font-weight:700;font-size:13px;cursor:pointer;letter-spacing:1px;color:#fff;background:linear-gradient(135deg,#{if @review_mode == :monte_carlo, do: "#7c3aed,#8b5cf6", else: "#0891b2,#06b6d4"})"}>
                CONFIRM <%= if @review_mode == :monte_carlo, do: "MONTE CARLO", else: "SOLVE" %>
              </button>
            </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- === ANALYST EXPLANATION POPUP === --%>
      <%= if @show_explanation_popup do %>
        <div style="position:fixed;inset:0;z-index:2000">
          <div style="position:absolute;inset:0;background:rgba(0,0,0,0.82)"
               phx-click="close_explanation_popup"></div>
          <div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:24px;pointer-events:none">
            <div style="background:#0d1117;border:1px solid #2d3748;border-radius:14px;width:min(860px,100%);max-height:88vh;display:flex;flex-direction:column;box-shadow:0 30px 60px rgba(0,0,0,0.7);pointer-events:auto">
            <%!-- Header --%>
            <div style="display:flex;justify-content:space-between;align-items:center;padding:20px 24px;border-bottom:1px solid #1e293b">
              <div>
                <span style="font-size:15px;font-weight:700;color:#e2e8f0;letter-spacing:0.5px">ANALYST NOTE</span>
                <%= if @result do %>
                  <span style="font-size:12px;color:#10b981;margin-left:12px;font-family:monospace">$<%= format_number(@result.profit) %> · <%= format_number(@result.tons) %> MT · <%= Float.round(@result.roi, 1) %>% ROI</span>
                <% end %>
              </div>
              <div style="display:flex;gap:8px;align-items:center">
                <button phx-click="save_explanation"
                  style="padding:8px 18px;border:none;border-radius:6px;background:linear-gradient(135deg,#4c1d95,#7c3aed);color:#e9d5ff;font-weight:700;font-size:12px;cursor:pointer;letter-spacing:0.5px">
                  💾 Save Analysis
                </button>
                <button phx-click="close_explanation_popup"
                  style="background:none;border:1px solid #374151;color:#9ca3af;cursor:pointer;font-size:20px;border-radius:6px;width:36px;height:36px;display:flex;align-items:center;justify-content:center">
                  ×
                </button>
              </div>
            </div>
            <%!-- Scrollable body --%>
            <div style="flex:1;overflow-y:auto;padding:24px">
              <%!-- Explanation text --%>
              <div style="background:#060c16;border:1px solid #1e293b;border-radius:10px;padding:20px;margin-bottom:20px">
                <div style="display:flex;align-items:center;gap:8px;margin-bottom:12px">
                  <span style="font-size:11px;color:#8b5cf6;font-weight:700;letter-spacing:1px">MARKET ANALYSIS</span>
                  <%= if @explaining do %>
                    <span style="font-size:10px;color:#475569;font-style:italic">generating analysis...</span>
                  <% end %>
                </div>
                <%= case @explanation do %>
                  <% {:error, err_text} -> %>
                    <div style="font-size:13px;color:#f87171;line-height:1.7"><%= err_text %></div>
                  <% text when is_binary(text) -> %>
                    <div style="font-size:14px;color:#e2e8f0;line-height:1.8;white-space:pre-wrap"><%= text %></div>
                  <% _ -> %>
                    <div style="font-size:13px;color:#475569;font-style:italic">Analysis not yet available — run SOLVE first</div>
                <% end %>
              </div>

              <%!-- Result summary grid --%>
              <%= if @result && @result.status == :optimal do %>
                <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:10px;padding:16px;margin-bottom:20px">
                  <div style="font-size:10px;color:#64748b;letter-spacing:1px;margin-bottom:12px">SOLVER RESULT DETAIL</div>
                  <div style="display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:14px">
                    <div style="background:#060c16;padding:10px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Profit</div>
                      <div style="font-size:16px;font-weight:800;color:#10b981;font-family:monospace">$<%= format_number(@result.profit) %></div>
                    </div>
                    <div style="background:#060c16;padding:10px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Tons</div>
                      <div style="font-size:16px;font-weight:700;font-family:monospace"><%= format_number(@result.tons) %></div>
                    </div>
                    <div style="background:#060c16;padding:10px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Barges</div>
                      <div style="font-size:16px;font-weight:700;font-family:monospace"><%= Float.round(@result.barges, 1) %></div>
                    </div>
                    <div style="background:#060c16;padding:10px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">ROI</div>
                      <div style="font-size:16px;font-weight:700;font-family:monospace"><%= Float.round(@result.roi, 1) %>%</div>
                    </div>
                    <div style="background:#060c16;padding:10px;border-radius:6px;text-align:center">
                      <div style="font-size:9px;color:#64748b">Capital</div>
                      <div style="font-size:14px;font-weight:700;font-family:monospace;color:#94a3b8">$<%= format_number(@result.cost) %></div>
                    </div>
                  </div>
                  <table style="width:100%;border-collapse:collapse;font-size:12px">
                    <thead><tr style="border-bottom:1px solid #1e293b">
                      <th style="text-align:left;padding:6px;color:#475569;font-size:10px">Route</th>
                      <th style="text-align:right;padding:6px;color:#475569;font-size:10px">Tons</th>
                      <th style="text-align:right;padding:6px;color:#475569;font-size:10px">Margin</th>
                      <th style="text-align:right;padding:6px;color:#475569;font-size:10px">Profit</th>
                    </tr></thead>
                    <tbody>
                      <%= for {name, idx} <- Enum.with_index(@route_names) do %>
                        <% tons = Enum.at(@result.route_tons, idx, 0) %>
                        <%= if tons > 0.5 do %>
                          <tr style="border-bottom:1px solid #1e293b11">
                            <td style="padding:6px;font-weight:600;color:#c8d6e5"><%= name %></td>
                            <td style="text-align:right;padding:6px;font-family:monospace"><%= format_number(tons) %></td>
                            <td style="text-align:right;padding:6px;font-family:monospace;color:#38bdf8">$<%= Float.round(Enum.at(@result.margins, idx, 0), 1) %>/t</td>
                            <td style="text-align:right;padding:6px;font-family:monospace;color:#10b981;font-weight:700">$<%= format_number(Enum.at(@result.route_profits, idx, 0)) %></td>
                          </tr>
                        <% end %>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>

              <%!-- Position impact --%>
              <%= if @post_solve_impact do %>
                <div style="background:#0d1a0d;border:1px solid #166534;border-radius:10px;padding:16px">
                  <div style="font-size:10px;color:#4ade80;letter-spacing:1px;margin-bottom:6px">POSITION IMPACT</div>
                  <div style="font-size:12px;color:#86efac;margin-bottom:10px"><%= @post_solve_impact.summary %></div>
                  <table style="width:100%;border-collapse:collapse;font-size:11px">
                    <thead><tr style="border-bottom:1px solid #166534">
                      <th style="text-align:left;padding:4px;color:#4ade80;font-size:10px">Counterparty</th>
                      <th style="text-align:center;padding:4px;color:#4ade80;font-size:10px">Dir</th>
                      <th style="text-align:right;padding:4px;color:#4ade80;font-size:10px">Open MT</th>
                      <th style="text-align:left;padding:4px;color:#4ade80;font-size:10px">Impact</th>
                    </tr></thead>
                    <tbody>
                      <%= for c <- @post_solve_impact.by_contract do %>
                        <tr style="border-bottom:1px solid #14532d22">
                          <td style="padding:4px;color:#d1fae5;font-weight:600"><%= c.counterparty %></td>
                          <td style={"text-align:center;padding:4px;color:#{if c.direction == "purchase", do: "#60a5fa", else: "#f59e0b"};font-weight:600;font-size:10px"}><%= if c.direction == "purchase", do: "BUY", else: "SELL" %></td>
                          <td style="text-align:right;padding:4px;font-family:monospace;color:#94a3b8"><%= format_number(c.open_qty) %></td>
                          <td style="padding:4px;color:#6ee7b7;font-size:10px"><%= c.impact %></td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Helpers ---

  defp percentile_rank(profit, dist) do
    cond do
      dist == nil -> nil
      profit <= dist.p5 -> {5, "below 5th percentile — high risk"}
      profit <= dist.p25 ->
        pct = round(5 + (profit - dist.p5) / max(dist.p25 - dist.p5, 1) * 20)
        {pct, "#{pct}th percentile — below average"}
      profit <= dist.p50 ->
        pct = round(25 + (profit - dist.p25) / max(dist.p50 - dist.p25, 1) * 25)
        {pct, "#{pct}th percentile — near median"}
      profit <= dist.p75 ->
        pct = round(50 + (profit - dist.p50) / max(dist.p75 - dist.p50, 1) * 25)
        {pct, "#{pct}th percentile — above average"}
      profit <= dist.p95 ->
        pct = round(75 + (profit - dist.p75) / max(dist.p95 - dist.p75, 1) * 20)
        {pct, "#{pct}th percentile — strong"}
      true -> {99, "above 95th percentile — best case"}
    end
  end

  defp sensitivity_label(key) do
    # Try all registered product groups for label lookup
    label =
      ProductGroup.list()
      |> Enum.find_value(fn pg ->
        ProductGroup.variables(pg)
        |> Enum.find_value(fn v ->
          if v[:key] == key, do: v[:label]
        end)
      end)

    label || key |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp trigger_label(:startup), do: "startup"
  defp trigger_label(:scheduled), do: "scheduled"
  defp trigger_label(:manual), do: "manual"
  defp trigger_label(:initial), do: "initial"
  defp trigger_label(key), do: sensitivity_label(key)

  defp format_trigger(%{key: key, baseline_value: baseline, current_value: current, delta: delta, threshold: threshold}) do
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(baseline, 1)} → #{Float.round(current, 1)} (#{sign}#{Float.round(delta, 1)}, threshold ±#{Float.round(threshold, 1)})"
  end
  defp format_trigger(%{key: key, baseline_value: baseline, current_value: current, delta: delta}) do
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(baseline, 1)} → #{Float.round(current, 1)} (#{sign}#{Float.round(delta, 1)})"
  end
  defp format_trigger(%{key: key, old: nil}), do: trigger_label(key)
  defp format_trigger(%{key: key, old: old, new: new}) do
    delta = new - old
    sign = if delta > 0, do: "+", else: ""
    "#{trigger_label(key)}: #{Float.round(old, 1)} → #{Float.round(new, 1)} (#{sign}#{Float.round(delta, 1)})"
  end
  defp format_trigger(%{key: key}), do: trigger_label(key)
  defp format_trigger(_), do: "—"

  defp signal_color(:strong_go), do: "#10b981"
  defp signal_color(:go), do: "#34d399"
  defp signal_color(:cautious), do: "#fbbf24"
  defp signal_color(:weak), do: "#f87171"
  defp signal_color(:no_go), do: "#ef4444"
  defp signal_color(_), do: "#64748b"

  defp signal_text(:strong_go), do: "STRONG GO"
  defp signal_text(:go), do: "GO"
  defp signal_text(:cautious), do: "CAUTIOUS"
  defp signal_text(:weak), do: "WEAK"
  defp signal_text(:no_go), do: "NO GO"
  defp signal_text(_), do: "—"

  defp group_color(:environment), do: "#38bdf8"
  defp group_color(:operations), do: "#a78bfa"
  defp group_color(:commercial), do: "#34d399"
  defp group_color(:market), do: "#34d399"
  defp group_color(:freight), do: "#f59e0b"
  defp group_color(:macro), do: "#818cf8"
  defp group_color(:quality), do: "#fb923c"
  defp group_color(_), do: "#94a3b8"

  defp group_icon(:environment), do: "~"
  defp group_icon(:operations), do: "*"
  defp group_icon(:commercial), do: "$"
  defp group_icon(:market), do: "$"
  defp group_icon(:freight), do: ">"
  defp group_icon(:macro), do: "#"
  defp group_icon(:quality), do: "?"
  defp group_icon(_), do: "-"

  defp format_var(%{unit: "$"}, val), do: "$#{format_number(val)}"
  defp format_var(%{unit: "$M"}, val), do: "$#{format_number(val)}M"
  defp format_var(%{step: step, unit: unit}, val) when is_float(val) and is_float(step) and step < 1 do
    "#{Float.round(val, 1)} #{unit}"
  end
  defp format_var(%{unit: unit}, val) when is_float(val), do: "#{round(val)} #{unit}"
  defp format_var(%{unit: unit}, val), do: "#{val} #{unit}"
  defp format_var(_meta, val), do: to_string(val)

  defp format_number(val) when is_float(val) do
    val
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})/, "\\1,")
    |> String.reverse()
    |> String.trim_leading(",")
  end
  defp format_number(val), do: to_string(val)

  defp load_contracts_data do
    book = TradingDesk.Contracts.SapPositions.book_summary()
    positions = book.positions

    # Pull live penalty schedule from ConstraintBridge (sourced from parsed contracts)
    penalty_by_counterparty =
      try do
        TradingDesk.Contracts.ConstraintBridge.penalty_schedule(:ammonia)
        |> Enum.group_by(& &1.counterparty)
      rescue
        _ -> %{}
      catch
        :exit, _ -> %{}
      end

    contracts =
      positions
      |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
      |> Enum.map(fn {name, pos} ->
        penalties =
          case Map.get(penalty_by_counterparty, name) do
            nil ->
              []
            entries ->
              Enum.map(entries, fn p ->
                type_label = case p.penalty_type do
                  :volume_shortfall -> "Volume shortfall"
                  :late_delivery    -> "Late delivery"
                  :demurrage        -> "Demurrage"
                  other             -> other |> to_string() |> String.replace("_", " ") |> String.capitalize()
                end
                %{
                  type: type_label,
                  rate: "$#{:erlang.float_to_binary(p.rate_per_ton / 1.0, decimals: 0)}/MT",
                  applies_to: if(pos.direction == :purchase, do: "Buyer", else: "Seller")
                }
              end)
          end

        %{
          counterparty: name,
          contract_number: pos.contract_number,
          direction: pos.direction,
          incoterm: pos.incoterm,
          total_qty: pos.total_qty_mt,
          delivered_qty: pos.delivered_qty_mt,
          open_qty: pos.open_qty_mt,
          period: pos.period,
          penalties: penalties,
          pct_complete: if(pos.total_qty_mt > 0, do: round(pos.delivered_qty_mt / pos.total_qty_mt * 100), else: 0)
        }
      end)

    %{
      contracts: contracts,
      total_purchase_open: book.total_purchase_open,
      total_sale_open: book.total_sale_open,
      net_position: book.net_position
    }
  end

  defp load_fleet_vessels(pg_filter) do
    if pg_filter in ["", "all"] do
      TrackedVessel.list_all()
    else
      import Ecto.Query
      TradingDesk.Repo.all(
        from v in TrackedVessel,
          where: v.product_group == ^pg_filter,
          order_by: [asc: v.status, desc: v.updated_at]
      )
    end
  rescue
    _ -> []
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(s), do: String.trim(s)

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  defp history_filter_opts(assigns) do
    year_from = Map.get(assigns, :history_year_from, Date.utc_today().year - 1)
    year_to   = Map.get(assigns, :history_year_to,   Date.utc_today().year)
    [
      from: Date.new!(year_from, 1, 1),
      to:   Date.new!(year_to, 12, 31)
    ]
  end

  defp load_api_status do
    poller_status = TradingDesk.Data.Poller.status()
    sap_status = TradingDesk.Contracts.SapRefreshScheduler.status()
    prices_updated = safe_call(fn -> TradingDesk.Data.AmmoniaPrices.last_updated() end, nil)
    claude_key = System.get_env("ANTHROPIC_API_KEY")
    delta_config = safe_call(fn -> TradingDesk.Config.DeltaConfig.get(:ammonia) end, %{
      enabled: false, thresholds: %{}, min_solve_interval_ms: 300_000, n_scenarios: 1000
    })

    error_count = Enum.count(poller_status.sources, & &1.status == :error)

    %{
      poller_sources: poller_status.sources,
      sap: sap_status,
      prices_updated_at: prices_updated,
      claude_configured: claude_key != nil and claude_key != "",
      error_count: error_count,
      delta_config: delta_config
    }
  end

  defp format_api_timestamp(nil), do: "—"
  defp format_api_timestamp(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h #{rem(div(diff, 60), 60)}m ago"
      true -> Calendar.strftime(dt, "%b %d %H:%M")
    end
  end
  defp format_api_timestamp(_), do: "—"

  defp format_interval(nil), do: "—"
  defp format_interval(ms) when is_integer(ms) do
    cond do
      ms < 60_000 -> "#{div(ms, 1000)}s"
      ms < 3_600_000 -> "#{div(ms, 60_000)}m"
      true -> "#{div(ms, 3_600_000)}h"
    end
  end
  defp format_interval(_), do: "—"

  # ── Solve history helpers ─────────────────────────────────

  # Load solve history filtered by trader_id and product_group.
  # Trader solves are keyed to the trader; auto-runner solves are shown for all traders
  # (they represent the live market signal relevant to everyone).
  defp load_solve_history(product_group, trader_id \\ nil) do
    # Fetch trader-specific audits if trader_id provided, else fetch all recent
    audits =
      if trader_id && trader_id != "" do
        safe_call(fn -> TradingDesk.Solver.SolveAuditStore.find_by_trader(to_string(trader_id), limit: 50) end, []) ++
        safe_call(fn -> TradingDesk.Solver.SolveAuditStore.list_recent(20) end, [])
        |> Enum.uniq_by(& &1.id)
      else
        safe_call(fn -> TradingDesk.Solver.SolveAuditStore.list_recent(50) end, [])
      end

    auto_history = safe_call(fn -> TradingDesk.Scenarios.AutoRunner.history() end, [])

    # Build auto-runner entries (shared across all traders — these are market signals)
    auto_entries =
      auto_history
      |> Enum.map(fn h ->
        {profit, signal} = extract_auto_result(h)
        %{
          completed_at: h.timestamp,
          source: :auto,
          trader_id: nil,
          mode: :monte_carlo,
          result_status: signal,
          profit: profit,
          triggers: Map.get(h, :triggers, []),
          adjustments: [],
          audit_id: Map.get(h, :audit_id)
        }
      end)

    # Build manual trader entries — filter to this trader's solves
    trader_entries =
      audits
      |> Enum.filter(fn a ->
        is_trader_solve = a.trigger in [:dashboard, :api]
        is_this_trader  = trader_id == nil or to_string(a.trader_id) == to_string(trader_id)
        is_trader_solve and is_this_trader
      end)
      |> Enum.map(fn a ->
        profit = extract_audit_profit(a)
        adjustments = extract_variable_adjustments(a)
        %{
          completed_at: a.completed_at || a.started_at,
          source: :trader,
          trader_id: a.trader_id,
          mode: a.mode,
          result_status: a.result_status,
          profit: profit,
          triggers: [],
          adjustments: adjustments,
          audit_id: a.id
        }
      end)

    # Merge, deduplicate by audit_id, sort newest first
    (auto_entries ++ trader_entries)
    |> Enum.uniq_by(& &1.audit_id)
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
    |> Enum.take(50)
  end

  defp extract_auto_result(%{distribution: dist}) when is_map(dist) do
    {Map.get(dist, :mean, 0.0), Map.get(dist, :signal, :unknown)}
  end
  defp extract_auto_result(_), do: {0.0, :unknown}

  defp extract_audit_profit(%{result: result, mode: :solve}) when is_map(result) do
    Map.get(result, :objective, 0.0) || Map.get(result, :profit, 0.0)
  end
  defp extract_audit_profit(%{result: result, mode: :monte_carlo}) when is_map(result) do
    Map.get(result, :mean, 0.0)
  end
  defp extract_audit_profit(_), do: 0.0

  defp extract_variable_adjustments(%{variables: vars, variable_sources: _sources}) when is_map(vars) do
    # We show variables that differ from default as "adjustments"
    # In a real implementation, this would compare against the baseline
    []
  end
  defp extract_variable_adjustments(_), do: []

  defp format_solve_time(nil), do: "—"
  defp format_solve_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d %H:%M:%S")
  end
  defp format_solve_time(_), do: "—"

  defp format_delta(delta) when is_float(delta) and delta >= 0, do: "+#{Float.round(delta, 2)}"
  defp format_delta(delta) when is_float(delta), do: "#{Float.round(delta, 2)}"
  defp format_delta(delta) when is_integer(delta) and delta >= 0, do: "+#{delta}"
  defp format_delta(delta) when is_integer(delta), do: "#{delta}"
  defp format_delta(delta), do: inspect(delta)

  defp signal_style(:strong_go), do: "background:#052e16;color:#4ade80"
  defp signal_style(:go), do: "background:#052e16;color:#86efac"
  defp signal_style(:hold), do: "background:#1a1400;color:#fbbf24"
  defp signal_style(:no_go), do: "background:#1c0a0a;color:#f87171"
  defp signal_style(_), do: "background:#0f172a;color:#64748b"

  # ── Threshold display helpers ─────────────────────────────

  defp format_threshold_key(key) do
    case key do
      :river_stage -> "River"
      :lock_hrs -> "Lock"
      :temp_f -> "Temp"
      :wind_mph -> "Wind"
      :vis_mi -> "Visibility"
      :precip_in -> "Precip"
      :inv_don -> "Inv Don"
      :inv_geis -> "Inv Geis"
      :stl_outage -> "StL Out"
      :mem_outage -> "Mem Out"
      :barge_count -> "Barges"
      :nola_buy -> "NOLA Buy"
      :sell_stl -> "Sell StL"
      :sell_mem -> "Sell Mem"
      :fr_don_stl -> "Fr D→StL"
      :fr_don_mem -> "Fr D→Mem"
      :fr_geis_stl -> "Fr G→StL"
      :fr_geis_mem -> "Fr G→Mem"
      :nat_gas -> "Nat Gas"
      :working_cap -> "Wrk Cap"
      other -> other |> to_string() |> String.replace("_", " ")
    end
  end

  defp format_threshold_value(key, val) do
    cond do
      key in [:nola_buy, :sell_stl, :sell_mem, :fr_don_stl, :fr_don_mem, :fr_geis_stl, :fr_geis_mem, :nat_gas] ->
        "$#{val}"
      key == :working_cap ->
        "$#{round(val / 1000)}k"
      key in [:river_stage] ->
        "#{val}ft"
      key in [:temp_f] ->
        "#{val}°F"
      key in [:wind_mph] ->
        "#{val}mph"
      key in [:vis_mi] ->
        "#{val}mi"
      key in [:precip_in] ->
        "#{val}in"
      key in [:lock_hrs] ->
        "#{val}hrs"
      key in [:inv_don, :inv_geis] ->
        "#{round(val)}MT"
      key in [:stl_outage, :mem_outage] ->
        "any"
      key in [:barge_count] ->
        "#{round(val)}"
      true ->
        "#{val}"
    end
  end

  defp maybe_parse_intent(socket) do
    # Use model_summary if non-empty (structured input), else fall back to trader_action
    model_summary = socket.assigns.model_summary || ""
    action = socket.assigns.trader_action || ""

    input_text =
      cond do
        String.trim(model_summary) != "" -> model_summary
        String.trim(action) != "" -> action
        true -> nil
      end

    if input_text do
      lv_pid = self()
      vars = socket.assigns.current_vars
      pg = socket.assigns.product_group
      spawn(fn ->
        case TradingDesk.IntentMapper.parse_intent(input_text, vars, pg) do
          {:ok, intent} -> send(lv_pid, {:intent_result, intent})
          {:error, _} -> send(lv_pid, {:intent_result, nil})
        end
      end)
      assign(socket, :intent_loading, true)
    else
      socket
    end
  end

  defp apply_intent_adjustments(vars, nil), do: vars
  defp apply_intent_adjustments(vars, %{variable_adjustments: adj}) when map_size(adj) > 0 do
    Enum.reduce(adj, vars, fn {key, val}, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, val), else: acc
    end)
  end
  defp apply_intent_adjustments(vars, _), do: vars

  defp maybe_intent_objective(%{objective: obj}, _default) when not is_nil(obj), do: obj
  defp maybe_intent_objective(_, default), do: default

  defp parse_value(_key, "true"), do: true
  defp parse_value(_key, "false"), do: false
  defp parse_value(_key, value) when is_binary(value) do
    case Float.parse(value) do
      {f, _} -> f
      :error -> 0.0
    end
  end
  defp parse_value(_key, value), do: value

  # --- Pipeline UI helpers ---

  defp objective_label(:max_profit), do: "Maximize Profit"
  defp objective_label(:min_cost), do: "Minimize Cost"
  defp objective_label(:max_roi), do: "Maximize ROI"
  defp objective_label(:cvar_adjusted), do: "CVaR-Adjusted"
  defp objective_label(:min_risk), do: "Minimize Risk"
  defp objective_label(_), do: "Custom Objective"

  defp analyst_error_text(:no_api_key), do: "ANTHROPIC_API_KEY not set. Export it in your shell to enable analyst explanations."
  defp analyst_error_text(:api_error), do: "Claude API returned an error. Check logs for details."
  defp analyst_error_text(:request_failed), do: "Could not reach Claude API. Check network connectivity."
  defp analyst_error_text(msg) when is_binary(msg), do: "Analyst crashed: #{msg}"
  defp analyst_error_text(reason), do: "Analyst error: #{inspect(reason)}"

  defp pipeline_button_text(false, _, label), do: "⚡ #{label}"
  defp pipeline_button_text(true, :checking_contracts, _), do: "📋 CHECKING CONTRACTS..."
  defp pipeline_button_text(true, :ingesting, _), do: "🔄 INGESTING CHANGES..."
  defp pipeline_button_text(true, :solving, _), do: "⏳ SOLVING..."
  defp pipeline_button_text(true, _, _), do: "⏳ WORKING..."

  defp pipeline_phase_text(:checking_contracts), do: "Checking contract hashes"
  defp pipeline_phase_text(:ingesting), do: "Waiting for Copilot to ingest changes"
  defp pipeline_phase_text(:solving), do: "Running solver"
  defp pipeline_phase_text(_), do: "Working"

  defp pipeline_bg(:checking_contracts), do: "#0c1629"
  defp pipeline_bg(:ingesting), do: "#1a1400"
  defp pipeline_bg(:solving), do: "#0c1629"
  defp pipeline_bg(_), do: "#0c1629"

  defp pipeline_border(:checking_contracts), do: "#1e3a5f"
  defp pipeline_border(:ingesting), do: "#78350f"
  defp pipeline_border(:solving), do: "#1e3a5f"
  defp pipeline_border(_), do: "#1e293b"

  defp pipeline_dot(:checking_contracts), do: "#38bdf8"
  defp pipeline_dot(:ingesting), do: "#f59e0b"
  defp pipeline_dot(:solving), do: "#10b981"
  defp pipeline_dot(_), do: "#64748b"

  # --- Vessel tracking helpers ---

  defp vessel_status_icon(:northbound), do: "^"
  defp vessel_status_icon(:southbound), do: "v"
  defp vessel_status_icon(_), do: "-"

  defp vessel_status_color(:underway_engine), do: "#10b981"
  defp vessel_status_color(:underway_sailing), do: "#34d399"
  defp vessel_status_color(:at_anchor), do: "#f59e0b"
  defp vessel_status_color(:moored), do: "#60a5fa"
  defp vessel_status_color(:not_under_command), do: "#ef4444"
  defp vessel_status_color(:restricted_maneuverability), do: "#fbbf24"
  defp vessel_status_color(_), do: "#64748b"

  defp vessel_status_text(:underway_engine), do: "UNDERWAY"
  defp vessel_status_text(:underway_sailing), do: "SAILING"
  defp vessel_status_text(:at_anchor), do: "ANCHOR"
  defp vessel_status_text(:moored), do: "MOORED"
  defp vessel_status_text(:not_under_command), do: "NUC"
  defp vessel_status_text(:restricted_maneuverability), do: "RESTRICTED"
  defp vessel_status_text(_), do: "UNKNOWN"

  # --- Map data helpers ---

  @terminal_coords %{
    # Ammonia Domestic (Mississippi River)
    "Donaldsonville, LA" => {30.098, -90.993},
    "Geismar, LA" => {30.219, -90.935},
    "St. Louis, MO" => {38.627, -90.199},
    "Memphis, TN" => {35.150, -90.049},
    # Ammonia International
    "Point Lisas, Trinidad" => {10.400, -61.468},
    "Yuzhnyy, Ukraine" => {46.627, 31.011},
    "Jubail, Saudi Arabia" => {27.015, 49.658},
    "Tampa, FL" => {27.951, -82.457},
    "Paradip/Mumbai, India" => {20.266, 86.612},
    "Jorf Lasfar, Morocco" => {33.101, -8.621},
    # Sulphur International
    "Vancouver, BC" => {49.283, -123.121},
    "Abu Dhabi/Ruwais, UAE" => {24.073, 52.730},
    "Batumi, Georgia" => {41.640, 41.637},
    "Mumbai/Paradip, India" => {20.266, 86.612},
    "Nanjing/Zhanjiang, China" => {32.060, 118.797},
    # Petcoke
    "US Gulf Coast" => {29.760, -95.370},
    "Mundra/Kandla, India" => {22.739, 69.722},
    "Qingdao/Lianyungang, China" => {36.067, 120.383},
    "Mundra/Jamnagar, India" => {22.294, 68.968}
  }

  @map_centers %{
    ammonia_domestic: {34.0, -90.5, 5},
    ammonia_international: {20.0, -20.0, 2},
    sulphur_international: {25.0, 40.0, 2},
    petcoke: {20.0, 40.0, 2}
  }

  defp map_data_json(product_group, frame, result, vessel_data) do
    routes = frame[:routes] || []
    {clat, clon, zoom} = Map.get(@map_centers, product_group, {20.0, 0.0, 2})

    route_tons = if result, do: result.route_tons || [], else: []

    terminals =
      routes
      |> Enum.flat_map(fn r -> [r[:origin], r[:destination]] end)
      |> Enum.uniq()
      |> Enum.flat_map(fn name ->
        case Map.get(@terminal_coords, name) do
          {lat, lon} ->
            color = if String.contains?(name || "", ["Don", "Geis", "USGC", "US Gulf", "Vancouver", "Point Lisas",
                                                      "Yuzhnyy", "Jubail", "Abu Dhabi", "Batumi", "Mundra/Jamnagar"]),
                       do: "#f59e0b", else: "#10b981"
            [%{name: name, lat: lat, lon: lon, color: color}]
          _ -> []
        end
      end)

    route_lines =
      routes
      |> Enum.with_index()
      |> Enum.flat_map(fn {r, idx} ->
        with {flat, flon} <- Map.get(@terminal_coords, r[:origin]),
             {tlat, tlon} <- Map.get(@terminal_coords, r[:destination]) do
          tons = Enum.at(route_tons, idx, 0.0)
          [%{from_lat: flat, from_lon: flon, to_lat: tlat, to_lon: tlon, active: tons > 0.5}]
        else
          _ -> []
        end
      end)

    vessels =
      case vessel_data do
        %{vessels: vs} when is_list(vs) -> build_vessel_markers(vs, product_group)
        _ when is_map(vessel_data) ->
          case vessel_data[:vessels] do
            vs when is_list(vs) -> build_vessel_markers(vs, product_group)
            _ -> []
          end
        _ -> []
      end

    data = %{
      center: [clat, clon],
      zoom: zoom,
      terminals: terminals,
      routes: route_lines,
      vessels: vessels
    }

    Jason.encode!(data)
  end

  defp build_vessel_markers(vessels, :ammonia_domestic) do
    # Barge positions approximated from river mile on the Mississippi
    Enum.flat_map(vessels, fn v ->
      case v[:river_mile] do
        rm when is_number(rm) ->
          # Approximate lat from river mile (Mile 0 = Pilottown ~29.18, Mile 180 = NOLA ~30.0,
          # Mile 600 = Memphis ~35.15, Mile 1050 = St. Louis ~38.63)
          lat = 29.18 + rm * 0.009
          lon = -90.0 + :rand.uniform() * 0.3 - 0.15  # slight jitter
          color = case v[:status] do
            :underway_engine -> "#10b981"
            :at_anchor -> "#f59e0b"
            :moored -> "#60a5fa"
            _ -> "#64748b"
          end
          [%{lat: lat, lon: lon, name: v[:name] || "Barge", status: to_string(v[:status] || "unknown"), color: color}]
        _ -> []
      end
    end)
  end

  defp build_vessel_markers(vessels, _product_group) do
    # Ocean vessels with lat/lon
    Enum.flat_map(vessels, fn v ->
      lat = v[:latitude] || v[:lat]
      lon = v[:longitude] || v[:lon]
      if lat && lon do
        color = case v[:status] do
          :underway_engine -> "#10b981"
          :at_anchor -> "#f59e0b"
          :moored -> "#60a5fa"
          _ -> "#64748b"
        end
        [%{lat: lat, lon: lon, name: v[:name] || "Vessel", status: to_string(v[:status] || "unknown"), color: color}]
      else
        []
      end
    end)
  end

  # --- Delivery impact helpers ---

  # Computes a summary of how the intended action affects each delivery schedule.
  # Returns %{by_customer: [...], deferred_count: int, total_penalty_exposure: float}
  # where each customer map has: counterparty, status, scheduled_qty_mt, frequency,
  # next_window_days, penalty_estimate.
  defp compute_delivery_impact(intent, product_group) do
    schedules =
      try do
        TradingDesk.Contracts.Store.get_active_set(product_group)
        |> TradingDesk.Trader.DeliverySchedule.from_contracts()
      catch
        :exit, _ -> []
      rescue
        _ -> []
      end

    if schedules == [] do
      nil
    else
      deferred   = (intent && intent.deferred_deliveries)  || []
      prioritised = (intent && intent.priority_deliveries) || []

      by_customer =
        schedules
        |> Enum.sort_by(
          &(&1.scheduled_qty_mt * &1.penalty_per_mt_per_day),
          :desc
        )
        |> Enum.map(fn s ->
          status =
            cond do
              Enum.any?(deferred,    &String.contains?(s.counterparty, &1)) -> :deferred
              Enum.any?(prioritised, &String.contains?(s.counterparty, &1)) -> :priority
              s.direction == :purchase                                       -> :supplier
              s.next_window_days > 0                                         -> :future_window
              true                                                           -> :open_unaffected
            end

          # Estimate penalty only for deferred deliveries: assume 3-day slip past grace
          penalty_estimate =
            if status == :deferred do
              TradingDesk.Trader.DeliverySchedule.penalty_for_delay(
                s,
                s.grace_period_days + 3
              )
            else
              0.0
            end

          %{
            counterparty:     s.counterparty,
            status:           status,
            scheduled_qty_mt: s.scheduled_qty_mt,
            frequency:        to_string(s.frequency),
            next_window_days: s.next_window_days,
            direction:        s.direction,
            penalty_estimate: penalty_estimate
          }
        end)

      deferred_count        = Enum.count(by_customer, &(&1.status == :deferred))
      total_penalty_exposure = Enum.sum(Enum.map(by_customer, & &1.penalty_estimate))

      %{
        by_customer:            by_customer,
        deferred_count:         deferred_count,
        total_penalty_exposure: total_penalty_exposure
      }
    end
  end

  defp delivery_impact_icon(:deferred),       do: "⚠"
  defp delivery_impact_icon(:priority),       do: "✓"
  defp delivery_impact_icon(:supplier),       do: "↓"
  defp delivery_impact_icon(:future_window),  do: "·"
  defp delivery_impact_icon(:open_unaffected), do: "·"
  defp delivery_impact_icon(_),               do: "·"

  defp delivery_impact_style(:deferred),       do: "color:#fca5a5"
  defp delivery_impact_style(:priority),       do: "color:#4ade80"
  defp delivery_impact_style(:supplier),       do: "color:#60a5fa"
  defp delivery_impact_style(:future_window),  do: "color:#64748b"
  defp delivery_impact_style(:open_unaffected), do: "color:#64748b"
  defp delivery_impact_style(_),               do: "color:#64748b"

  defp delivery_impact_note(:priority),       do: "serve first"
  defp delivery_impact_note(:supplier),       do: "supplier delivery"
  defp delivery_impact_note(:future_window),  do: "future window"
  defp delivery_impact_note(:open_unaffected), do: "on schedule"
  defp delivery_impact_note(_),              do: "on schedule"

  # ── Model Summary Builder ───────────────────────────────────
  # Generates the structured text shown in the SCENARIO MODEL textarea.
  # Traders can edit this text and submit it as the scenario input.

  # Anonymize the model summary the same way IntentMapper will before sending to Claude.
  # Returns the anonymized text string (for display in the pre-solve review popup).
  defp build_anon_model_preview(model_summary, book) when is_binary(model_summary) do
    counterparty_names = TradingDesk.Anonymizer.counterparty_names(book)
    {anon_text, _} = TradingDesk.Anonymizer.anonymize(model_summary, counterparty_names)
    anon_text
  end
  defp build_anon_model_preview(_, _), do: ""

  defp build_model_summary_text(assigns) do
    frame         = assigns[:frame] || %{}
    vars          = assigns[:current_vars] || %{}
    overrides     = assigns[:overrides] || MapSet.new()
    objective     = assigns[:objective_mode] || :max_profit
    vessel_data   = assigns[:vessel_data]
    product_group = assigns[:product_group] || :ammonia_domestic
    description   = assigns[:scenario_description] || ""
    date          = Date.utc_today() |> Date.to_string()
    pg_name       = (frame[:name] || "Trading Desk") |> String.upcase()

    # Forecast data (may not be available)
    forecast = safe_call(fn -> LiveState.get_supplementary(:forecast) end, nil)

    # SAP positions (may not be available)
    book = safe_call(fn -> TradingDesk.Contracts.SapPositions.book_summary() end, nil)

    # Fleet vessels
    fleet = safe_call(fn -> TrackedVessel.list_active() end, [])

    desc_section =
      if description != "" do
        "SCENARIO: #{description}"
      else
        "SCENARIO: (none entered)"
      end

    """
    === #{pg_name} — #{date} ===
    Objective: #{objective_label(objective)}

    #{desc_section}

    #{build_variable_summary_text(frame[:variables] || [], vars, overrides)}
    #{build_forecast_summary_text(forecast)}
    #{build_routes_summary_text(frame[:routes] || [])}
    #{build_constraints_summary_text(frame[:constraints] || [], vars)}
    #{build_obligations_summary_text(product_group)}
    #{build_positions_summary_text(book)}
    #{build_fleet_summary_text(fleet, vessel_data)}
    """
    |> String.trim()
  end

  defp build_variable_summary_text(variable_defs, vars, overrides) do
    variable_defs
    |> Enum.group_by(& &1[:group])
    |> Enum.map_join("\n", fn {group, defs} ->
      header = "--- #{group |> to_string() |> String.upcase()} ---"
      lines  = Enum.map_join(defs, "\n", fn v ->
        val    = Map.get(vars, v[:key])
        status = if MapSet.member?(overrides, v[:key]), do: "[OVERRIDE]", else: "[LIVE]"
        formatted_val = case {v[:type], val} do
          {:boolean, true}  -> "OUTAGE"
          {:boolean, false} -> "ONLINE"
          {:boolean, 1.0}   -> "OUTAGE"
          {:boolean, 0.0}   -> "ONLINE"
          {_, fval} when is_float(fval) and abs(fval) >= 1000 ->
            format_number(fval)
          {_, fval} when is_float(fval) ->
            :erlang.float_to_binary(fval, [{:decimals, 1}])
          _ -> to_string(val)
        end
        unit = if v[:unit] && v[:unit] != "", do: " #{v[:unit]}", else: ""
        key_padded  = v[:key] |> to_string() |> String.pad_trailing(16)
        val_padded  = "#{formatted_val}#{unit}" |> String.pad_trailing(20)
        "#{key_padded}  #{val_padded} #{status}"
      end)
      "#{header}\n#{lines}"
    end)
  end

  defp build_forecast_summary_text(nil), do: ""
  defp build_forecast_summary_text(forecast) when is_map(forecast) do
    d3 = Map.get(forecast, :solver_d3) || %{}
    if map_size(d3) == 0 do
      ""
    else
      lines = Enum.map_join(d3, "\n", fn {k, v} ->
        label = k |> to_string() |> String.replace("forecast_", "") |> String.pad_trailing(20)
        formatted = if is_float(v), do: :erlang.float_to_binary(v, decimals: 1), else: to_string(v)
        "#{label}  #{formatted}"
      end)
      "--- FORECAST D+3 ---\n#{lines}"
    end
  end
  defp build_forecast_summary_text(_), do: ""

  defp build_routes_summary_text([]), do: ""
  defp build_routes_summary_text(routes) do
    lines = Enum.map_join(routes, "\n", fn r ->
      key  = (r[:key] || "route") |> to_string() |> String.pad_trailing(12)
      name = (r[:name] || "") |> String.pad_trailing(28)
      dist = "#{r[:distance_mi] || "?"}mi"
      days = "#{r[:typical_transit_days] || "?"}d"
      cap  = "#{round(r[:unit_capacity] || 0)}t/barge"
      "#{key}  #{name}  #{dist}  #{days}  #{cap}"
    end)
    "--- ROUTES ---\n#{lines}"
  end

  defp build_constraints_summary_text([], _vars), do: ""
  defp build_constraints_summary_text(constraints, vars) do
    lines = Enum.map_join(constraints, "\n", fn c ->
      bound_val = if c[:bound_variable], do: Map.get(vars, c[:bound_variable]), else: nil
      outage    = if c[:outage_variable], do: Map.get(vars, c[:outage_variable]), else: nil
      case c[:type] do
        :supply ->
          bound_str = if bound_val, do: " max #{round(bound_val)}t", else: ""
          routes_str = (c[:routes] || []) |> Enum.map_join(", ", &to_string/1)
          "#{c[:key]}  Supply#{bound_str} → [#{routes_str}]"
        :demand_cap ->
          bound_str = if bound_val, do: " max #{round(bound_val)}t", else: ""
          outage_str = case outage do
            true -> " (outage: YES)"
            1.0  -> " (outage: YES)"
            _    -> " (outage: NONE)"
          end
          dest = c[:destination] || ""
          "#{c[:key]}  Demand#{bound_str} → #{dest}#{outage_str}"
        :fleet_constraint ->
          bound_str = if bound_val, do: " max #{round(bound_val)} barges", else: ""
          "#{c[:key]}  Fleet#{bound_str} across all routes"
        :capital_constraint ->
          bound_str = if bound_val, do: " max $#{round(bound_val)}", else: ""
          "#{c[:key]}  Capital#{bound_str} across all routes"
        _ ->
          "#{c[:key]}  #{c[:name] || to_string(c[:type] || "custom")}"
      end
    end)
    "--- CONSTRAINTS ---\n#{lines}"
  end

  defp build_obligations_summary_text(product_group) do
    # Use :ammonia as the Store key (seed contracts are stored under :ammonia)
    store_key = if product_group == :ammonia_domestic, do: :ammonia, else: product_group

    penalty_sched =
      safe_call(fn ->
        TradingDesk.Contracts.ConstraintBridge.penalty_schedule(store_key)
      end, [])

    active_contracts =
      safe_call(fn ->
        TradingDesk.Contracts.Store.get_active_set(store_key)
      end, [])

    schedules = TradingDesk.Trader.DeliverySchedule.from_contracts(active_contracts)
    total_exposure = TradingDesk.Trader.DeliverySchedule.total_daily_exposure(schedules)

    if penalty_sched == [] and schedules == [] do
      ""
    else
      penalty_lines =
        if penalty_sched != [] do
          penalty_sched
          |> Enum.sort_by(& &1.max_exposure, :desc)
          |> Enum.map_join("\n", fn p ->
            type = p.penalty_type |> to_string() |> String.replace("_", " ")
            dir  = if p.counterparty_type == :supplier, do: "BUY", else: "SELL"
            rate = :erlang.float_to_binary(p.rate_per_ton / 1.0, decimals: 0)
            open = format_number(p.open_qty / 1.0)
            exp  = format_number(p.max_exposure / 1.0)
            "  #{p.counterparty}  #{dir}  #{type}  $#{rate}/MT  open=#{open} MT  max=$#{exp}"
          end)
        else
          "  (no penalty clauses in active contracts)"
        end

      schedule_lines =
        if schedules != [] do
          schedules
          |> Enum.sort_by(fn s -> s.scheduled_qty_mt * s.penalty_per_mt_per_day end, :desc)
          |> Enum.map_join("\n", fn s ->
            dir    = if s.direction == :purchase, do: "from", else: "to"
            daily  = s.scheduled_qty_mt * s.penalty_per_mt_per_day
            status = if s.next_window_days == 0, do: "WINDOW OPEN", else: "opens D+#{s.next_window_days}"
            rate   = :erlang.float_to_binary(s.penalty_per_mt_per_day / 1.0, decimals: 2)
            "  #{s.counterparty} #{dir}  #{round(s.scheduled_qty_mt)} MT " <>
            "grace=#{s.grace_period_days}d  $#{rate}/MT/day ($#{round(daily)}/day)  #{status}"
          end)
        else
          "  (no delivery schedule terms loaded)"
        end

      exposure_line =
        if total_exposure > 0 do
          "Total slip exposure: $#{format_number(total_exposure)}/day if all deliveries miss grace"
        else
          ""
        end

      penalty_lines_clean   = String.trim(penalty_lines)
      schedule_lines_clean  = String.trim(schedule_lines)
      exposure_line_clean   = String.trim(exposure_line)

      """
      --- OBLIGATIONS & PENALTIES ---
      Penalty clauses (solver reduces effective sell margin by weighted-avg rate):
      #{penalty_lines_clean}

      Delivery schedule obligations:
      #{schedule_lines_clean}
      #{if exposure_line_clean != "", do: "\n#{exposure_line_clean}", else: ""}
      """
      |> String.trim_trailing()
    end
  end

  defp build_positions_summary_text(nil), do: ""
  defp build_positions_summary_text(book) do
    header = "--- OPEN POSITIONS (SAP) ---\n" <>
      "Purchase open: #{format_number(book.total_purchase_open)} MT | " <>
      "Sale open: #{format_number(book.total_sale_open)} MT | " <>
      "Net: #{if book.net_position >= 0, do: "+", else: ""}#{format_number(book.net_position)} MT"
    rows = book.positions
      |> Enum.sort_by(fn {_k, v} -> v.open_qty_mt end, :desc)
      |> Enum.map_join("\n", fn {name, pos} ->
        dir  = if pos.direction == :purchase, do: "BUY ", else: "SELL"
        inc  = pos.incoterm |> to_string() |> String.upcase() |> String.pad_trailing(4)
        ctr  = format_number(pos.total_qty_mt) |> String.pad_leading(9)
        del  = format_number(pos.delivered_qty_mt) |> String.pad_leading(9)
        open = format_number(pos.open_qty_mt) |> String.pad_leading(9)
        num  = pos.contract_number || ""
        "#{name}  #{dir} #{inc}  contract=#{ctr} MT  delivered=#{del} MT  open=#{open} MT  [#{num}]"
      end)
    if rows == "", do: header, else: "#{header}\n#{rows}"
  end

  defp build_fleet_summary_text([], nil), do: ""
  defp build_fleet_summary_text(fleet, vessel_data) do
    vessel_lines = if is_list(fleet) and fleet != [] do
      Enum.map_join(fleet, "\n", fn v ->
        mmsi = v.mmsi || "?"
        name = v.vessel_name || "Unknown"
        pg   = v.product_group || "?"
        status = v.status || "active"
        "#{name}  MMSI:#{mmsi}  #{pg}  #{status}"
      end)
    else
      ""
    end

    ais_summary = case vessel_data do
      %{vessels: vessels} when is_list(vessels) and length(vessels) > 0 ->
        Enum.map_join(Enum.take(vessels, 5), "\n", fn v ->
          name  = v[:name] || "Unknown"
          mile  = v[:river_mile] && "mi #{v[:river_mile]}" || ""
          spd   = v[:speed_kn] && "#{v[:speed_kn]}kn" || ""
          "  AIS> #{name}  #{mile}  #{spd}"
        end)
      _ -> "  (no AIS position data)"
    end

    if vessel_lines == "" and ais_summary == "  (no AIS position data)" do
      ""
    else
      content = [vessel_lines, ais_summary]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      "--- FLEET (AIS TRACKING) ---\n#{content}"
    end
  end

  # Safe GenServer call — returns fallback if the service isn't running yet
  defp safe_call(fun, fallback) do
    try do
      fun.()
    catch
      :exit, _ -> fallback
      _, _ -> fallback
    end
  end
end
