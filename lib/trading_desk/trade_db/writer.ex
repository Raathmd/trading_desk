defmodule TradingDesk.TradeDB.Writer do
  @moduledoc """
  Async writer for the SQLite trade history database.

  All public functions are non-blocking — writes are fired as Tasks under
  TradingDesk.Contracts.TaskSupervisor. Errors are logged, never raised,
  and never block the solve pipeline.

  ## Write sources

    - `persist_solve/1`          — called by Pipeline.write_audit/1 for every solve
    - `persist_auto_triggers/2`  — called by AutoRunner after each auto-solve
    - `persist_contract/1`       — called by DB.Writer alongside its Postgres write
    - `persist_config_change/3`  — called when DeltaConfig is updated by an admin

  ## What gets written per solve

    solves                   ← identity, timeline, trigger source, result summary
    solve_variables          ← all 20 variable values
    solve_variable_sources   ← API fetch timestamps (data freshness audit)
    solve_delta_config       ← thresholds + config active at solve time
    solve_results_single     ← LP result: profit, tons, barges, cost, ROI  (if :solve)
    solve_result_routes      ← per-route: origin→dest, tons, margin         (if :solve)
    solve_results_mc         ← MC distribution: signal, P5-P95              (if :monte_carlo)
    solve_mc_sensitivity     ← top 6 driver variables by |correlation|      (if :monte_carlo)
    solve_contracts          ← which contracts were active during this solve
    chain_commit_log         ← pending entry (stub — updated when chain is live)

  Then separately:
    auto_solve_triggers      ← per-variable trigger details (auto-runner only)
  """

  import Ecto.Query, warn: false
  import Bitwise, warn: false
  require Logger

  alias TradingDesk.TradeRepo

  alias TradingDesk.TradeDB.{
    Solve, SolveVariables, SolveVariableSources, SolveDeltaConfig,
    SolveResultSingle, SolveResultMc, SolveResultRoute, SolveMcSensitivity,
    AutoSolveTrigger, SolveContract,
    TradeContract, TradeContractClause,
    ChainCommitLog, ConfigChangeHistory
  }

  # Route index → {origin, destination}
  @routes %{
    0 => {"don", "stl"},
    1 => {"don", "mem"},
    2 => {"geis", "stl"},
    3 => {"geis", "mem"}
  }

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Persist a completed solve audit to SQLite. Async — returns immediately.

  Writes all normalized tables: solve record, variables, sources, delta config,
  result (single or MC), routes/sensitivity, contract links, and a pending
  chain commit stub.

  Called from Pipeline.write_audit/1 for both auto and manual solves.
  """
  @spec persist_solve(TradingDesk.Solver.SolveAudit.t()) :: :ok
  def persist_solve(%TradingDesk.Solver.SolveAudit{} = audit) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> do_persist_solve(audit) end
    )
    :ok
  end

  @doc """
  Persist auto-solve trigger details for a completed solve.

  Call this from AutoRunner with the trigger_details list after a solve
  completes. Updates the triggered_mask in solve_delta_config as well.

  The solve_id is the audit_id returned by the pipeline envelope.
  """
  @spec persist_auto_triggers(String.t(), [map()]) :: :ok
  def persist_auto_triggers(solve_id, trigger_details) when is_list(trigger_details) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> do_persist_triggers(solve_id, trigger_details) end
    )
    :ok
  end

  @doc """
  Persist a contract (and its clauses) to the SQLite trade history.

  Upserts on id, replacing mutable fields (status, sap data, clauses).
  Clauses are atomically replaced: delete existing, then insert current set.

  Call this from DB.Writer.persist_contract/1 alongside the Postgres write.
  """
  @spec persist_contract(TradingDesk.Contracts.Contract.t()) :: :ok
  def persist_contract(%TradingDesk.Contracts.Contract{} = contract) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> do_persist_contract(contract) end
    )
    :ok
  end

  @doc """
  Record an admin DeltaConfig change in the history log.

  `config` should be the full config map after the change.
  Optionally provide `field_changed`, `old_value`, and `new_value` for granular audit.
  """
  @spec persist_config_change(atom(), map(), keyword()) :: :ok
  def persist_config_change(product_group, config, opts \\ []) do
    admin_id = Keyword.get(opts, :admin_id)
    field_changed = Keyword.get(opts, :field_changed)
    old_value = Keyword.get(opts, :old_value)
    new_value = Keyword.get(opts, :new_value)

    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn ->
        attrs = %{
          product_group: to_string(product_group),
          admin_id: admin_id,
          changed_at: DateTime.utc_now(),
          field_changed: field_changed,
          old_value_json: encode_json(old_value),
          new_value_json: encode_json(new_value),
          full_config_json: encode_json!(config)
        }

        # Also stub a chain commit for this config change
        commit_id = make_commit_id()
        chain_attrs = %{
          id: commit_id,
          commit_type: ChainCommitLog.type_config_change(),
          product_group: to_string(product_group),
          signer_type: "server",
          signer_id: admin_id || "system",
          status: "pending"
        }

        %ChainCommitLog{}
        |> ChainCommitLog.changeset(chain_attrs)
        |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :id)

        %ConfigChangeHistory{}
        |> ConfigChangeHistory.changeset(Map.put(attrs, :chain_commit_id, commit_id))
        |> TradeRepo.insert()
        |> case do
          {:ok, _} -> :ok
          {:error, cs} ->
            Logger.warning("TradeDB: config change persist failed: #{inspect(cs.errors)}")
        end
      end
    )
    :ok
  end

  # ──────────────────────────────────────────────────────────
  # SOLVE PERSISTENCE
  # ──────────────────────────────────────────────────────────

  defp do_persist_solve(audit) do
    solve_type = if audit.mode == :monte_carlo, do: "monte_carlo", else: "single"
    is_auto = audit.trigger == :auto_runner
    pg = to_string(audit.product_group || :ammonia)

    # Step 1: Main solve row — must succeed before we write anything else
    solve_attrs = %{
      id: audit.id,
      solve_type: solve_type,
      trigger_source: to_string(audit.trigger || :unknown),
      product_group: pg,
      trader_id: audit.trader_id,
      is_auto_solve: is_auto,
      contracts_checked: audit.contracts_checked || false,
      contracts_stale: audit.contracts_stale || false,
      contracts_stale_reason: maybe_inspect(audit.contracts_stale_reason),
      contracts_ingested: audit.contracts_ingested || 0,
      result_status: to_string(audit.result_status || :unknown),
      started_at: audit.started_at,
      contracts_checked_at: audit.contracts_checked_at,
      ingestion_completed_at: audit.ingestion_completed_at,
      solve_started_at: audit.solve_started_at,
      completed_at: audit.completed_at
    }

    case %Solve{} |> Solve.changeset(solve_attrs) |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :id) do
      {:ok, _} ->
        # Steps 2-7 all depend on the solve row existing
        write_variables(audit.id, audit.variables)
        write_variable_sources(audit.id, audit.variable_sources)
        write_delta_config(audit.id, audit.product_group, is_auto)
        write_result(audit.id, audit.result, audit.mode)
        write_solve_contracts(audit.id, audit.contracts_used || [])
        write_chain_commit_stub(audit.id, audit.mode, is_auto, pg, audit.trader_id)

        Logger.debug("TradeDB: solve #{audit.id} persisted (#{audit.mode}, trigger=#{audit.trigger})")

      {:error, changeset} ->
        Logger.warning("TradeDB: solve #{audit.id} insert failed: #{inspect(changeset.errors)}")
    end
  rescue
    e -> Logger.error("TradeDB: solve persist crashed: #{Exception.message(e)}")
  end

  defp write_variables(_id, nil), do: :ok

  defp write_variables(solve_id, %TradingDesk.Variables{} = v) do
    attrs = %{
      solve_id: solve_id,
      river_stage: v.river_stage,
      lock_hrs: v.lock_hrs,
      temp_f: v.temp_f,
      wind_mph: v.wind_mph,
      vis_mi: v.vis_mi,
      precip_in: v.precip_in,
      inv_don: v.inv_don,
      inv_geis: v.inv_geis,
      stl_outage: v.stl_outage,
      mem_outage: v.mem_outage,
      barge_count: v.barge_count,
      nola_buy: v.nola_buy,
      sell_stl: v.sell_stl,
      sell_mem: v.sell_mem,
      fr_don_stl: v.fr_don_stl,
      fr_don_mem: v.fr_don_mem,
      fr_geis_stl: v.fr_geis_stl,
      fr_geis_mem: v.fr_geis_mem,
      nat_gas: v.nat_gas,
      working_cap: v.working_cap
    }

    %SolveVariables{}
    |> SolveVariables.changeset(attrs)
    |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :solve_id)
  rescue
    e -> Logger.warning("TradeDB: variables write failed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_variables(solve_id, vars) when is_map(vars) do
    # Convert string-keyed or atom-keyed map to struct
    atom_vars =
      Map.new(vars, fn {k, v} ->
        key = if is_binary(k), do: String.to_existing_atom(k), else: k
        {key, v}
      end)

    struct = struct(TradingDesk.Variables, atom_vars)
    write_variables(solve_id, struct)
  rescue
    _ -> Logger.warning("TradeDB: could not coerce variables map for #{solve_id}")
  end

  defp write_variable_sources(_id, nil), do: :ok

  defp write_variable_sources(solve_id, sources) when is_map(sources) do
    to_dt = fn key ->
      val = Map.get(sources, key) || Map.get(sources, to_string(key))
      case val do
        %DateTime{} = dt -> dt
        s when is_binary(s) ->
          case DateTime.from_iso8601(s) do
            {:ok, dt, _} -> dt
            _ -> nil
          end
        _ -> nil
      end
    end

    attrs = %{
      solve_id: solve_id,
      usgs_fetched_at: to_dt.(:usgs),
      noaa_fetched_at: to_dt.(:noaa),
      usace_fetched_at: to_dt.(:usace),
      eia_fetched_at: to_dt.(:eia),
      internal_fetched_at: to_dt.(:internal),
      broker_fetched_at: to_dt.(:broker),
      market_fetched_at: to_dt.(:market)
    }

    %SolveVariableSources{}
    |> SolveVariableSources.changeset(attrs)
    |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :solve_id)
  rescue
    e -> Logger.warning("TradeDB: variable sources write failed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_delta_config(solve_id, product_group, _is_auto) do
    config =
      try do
        TradingDesk.Config.DeltaConfig.get(product_group || :ammonia)
      rescue
        _ -> %{enabled: false, thresholds: %{}, n_scenarios: 1000, min_solve_interval_ms: 300_000}
      end

    thresholds = config[:thresholds] || config["thresholds"] || %{}

    attrs = %{
      solve_id: solve_id,
      enabled: config[:enabled] || false,
      n_scenarios: config[:n_scenarios] || 1000,
      min_solve_interval_ms: config[:min_solve_interval_ms] || 300_000,
      thresholds_json: encode_json!(thresholds),
      triggered_mask: 0   # updated later by persist_auto_triggers/2
    }

    %SolveDeltaConfig{}
    |> SolveDeltaConfig.changeset(attrs)
    |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :solve_id)
  rescue
    e -> Logger.warning("TradeDB: delta config write failed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_result(_id, nil, _mode), do: :ok

  defp write_result(solve_id, result, :solve) do
    attrs = %{
      solve_id: solve_id,
      status: to_string(get_in_result(result, :status) || :unknown),
      profit: get_in_result(result, :profit),
      tons: get_in_result(result, :tons),
      barges: get_in_result(result, :barges),
      cost: get_in_result(result, :cost),
      roi: get_in_result(result, :roi),
      eff_barge: get_in_result(result, :eff_barge)
    }

    case %SolveResultSingle{} |> SolveResultSingle.changeset(attrs) |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :solve_id) do
      {:ok, _} -> write_routes(solve_id, result)
      {:error, cs} -> Logger.warning("TradeDB: single result write failed for #{solve_id}: #{inspect(cs.errors)}")
    end
  rescue
    e -> Logger.warning("TradeDB: single result crashed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_result(solve_id, result, :monte_carlo) do
    attrs = %{
      solve_id: solve_id,
      signal: to_string(get_in_result(result, :signal) || :unknown),
      n_scenarios: get_in_result(result, :n_scenarios),
      n_feasible: get_in_result(result, :n_feasible),
      n_infeasible: get_in_result(result, :n_infeasible),
      mean: get_in_result(result, :mean),
      stddev: get_in_result(result, :stddev),
      p5: get_in_result(result, :p5),
      p25: get_in_result(result, :p25),
      p50: get_in_result(result, :p50),
      p75: get_in_result(result, :p75),
      p95: get_in_result(result, :p95),
      min_profit: get_in_result(result, :min),
      max_profit: get_in_result(result, :max)
    }

    case %SolveResultMc{} |> SolveResultMc.changeset(attrs) |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :solve_id) do
      {:ok, _} -> write_sensitivity(solve_id, get_in_result(result, :sensitivity))
      {:error, cs} -> Logger.warning("TradeDB: MC result write failed for #{solve_id}: #{inspect(cs.errors)}")
    end
  rescue
    e -> Logger.warning("TradeDB: MC result crashed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_routes(solve_id, result) do
    route_tons = list_field(result, :route_tons)
    route_profits = list_field(result, :route_profits)
    margins = list_field(result, :margins)
    transits = list_field(result, :transits)
    shadow_prices = list_field(result, :shadow_prices)

    for {idx, {origin, dest}} <- @routes do
      tons = Enum.at(route_tons, idx)

      if tons && tons > 0 do
        %SolveResultRoute{}
        |> SolveResultRoute.changeset(%{
          solve_id: solve_id,
          route_index: idx,
          origin: origin,
          destination: dest,
          tons: tons,
          profit: Enum.at(route_profits, idx),
          margin: Enum.at(margins, idx),
          transit_days: Enum.at(transits, idx),
          shadow_price: Enum.at(shadow_prices, idx)
        })
        |> TradeRepo.insert()
      end
    end
  rescue
    e -> Logger.warning("TradeDB: routes write failed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_sensitivity(_id, nil), do: :ok
  defp write_sensitivity(_id, []), do: :ok

  defp write_sensitivity(solve_id, sensitivity) when is_list(sensitivity) do
    sensitivity
    |> Enum.with_index(1)
    |> Enum.each(fn {{var_key, correlation}, rank} ->
      %SolveMcSensitivity{}
      |> SolveMcSensitivity.changeset(%{
        solve_id: solve_id,
        variable_key: to_string(var_key),
        correlation: correlation,
        rank: rank
      })
      |> TradeRepo.insert()
    end)
  rescue
    e -> Logger.warning("TradeDB: sensitivity write failed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_solve_contracts(solve_id, contracts) when is_list(contracts) do
    Enum.each(contracts, fn snap ->
      contract_id = snap[:id] || Map.get(snap, "id")
      if contract_id do
        %SolveContract{}
        |> SolveContract.changeset(%{
          solve_id: solve_id,
          contract_id: contract_id,
          counterparty: snap[:counterparty] || Map.get(snap, "counterparty"),
          contract_version: snap[:version] || Map.get(snap, "version"),
          open_position: snap[:open_position] || Map.get(snap, "open_position")
        })
        |> TradeRepo.insert(on_conflict: :nothing, conflict_target: [:solve_id, :contract_id])
      end
    end)
  rescue
    e -> Logger.warning("TradeDB: solve_contracts write failed for #{solve_id}: #{Exception.message(e)}")
  end

  defp write_chain_commit_stub(solve_id, mode, is_auto, product_group, trader_id) do
    commit_type =
      cond do
        is_auto && mode == :monte_carlo -> ChainCommitLog.type_auto_mc()
        is_auto -> ChainCommitLog.type_auto_solve()
        mode == :monte_carlo -> ChainCommitLog.type_mc()
        true -> ChainCommitLog.type_solve()
      end

    commit_id = make_commit_id()

    case %ChainCommitLog{}
         |> ChainCommitLog.changeset(%{
           id: commit_id,
           solve_id: solve_id,
           commit_type: commit_type,
           product_group: product_group,
           signer_type: if(is_auto, do: "server", else: "trader"),
           signer_id: trader_id || "system",
           status: "pending"
         })
         |> TradeRepo.insert() do
      {:ok, _} ->
        # Back-link the solve row to its chain commit
        TradeRepo.update_all(
          from(s in Solve, where: s.id == ^solve_id),
          set: [chain_commit_id: commit_id]
        )

      {:error, cs} ->
        Logger.warning("TradeDB: chain commit stub failed for #{solve_id}: #{inspect(cs.errors)}")
    end
  rescue
    e -> Logger.warning("TradeDB: chain commit stub crashed for #{solve_id}: #{Exception.message(e)}")
  end

  # ──────────────────────────────────────────────────────────
  # TRIGGER PERSISTENCE (auto-runner only)
  # ──────────────────────────────────────────────────────────

  defp do_persist_triggers(solve_id, trigger_details) do
    triggered_mask =
      Enum.reduce(trigger_details, 0, fn t, acc ->
        idx = t[:variable_index] || 0
        bor(acc, bsl(1, idx))
      end)

    # Update the delta config snapshot with the actual triggered mask
    TradeRepo.update_all(
      from(dc in SolveDeltaConfig, where: dc.solve_id == ^solve_id),
      set: [triggered_mask: triggered_mask]
    )

    Enum.each(trigger_details, fn t ->
      delta = t[:delta] || (t[:current_value] - (t[:baseline_value] || 0.0))

      %AutoSolveTrigger{}
      |> AutoSolveTrigger.changeset(%{
        solve_id: solve_id,
        variable_key: to_string(t[:key] || t[:variable_key] || "unknown"),
        variable_index: t[:variable_index],
        baseline_value: t[:baseline_value],
        current_value: t[:current_value],
        threshold: t[:threshold],
        delta: delta,
        direction: if(delta >= 0, do: "up", else: "down")
      })
      |> TradeRepo.insert()
    end)

    Logger.debug("TradeDB: #{length(trigger_details)} triggers persisted for solve #{solve_id}")
  rescue
    e -> Logger.error("TradeDB: trigger persist crashed: #{Exception.message(e)}")
  end

  # ──────────────────────────────────────────────────────────
  # CONTRACT PERSISTENCE
  # ──────────────────────────────────────────────────────────

  defp do_persist_contract(contract) do
    now = DateTime.utc_now()

    attrs = %{
      id: contract.id,
      counterparty: contract.counterparty,
      counterparty_type: maybe_to_string(contract.counterparty_type),
      product_group: to_string(contract.product_group),
      version: contract.version || 1,
      status: to_string(contract.status || :draft),
      template_type: maybe_to_string(contract.template_type),
      incoterm: maybe_to_string(contract.incoterm),
      term_type: maybe_to_string(contract.term_type),
      company: maybe_to_string(contract.company),
      contract_date: contract.contract_date,
      expiry_date: contract.expiry_date,
      contract_number: contract.contract_number,
      family_id: contract.family_id,
      source_file: contract.source_file,
      source_format: maybe_to_string(contract.source_format),
      file_hash: contract.file_hash,
      file_size: contract.file_size,
      network_path: contract.network_path,
      graph_item_id: contract.graph_item_id,
      graph_drive_id: contract.graph_drive_id,
      sap_contract_id: contract.sap_contract_id,
      sap_validated: contract.sap_validated || false,
      open_position: contract.open_position,
      sap_discrepancies_json: encode_json(contract.sap_discrepancies),
      reviewed_by: contract.reviewed_by,
      reviewed_at: contract.reviewed_at,
      review_notes: contract.review_notes,
      verification_status: maybe_to_string(contract.verification_status),
      last_verified_at: contract.last_verified_at,
      previous_hash: contract.previous_hash,
      clauses_json: encode_clauses(contract.clauses),
      template_validation_json: encode_json(contract.template_validation),
      llm_validation_json: encode_json(contract.llm_validation),
      scan_date: contract.scan_date,
      created_at: contract.created_at || now,
      updated_at: contract.updated_at || now
    }

    # Mutable fields to update on conflict (ID + version are immutable once written)
    updatable = [
      :status, :sap_validated, :open_position, :sap_discrepancies_json,
      :verification_status, :last_verified_at, :clauses_json,
      :template_validation_json, :llm_validation_json,
      :reviewed_by, :reviewed_at, :review_notes, :updated_at
    ]

    case %TradeContract{}
         |> TradeContract.changeset(attrs)
         |> TradeRepo.insert(on_conflict: {:replace, updatable}, conflict_target: :id) do
      {:ok, _} ->
        write_contract_clauses(contract.id, contract.clauses || [])
        Logger.debug("TradeDB: contract #{contract.id} persisted (#{contract.counterparty} v#{contract.version})")

      {:error, cs} ->
        Logger.warning("TradeDB: contract #{contract.id} persist failed: #{inspect(cs.errors)}")
    end
  rescue
    e -> Logger.error("TradeDB: contract persist crashed: #{Exception.message(e)}")
  end

  defp write_contract_clauses(contract_id, clauses) when is_list(clauses) do
    # Atomic replace: delete all existing, then insert current set
    TradeRepo.delete_all(from(c in TradeContractClause, where: c.contract_id == ^contract_id))

    Enum.each(clauses, fn clause ->
      clause_id =
        clause_field(clause, :id) ||
          (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

      attrs = %{
        id: clause_id,
        contract_id: contract_id,
        clause_id: clause_field(clause, :clause_id),
        clause_type: maybe_to_string(clause_field(clause, :type)),
        category: maybe_to_string(clause_field(clause, :category)),
        description: clause_field(clause, :description),
        parameter: maybe_to_string(clause_field(clause, :parameter)),
        operator: maybe_to_string(clause_field(clause, :operator)),
        value: clause_field(clause, :value),
        value_upper: clause_field(clause, :value_upper),
        unit: clause_field(clause, :unit),
        penalty_per_unit: clause_field(clause, :penalty_per_unit),
        penalty_cap: clause_field(clause, :penalty_cap),
        period: maybe_to_string(clause_field(clause, :period)),
        confidence: maybe_to_string(clause_field(clause, :confidence)),
        reference_section: clause_field(clause, :reference_section),
        extracted_at: clause_field(clause, :extracted_at)
      }

      %TradeContractClause{}
      |> TradeContractClause.changeset(attrs)
      |> TradeRepo.insert(on_conflict: :nothing, conflict_target: :id)
    end)
  rescue
    e -> Logger.warning("TradeDB: clauses write failed for #{contract_id}: #{Exception.message(e)}")
  end

  defp write_contract_clauses(_, _), do: :ok

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp get_in_result(%_{} = struct, key), do: Map.get(struct, key)
  defp get_in_result(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp get_in_result(_, _), do: nil

  defp list_field(result, key) do
    val = get_in_result(result, key)
    if is_list(val), do: val, else: []
  end

  defp clause_field(%_{} = struct, key), do: Map.get(struct, key)
  defp clause_field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp clause_field(_, _), do: nil

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(v), do: to_string(v)

  defp maybe_inspect(nil), do: nil
  defp maybe_inspect(v) when is_binary(v), do: v
  defp maybe_inspect(v), do: inspect(v)

  defp encode_json(nil), do: nil
  defp encode_json(v) when is_map(v) or is_list(v) do
    Jason.encode!(v)
  rescue
    _ -> nil
  end
  defp encode_json(_), do: nil

  defp encode_json!(v) do
    Jason.encode!(v)
  rescue
    _ -> "{}"
  end

  defp encode_clauses(nil), do: "[]"
  defp encode_clauses(clauses) when is_list(clauses) do
    Jason.encode!(Enum.map(clauses, fn c ->
      if is_struct(c), do: Map.from_struct(c), else: c
    end))
  rescue
    _ -> "[]"
  end
  defp encode_clauses(_), do: "[]"

  defp make_commit_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
