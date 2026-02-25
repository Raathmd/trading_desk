defmodule TradingDesk.Solver.Pipeline do
  @moduledoc """
  Solve pipeline that ensures contract data is current before solving.

  Every solve goes through this pipeline:

    1. Check contract hashes against Graph API (via Zig scanner)
    2. If any contracts changed or are new:
       a. Notify caller: "waiting for contract LLM to ingest changes"
       b. Fetch changed files, extract via contract LLM, ingest
       c. Reload contract-derived variables
    3. Snapshot active contracts + variable sources (for audit)
    4. Frame solver input — LLM reads contract clauses + trader notes +
       current data and produces variable adjustments (falls back to
       mechanical ConstraintBridge if LLM unavailable)
    5. Run the LP solve (single or Monte Carlo) with framed data
    6. Write audit record (immutable — contract versions, variables, result)
    7. Return result

  Every pipeline execution writes a `SolveAudit` record capturing exactly
  which contract versions and variable values were used. This enables:

    - Auditing: which contract data drove a particular decision
    - DAG visualization: trace decision paths over time
    - Performance tracking: compare auto-runner vs trader decisions
    - Management reporting: product group and company-wide views

  The pipeline runs asynchronously. The dashboard subscribes to PubSub
  events and updates as each phase completes:

    :pipeline_started       — solve requested, checking contracts
    :pipeline_contracts_ok  — contracts current, framing now
    :pipeline_ingesting     — N contracts changed, ingesting first
    :pipeline_ingest_done   — ingestion complete, framing now
    :pipeline_framing       — LLM framing solver input from contracts + notes
    :pipeline_framed        — framing complete, N adjustments applied
    :pipeline_solving       — running solver with framed variables
    :pipeline_solve_done    — solve complete, result available
    :pipeline_error         — something failed

  ## Usage

      # From LiveView:
      Pipeline.solve_async(variables, product_group: :ammonia, trader_id: "trader@trammo.com")
      # Dashboard gets PubSub updates as phases complete

      # Synchronous (for AutoRunner):
      Pipeline.solve(variables, product_group: :ammonia, trigger: :auto_runner)
  """

  alias TradingDesk.Contracts.{ScanCoordinator, NetworkScanner, Store, SapPositions}
  alias TradingDesk.Solver.{Port, SolveAudit, SolveAuditStore}
  alias TradingDesk.LLM.PresolveFramer
  alias TradingDesk.Data.LiveState
  alias TradingDesk.ProductGroup

  require Logger

  @pubsub TradingDesk.PubSub
  @topic "solve_pipeline"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Run the full pipeline: check contracts → ingest changes → solve → audit.

  Options:
    :product_group   — which contracts to check (default: :ammonia)
    :mode            — :solve or :monte_carlo (default: :solve)
    :n_scenarios     — Monte Carlo scenario count (default: 1000)
    :skip_contracts  — skip contract check (default: false)
    :skip_framing    — skip LLM presolve framing (default: false)
    :trader_notes    — free-text instructions from the trader (passed to LLM framer)
    :caller_ref      — opaque reference passed through to events
    :trader_id       — who triggered this solve (nil for auto-runner)
    :trigger         — :dashboard | :auto_runner | :api | :scheduled
  """
  @spec run(TradingDesk.Variables.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(variables, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia)
    mode = Keyword.get(opts, :mode, :solve)
    n_scenarios = Keyword.get(opts, :n_scenarios, 1000)
    skip_contracts = Keyword.get(opts, :skip_contracts, false)
    skip_framing = Keyword.get(opts, :skip_framing, false)
    trader_notes = Keyword.get(opts, :trader_notes)
    caller_ref = Keyword.get(opts, :caller_ref)
    trader_id = Keyword.get(opts, :trader_id)
    trigger = Keyword.get(opts, :trigger, :dashboard)
    solver_opts = Keyword.get(opts, :solver_opts, [])

    run_id = generate_run_id()
    started_at = DateTime.utc_now()

    # Initialize audit record — will be populated as we go
    audit = %SolveAudit{
      id: run_id,
      mode: mode,
      product_group: product_group,
      trader_id: trader_id,
      trigger: trigger,
      caller_ref: caller_ref,
      variables: variables,
      variable_sources: SolveAudit.snapshot_variable_sources(),
      contracts_checked: false,
      contracts_stale: false,
      contracts_ingested: 0,
      started_at: started_at
    }

    broadcast(:pipeline_started, %{
      run_id: run_id,
      mode: mode,
      product_group: product_group,
      caller_ref: caller_ref
    })

    Logger.info("Pipeline #{run_id}: #{mode} for #{product_group}, solver_opts=#{inspect(solver_opts)}")

    # Phase 1: Contract freshness check
    {contract_result, audit} =
      if skip_contracts or not scanner_available?() do
        {{:ok, :skipped}, audit}
      else
        check_and_ingest_contracts(run_id, product_group, caller_ref, audit)
      end

    # Snapshot active contracts AFTER any ingestion (so we capture the latest versions)
    audit = %{audit |
      contracts_used: SolveAudit.snapshot_active_contracts(product_group),
      contracts_checked_at: if(audit.contracts_checked, do: DateTime.utc_now())
    }

    # Mark contract check result in audit
    audit = case contract_result do
      {:error, reason} ->
        Logger.warning("Pipeline #{run_id}: contract check failed (#{inspect(reason)}), solving with existing data")
        broadcast(:pipeline_contracts_stale, %{run_id: run_id, reason: reason, caller_ref: caller_ref})
        %{audit | contracts_stale: true, contracts_stale_reason: reason}
      {:ok, _} -> audit
    end

    # Phase 2: Presolve framing — LLM reads contracts + trader notes → variable adjustments
    {framed_variables, framing_report, audit} =
      frame_variables(variables, run_id, product_group, trader_notes, skip_framing, caller_ref, audit)

    # Phase 3: Solve with framed variables
    broadcast(:pipeline_solving, %{run_id: run_id, mode: mode, caller_ref: caller_ref})

    audit = %{audit | solve_started_at: DateTime.utc_now()}
    solve_result = execute_solve(framed_variables, product_group, mode, n_scenarios, solver_opts)

    case solve_result do
      {:ok, result} ->
        completed_at = DateTime.utc_now()
        audit = %{audit |
          result: result,
          result_status: extract_result_status(result, mode),
          completed_at: completed_at
        }

        write_audit(audit)

        broadcast(:pipeline_solve_done, %{
          run_id: run_id,
          mode: mode,
          result: result,
          audit_id: run_id,
          caller_ref: caller_ref,
          completed_at: completed_at,
          contracts_stale: audit.contracts_stale,
          framing_report: framing_report
        })

        {:ok, %{
          run_id: run_id,
          audit_id: run_id,
          result: result,
          mode: mode,
          contracts_checked: audit.contracts_checked,
          contracts_stale: audit.contracts_stale,
          framing_report: framing_report,
          completed_at: completed_at
        }}

      {:error, reason} ->
        audit = %{audit | result_status: :error, completed_at: DateTime.utc_now()}
        write_audit(audit)

        broadcast(:pipeline_error, %{
          run_id: run_id,
          phase: :solve,
          error: reason,
          caller_ref: caller_ref
        })
        {:error, {:solve_failed, reason}}
    end
  end

  @doc "Run pipeline asynchronously — broadcasts events to PubSub."
  def run_async(variables, opts \\ []) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> run(variables, opts) end
    )
  end

  @doc "Convenience: solve mode."
  def solve(variables, opts \\ []) do
    run(variables, Keyword.put(opts, :mode, :solve))
  end

  def solve_async(variables, opts \\ []) do
    run_async(variables, Keyword.put(opts, :mode, :solve))
  end

  @doc "Convenience: Monte Carlo mode."
  def monte_carlo(variables, opts \\ []) do
    run(variables, Keyword.put(opts, :mode, :monte_carlo))
  end

  def monte_carlo_async(variables, opts \\ []) do
    run_async(variables, Keyword.put(opts, :mode, :monte_carlo))
  end

  # ──────────────────────────────────────────────────────────
  # PHASE 1: CONTRACT FRESHNESS CHECK
  # ──────────────────────────────────────────────────────────

  defp check_and_ingest_contracts(run_id, product_group, caller_ref, audit) do
    contracts = Store.list_by_product_group(product_group)

    # Build list of contracts with Graph IDs and stored hashes
    known =
      contracts
      |> Enum.filter(fn c -> c.file_hash && c.graph_item_id && c.graph_drive_id end)
      |> Enum.map(fn c ->
        %{id: c.id, drive_id: c.graph_drive_id, item_id: c.graph_item_id, hash: c.file_hash}
      end)

    audit = %{audit | contracts_checked: true}

    if length(known) == 0 do
      broadcast(:pipeline_contracts_ok, %{
        run_id: run_id,
        message: "no contracts with Graph IDs to check",
        caller_ref: caller_ref
      })
      {{:ok, :no_contracts_to_check}, audit}
    else
      Logger.info("Pipeline #{run_id}: checking #{length(known)} contract hashes")

      case NetworkScanner.diff_hashes(known) do
        {:ok, diff} ->
          changed = Map.get(diff, "changed", [])
          missing = Map.get(diff, "missing", [])
          unchanged = Map.get(diff, "unchanged", [])

          if length(changed) == 0 and length(missing) == 0 do
            broadcast(:pipeline_contracts_ok, %{
              run_id: run_id,
              checked: length(unchanged),
              caller_ref: caller_ref
            })

            Logger.info("Pipeline #{run_id}: all #{length(unchanged)} contracts current")
            {{:ok, :all_current}, audit}
          else
            broadcast(:pipeline_ingesting, %{
              run_id: run_id,
              changed: length(changed),
              missing: length(missing),
              unchanged: length(unchanged),
              caller_ref: caller_ref
            })

            Logger.info(
              "Pipeline #{run_id}: #{length(changed)} changed, " <>
              "#{length(missing)} missing — ingesting before solve"
            )

            case ScanCoordinator.check_existing(product_group) do
              {:ok, ingest_result} ->
                ingested_count = ingest_result[:changed] || 0
                audit = %{audit |
                  contracts_ingested: ingested_count,
                  ingestion_completed_at: DateTime.utc_now()
                }

                broadcast(:pipeline_ingest_done, %{
                  run_id: run_id,
                  re_ingested: ingested_count,
                  caller_ref: caller_ref
                })

                Logger.info("Pipeline #{run_id}: ingestion complete, proceeding to solve")
                {{:ok, :ingested}, audit}

              {:error, reason} ->
                {{:error, {:ingest_failed, reason}}, audit}
            end
          end

        {:error, reason} ->
          {{:error, {:hash_check_failed, reason}}, audit}
      end
    end
  end

  # ──────────────────────────────────────────────────────────
  # PHASE 2: PRESOLVE FRAMING
  # ──────────────────────────────────────────────────────────

  defp frame_variables(variables, run_id, product_group, _trader_notes, true = _skip, _caller_ref, audit) do
    Logger.info("Pipeline #{run_id}: skipping presolve framing")
    var_map = ensure_var_map(variables, product_group)
    {var_map, nil, audit}
  end

  defp frame_variables(variables, run_id, product_group, trader_notes, _skip, caller_ref, audit) do
    var_map = ensure_var_map(variables, product_group)

    broadcast(:pipeline_framing, %{
      run_id: run_id,
      product_group: product_group,
      has_trader_notes: trader_notes != nil and trader_notes != "",
      caller_ref: caller_ref
    })

    Logger.info("Pipeline #{run_id}: presolve framing (contracts + trader notes → variable adjustments)")

    case PresolveFramer.frame(var_map, product_group: product_group, trader_notes: trader_notes) do
      {:ok, %{variables: framed, adjustments: adjustments} = report} ->
        n_adj = length(adjustments)

        broadcast(:pipeline_framed, %{
          run_id: run_id,
          adjustments: n_adj,
          warnings: length(Map.get(report, :warnings, [])),
          framing_notes: Map.get(report, :framing_notes),
          caller_ref: caller_ref
        })

        Logger.info("Pipeline #{run_id}: framing complete — #{n_adj} adjustment(s)")
        {framed, report, %{audit | framing_report: report, framing_completed_at: DateTime.utc_now()}}

      {:error, reason} ->
        Logger.warning("Pipeline #{run_id}: framing failed (#{inspect(reason)}), solving with unframed variables")

        broadcast(:pipeline_framed, %{
          run_id: run_id,
          adjustments: 0,
          warnings: ["Framing failed: #{inspect(reason)}"],
          caller_ref: caller_ref
        })

        {var_map, nil, audit}
    end
  end

  defp ensure_var_map(%TradingDesk.Variables{} = variables, product_group) do
    Map.merge(
      ProductGroup.default_values(product_group || :ammonia_domestic),
      Map.from_struct(variables)
    )
  end
  defp ensure_var_map(variables, _product_group) when is_map(variables), do: variables

  # ──────────────────────────────────────────────────────────
  # PHASE 3: EXECUTE SOLVE
  # ──────────────────────────────────────────────────────────

  defp execute_solve(variables, product_group, :solve, _n_scenarios, solver_opts) when is_map(variables) do
    Port.solve(product_group, variables, solver_opts)
  end

  defp execute_solve(variables, product_group, :monte_carlo, n_scenarios, solver_opts) when is_map(variables) do
    Port.monte_carlo(product_group, variables, n_scenarios, solver_opts)
  end

  # ──────────────────────────────────────────────────────────
  # AUDIT
  # ──────────────────────────────────────────────────────────

  defp write_audit(audit) do
    # ETS (fast, in-process — powers real-time queries and DAG visualization)
    case SolveAuditStore.record(audit) do
      {:ok, _} ->
        Logger.debug("Audit #{audit.id} recorded (#{audit.mode}, #{length(audit.contracts_used || [])} contracts)")

      error ->
        Logger.warning("Failed to write audit #{audit.id}: #{inspect(error)}")
    end

    # Postgres (durable, multi-node — powers audit trail and management reporting)
    TradingDesk.DB.Writer.persist_solve_audit(audit)

    # SQLite trade history (portable, chain-restorable — full normalized record)
    TradingDesk.TradeDB.Writer.persist_solve(audit)
  end

  defp extract_result_status(result, :solve) do
    Map.get(result, :status, :unknown)
  end

  defp extract_result_status(result, :monte_carlo) do
    Map.get(result, :signal, :unknown)
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp scanner_available? do
    try do
      NetworkScanner.available?()
    catch
      :exit, _ -> false
    end
  end

  defp generate_run_id do
    :crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:pipeline_event, event, payload})
  end

  # ──────────────────────────────────────────────────────────
  # SAP WRITE-BACK STUBS (req 10.4)
  # ──────────────────────────────────────────────────────────

  @doc """
  Create a contract in SAP based on solver outcome.

  This is the pipeline entry point for SAP write-back. The trader
  reviews a solver result, decides to act, and this pushes the action
  to SAP as a new contract or delivery.

  Delegates to SapPositions.create_contract/1.
  Currently a stub — does not call SAP.
  """
  def sap_create_contract(params) do
    SapPositions.create_contract(params)
  end

  @doc """
  Create a delivery in SAP under an existing contract.

  Delegates to SapPositions.create_delivery/1.
  Currently a stub — does not call SAP.
  """
  def sap_create_delivery(params) do
    SapPositions.create_delivery(params)
  end
end
