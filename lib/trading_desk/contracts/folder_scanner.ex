defmodule TradingDesk.Contracts.FolderScanner do
  @moduledoc """
  Monitors a local server folder for contract files and syncs with the database.

  ## The Flow

  1. Scan configured folder for supported files (.pdf, .docx, .docm, .txt)
  2. Compute SHA-256 hash for each file on disk
  3. Compare against contracts in the database:
     - **New file** (hash not in DB)        → extract via Copilot LLM (fallback: Parser)
     - **Changed file** (same name, new hash) → re-extract via Copilot, delete old schedules
     - **Missing file** (in DB, not on disk)  → soft-delete (set deleted_at)
  4. Generate scheduled deliveries for each ingested contract

  ## Clause extraction

  New and changed files are sent through **CopilotClient LLM extraction** first,
  which captures nuanced clause changes (pricing, penalties, delivery terms) that
  affect solver input via the ConstraintBridge. If Copilot is unavailable, falls
  back to the deterministic Parser via Inventory.ingest_file/2.

  5. SAP-closed contracts are also soft-deleted

  ## Contract key

  The `file_hash` (SHA-256) acts as the version key linking contracts to their
  scheduled deliveries. When a file is reimported with a new hash, new schedule
  records are created and old ones physically deleted.

  ## Configuration

  Set `CONTRACT_WATCH_DIR` env var to the folder path. Defaults to
  `priv/contracts` in dev.
  """

  alias TradingDesk.Contracts.{
    CopilotClient,
    CopilotIngestion,
    DocumentReader,
    HashVerifier,
    Inventory,
    SapPositions,
    Store
  }

  alias TradingDesk.DB.ScheduledDelivery
  alias TradingDesk.Schedule.DeliveryScheduler
  alias TradingDesk.Repo

  import Ecto.Query

  require Logger

  @supported_extensions ~w(.pdf .docx .docm .txt)
  @pubsub TradingDesk.PubSub
  @topic "contracts"

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Run a full folder scan for the given product group.

  Scans the configured watch directory, compares file hashes against
  the database, ingests new/changed files, and soft-deletes missing ones.

  Returns {:ok, summary} with counts of new, changed, removed, unchanged.
  """
  @spec scan(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def scan(product_group \\ :ammonia, opts \\ []) do
    dir = Keyword.get(opts, :directory) || watch_dir()

    unless File.dir?(dir) do
      {:error, {:directory_not_found, dir}}
    else
      Logger.info("FolderScanner: scanning #{dir} for #{product_group}")
      broadcast(:folder_scan_started, %{directory: dir, product_group: product_group})

      disk_files = list_files(dir)
      db_contracts = active_contracts(product_group)

      {new_files, changed_files, unchanged_files, missing_contracts} =
        classify(disk_files, db_contracts)

      # Ingest new files
      new_results = Enum.map(new_files, fn {path, _hash} ->
        ingest_new(path, product_group, opts)
      end)

      # Re-ingest changed files (delete old schedules, create new)
      changed_results = Enum.map(changed_files, fn {path, _new_hash, contract} ->
        reingest_changed(path, contract, product_group, opts)
      end)

      # Soft-delete contracts whose files are missing from disk
      removed_count = soft_delete_missing(missing_contracts, :file_removed)

      summary = %{
        directory: dir,
        product_group: product_group,
        new_ingested: Enum.count(new_results, &match?({:ok, _}, &1)),
        new_failed: Enum.count(new_results, &match?({:error, _}, &1)),
        re_ingested: Enum.count(changed_results, &match?({:ok, _}, &1)),
        re_ingest_failed: Enum.count(changed_results, &match?({:error, _}, &1)),
        removed: removed_count,
        unchanged: length(unchanged_files),
        scanned_at: DateTime.utc_now()
      }

      broadcast(:folder_scan_complete, summary)
      Logger.info(
        "FolderScanner: #{summary.new_ingested} new, #{summary.re_ingested} updated, " <>
        "#{summary.removed} removed, #{summary.unchanged} unchanged"
      )

      {:ok, summary}
    end
  end

  @doc """
  Reimport all files from the watch folder.

  Clears ALL scheduled deliveries for the product group, then re-scans
  and re-ingests every file as if starting fresh.
  """
  @spec reimport_all(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def reimport_all(product_group \\ :ammonia, opts \\ []) do
    Logger.info("FolderScanner: REIMPORT ALL for #{product_group}")
    broadcast(:reimport_started, %{product_group: product_group})

    # Step 1: Delete all scheduled deliveries for this product group
    deleted_count = clear_schedules(product_group)
    Logger.info("FolderScanner: cleared #{deleted_count} scheduled deliveries")

    # Step 2: Full scan (will ingest everything as new since we don't
    # reset the contracts table — but changed hashes create new versions)
    result = scan(product_group, opts)

    case result do
      {:ok, summary} ->
        summary = Map.put(summary, :schedules_cleared, deleted_count)
        broadcast(:reimport_complete, summary)
        {:ok, summary}

      error ->
        error
    end
  end

  @doc "Run scan in background."
  def scan_async(product_group \\ :ammonia, opts \\ []) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> scan(product_group, opts) end
    )
  end

  @doc "Run reimport in background."
  def reimport_all_async(product_group \\ :ammonia, opts \\ []) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn -> reimport_all(product_group, opts) end
    )
  end

  @doc """
  Soft-delete contracts that SAP reports as closed.

  Takes a list of SAP contract IDs that are closed and marks the
  corresponding contracts as logically deleted.
  """
  @spec mark_sap_closed([String.t()]) :: non_neg_integer()
  def mark_sap_closed(closed_sap_ids) when is_list(closed_sap_ids) do
    contracts =
      Store.list_all()
      |> Enum.filter(fn c ->
        c.sap_contract_id in closed_sap_ids and is_nil(Map.get(c, :deleted_at))
      end)

    soft_delete_missing(contracts, :sap_closed)
  end

  @doc "Get the configured watch directory."
  @spec watch_dir() :: String.t()
  def watch_dir do
    System.get_env("CONTRACT_WATCH_DIR") ||
      Path.join(:code.priv_dir(:trading_desk) |> to_string(), "contracts")
  end

  # ──────────────────────────────────────────────────────────
  # SCHEDULE MANAGEMENT
  # ──────────────────────────────────────────────────────────

  @doc """
  Delete all scheduled deliveries for a product group.
  Returns the number of deleted records.
  """
  @spec clear_schedules(atom()) :: non_neg_integer()
  def clear_schedules(product_group) do
    pg = to_string(product_group)

    {count, _} =
      from(sd in ScheduledDelivery, where: sd.product_group == ^pg)
      |> Repo.delete_all()

    count
  end

  @doc """
  Delete scheduled deliveries linked to a specific contract hash.
  Used when a contract file is reimported with a new hash.
  """
  @spec clear_schedules_for_hash(String.t()) :: non_neg_integer()
  def clear_schedules_for_hash(contract_hash) do
    {count, _} =
      from(sd in ScheduledDelivery, where: sd.contract_hash == ^contract_hash)
      |> Repo.delete_all()

    count
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: FILE LISTING
  # ──────────────────────────────────────────────────────────

  defp list_files(dir) do
    File.ls!(dir)
    |> Enum.filter(fn f ->
      path = Path.join(dir, f)
      not File.dir?(path) and (Path.extname(f) |> String.downcase()) in @supported_extensions
    end)
    |> Enum.sort()
    |> Enum.map(fn filename ->
      path = Path.join(dir, filename)

      case HashVerifier.compute_file_hash(path) do
        {:ok, hash, _size} -> {path, hash}
        {:error, reason} ->
          Logger.warning("FolderScanner: cannot hash #{filename}: #{inspect(reason)}")
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: CLASSIFICATION
  # ──────────────────────────────────────────────────────────

  defp classify(disk_files, db_contracts) do
    # Build lookups
    by_hash = Map.new(db_contracts, fn c -> {c.file_hash, c} end)
    by_source = Map.new(db_contracts, fn c -> {c.source_file, c} end)

    # Track which DB contracts are accounted for
    matched_ids = MapSet.new()

    {new, changed, unchanged, matched_ids} =
      Enum.reduce(disk_files, {[], [], [], matched_ids}, fn {path, disk_hash}, {n, ch, unch, matched} ->
        filename = Path.basename(path)

        cond do
          # Exact hash match — file unchanged
          Map.has_key?(by_hash, disk_hash) ->
            contract = by_hash[disk_hash]
            {n, ch, [{path, disk_hash, contract} | unch], MapSet.put(matched, contract.id)}

          # Same filename but different hash — file changed
          Map.has_key?(by_source, filename) ->
            contract = by_source[filename]
            {n, [{path, disk_hash, contract} | ch], unch, MapSet.put(matched, contract.id)}

          # Not in DB at all — new file
          true ->
            {[{path, disk_hash} | n], ch, unch, matched}
        end
      end)

    # Contracts in DB but not on disk (and not soft-deleted already)
    missing =
      db_contracts
      |> Enum.reject(fn c -> MapSet.member?(matched_ids, c.id) end)

    {Enum.reverse(new), Enum.reverse(changed), Enum.reverse(unchanged), missing}
  end

  defp active_contracts(product_group) do
    Store.list_by_product_group(product_group)
    |> Enum.reject(fn c -> Map.get(c, :deleted_at) != nil end)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: INGESTION
  # ──────────────────────────────────────────────────────────

  defp ingest_new(path, product_group, _opts) do
    filename = Path.basename(path)
    Logger.info("FolderScanner: ingesting new file #{filename}")

    result = copilot_extract_and_ingest(path, product_group, [
      counterparty: Inventory.derive_counterparty_from_filename(filename),
      counterparty_type: :customer,
      network_path: path
    ])

    case result do
      {:ok, contract} ->
        broadcast(:clauses_changed, %{
          contract_id: contract.id,
          counterparty: contract.counterparty,
          product_group: product_group,
          reason: :new_file,
          clause_count: length(contract.clauses || [])
        })

        {:ok, contract}

      error ->
        error
    end
  end

  defp reingest_changed(path, old_contract, product_group, _opts) do
    filename = Path.basename(path)
    Logger.info("FolderScanner: re-ingesting changed file #{filename} (was v#{old_contract.version})")

    # Delete old scheduled deliveries for the previous hash
    if old_contract.file_hash do
      cleared = clear_schedules_for_hash(old_contract.file_hash)
      Logger.info("FolderScanner: cleared #{cleared} old schedule records for hash #{String.slice(old_contract.file_hash, 0, 12)}...")
    end

    result = copilot_extract_and_ingest(path, product_group, [
      counterparty: old_contract.counterparty,
      counterparty_type: old_contract.counterparty_type,
      template_type: old_contract.template_type,
      incoterm: old_contract.incoterm,
      term_type: old_contract.term_type,
      company: old_contract.company,
      contract_date: old_contract.contract_date,
      expiry_date: old_contract.expiry_date,
      sap_contract_id: old_contract.sap_contract_id,
      network_path: path
    ])

    case result do
      {:ok, contract} ->
        broadcast(:clauses_changed, %{
          contract_id: contract.id,
          counterparty: contract.counterparty,
          product_group: product_group,
          reason: :file_changed,
          previous_version: old_contract.version,
          clause_count: length(contract.clauses || [])
        })

        {:ok, contract}

      error ->
        error
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: COPILOT-FIRST EXTRACTION
  #
  # Tries CopilotClient LLM extraction first so clause changes
  # (pricing, penalties, delivery terms) are fully captured for
  # the solver's ConstraintBridge. Falls back to deterministic
  # Parser via Inventory.ingest_file if Copilot is unavailable.
  # ──────────────────────────────────────────────────────────

  defp copilot_extract_and_ingest(path, product_group, opts) do
    filename = Path.basename(path)

    case extract_via_copilot(path) do
      {:ok, extraction} ->
        Logger.info("FolderScanner: Copilot extraction succeeded for #{filename}")
        ingest_copilot_extraction(path, extraction, product_group, opts)

      {:error, reason} ->
        Logger.info(
          "FolderScanner: Copilot unavailable for #{filename} (#{inspect(reason)}), " <>
          "falling back to deterministic parser"
        )

        Inventory.ingest_file(path, Keyword.put(opts, :product_group, product_group))
    end
  end

  # Read local file → send text to Copilot LLM for clause extraction
  defp extract_via_copilot(path) do
    with {:ok, text} <- DocumentReader.read(path),
         {:ok, extraction} <- CopilotClient.extract_text(text) do
      {:ok, extraction}
    end
  end

  # Ingest Copilot extraction as a versioned contract, then generate schedule
  defp ingest_copilot_extraction(path, extraction, product_group, opts) do
    copilot_opts = [
      product_group: product_group,
      network_path: Keyword.get(opts, :network_path, path),
      sap_contract_id: Keyword.get(opts, :sap_contract_id)
    ]

    case CopilotIngestion.ingest(path, extraction, copilot_opts) do
      {:ok, contract} ->
        # Generate scheduled deliveries (same as Inventory does, but CopilotIngestion doesn't)
        schedule_deliveries_async(contract)
        {:ok, contract}

      {:error, reason} ->
        Logger.warning("FolderScanner: Copilot ingestion failed (#{inspect(reason)}), falling back to parser")
        fallback_opts = Keyword.put(opts, :product_group, product_group)
        Inventory.ingest_file(path, fallback_opts)
    end
  end

  # Fetch SAP open position and generate scheduled deliveries (async, non-blocking)
  defp schedule_deliveries_async(contract) do
    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn ->
        with_position = fetch_sap_position(contract)
        DeliveryScheduler.generate_from_contract(with_position)
      end
    )
  end

  defp fetch_sap_position(contract) do
    case SapPositions.fetch_position(contract.counterparty) do
      {:ok, pos} when is_map(pos) ->
        open_qty = pos.open_qty_mt || pos[:open_quantity] || 0.0
        Store.update_open_position(contract.counterparty, contract.product_group, open_qty)
        %{contract | open_position: open_qty}

      _ ->
        Logger.debug("FolderScanner: SAP position unavailable for #{contract.counterparty}")
        contract
    end
  rescue
    _ -> contract
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: SOFT-DELETE
  # ──────────────────────────────────────────────────────────

  defp soft_delete_missing(contracts, reason) do
    now = DateTime.utc_now()

    Enum.each(contracts, fn contract ->
      updated = %{contract |
        deleted_at: now,
        deletion_reason: reason,
        updated_at: now
      }

      # Update in ETS
      Store.soft_delete(contract.id, reason)

      # Update in Postgres
      TradingDesk.DB.Writer.persist_contract(updated)

      Logger.info("FolderScanner: soft-deleted #{contract.counterparty} v#{contract.version} (#{reason})")
    end)

    length(contracts)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE: PUBSUB
  # ──────────────────────────────────────────────────────────

  defp broadcast(event, payload) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:contract_event, event, payload})
  end
end
