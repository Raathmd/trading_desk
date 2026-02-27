defmodule TradingDesk.HistoricalBackfillLive do
  @moduledoc """
  Historical Backfill LiveView — Phase 4.

  Three-phase workflow for uploading SAP contract history files,
  processing them through LLM framing, and generating contract
  execution vectors.

    1. UPLOAD     — select product group + upload CSV/JSON files
    2. PROCESSING — real-time progress via PubSub as Oban workers run
    3. COMPLETE   — summary of contracts processed, vectors created, errors
  """
  use Phoenix.LiveView
  require Logger

  alias TradingDesk.Repo
  alias TradingDesk.Vectorization.{BackfillJob, BackfillFileWorker}

  @product_groups [
    {"Ammonia Domestic", "ammonia_domestic"},
    {"Sulphur International", "sulphur_international"},
    {"Petcoke", "petcoke"},
    {"Ammonia International", "ammonia_international"}
  ]

  # ── Mount ────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:phase, :upload)
      |> assign(:product_groups, @product_groups)
      |> assign(:selected_product_group, "ammonia_domestic")
      |> assign(:job, nil)
      |> assign(:processing_logs, [])
      |> assign(:file_statuses, %{})
      |> assign(:summary, nil)
      |> assign(:error_message, nil)
      |> allow_upload(:sap_files,
        accept: ~w(.csv .json),
        max_entries: 50,
        max_file_size: 100_000_000
      )

    {:ok, socket}
  end

  # ── Events: Upload Phase ─────────────────────────────────────

  @impl true
  def handle_event("select_product_group", %{"product_group" => pg}, socket) do
    {:noreply, assign(socket, :selected_product_group, pg)}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :sap_files, ref)}
  end

  @impl true
  def handle_event("start_processing", _params, socket) do
    entries = socket.assigns.uploads.sap_files.entries

    if Enum.empty?(entries) do
      {:noreply, assign(socket, :error_message, "Please select at least one file to upload.")}
    else
      # Validate all entries — abort if any have errors
      errors =
        Enum.filter(entries, fn entry -> entry.valid? == false end)

      if Enum.any?(errors) do
        {:noreply, assign(socket, :error_message, "Some files have validation errors. Please fix or remove them.")}
      else
        process_uploads(socket)
      end
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    socket =
      socket
      |> assign(:phase, :upload)
      |> assign(:job, nil)
      |> assign(:processing_logs, [])
      |> assign(:file_statuses, %{})
      |> assign(:summary, nil)
      |> assign(:error_message, nil)
      |> allow_upload(:sap_files,
        accept: ~w(.csv .json),
        max_entries: 50,
        max_file_size: 100_000_000
      )

    {:noreply, socket}
  end

  # ── PubSub: Processing Updates ───────────────────────────────

  @impl true
  def handle_info({:backfill_update, %{type: :file_status, data: data}}, socket) do
    file_statuses = Map.put(socket.assigns.file_statuses, data.filename, data.status)

    log_entry = %{
      timestamp: DateTime.utc_now(),
      filename: data.filename,
      type: :file_status,
      message: "File #{data.filename}: #{data.status}",
      status: data.status
    }

    {:noreply,
     socket
     |> assign(:file_statuses, file_statuses)
     |> update(:processing_logs, &[log_entry | &1])}
  end

  @impl true
  def handle_info({:backfill_update, %{type: :contract_framed, data: data}}, socket) do
    snippet =
      if data.llm_output && String.length(data.llm_output) > 120 do
        String.slice(data.llm_output, 0, 120) <> "..."
      else
        data.llm_output || ""
      end

    log_entry = %{
      timestamp: DateTime.utc_now(),
      filename: data.filename,
      type: :contract_framed,
      row: data.row,
      sap_reference: data.sap_reference,
      message: "#{data.filename} row #{data.row} [#{data.sap_reference}] — framed",
      snippet: snippet,
      status: "framed"
    }

    {:noreply, update(socket, :processing_logs, &[log_entry | &1])}
  end

  @impl true
  def handle_info({:backfill_update, %{type: :contract_vectorized, data: data}}, socket) do
    log_entry = %{
      timestamp: DateTime.utc_now(),
      filename: data.filename,
      type: :contract_vectorized,
      row: data.row,
      message: "#{data.filename} row #{data.row} — vector created",
      status: "vectorized"
    }

    {:noreply, update(socket, :processing_logs, &[log_entry | &1])}
  end

  @impl true
  def handle_info({:backfill_update, %{type: :error, data: data}}, socket) do
    log_entry = %{
      timestamp: DateTime.utc_now(),
      filename: data.filename,
      type: :error,
      row: data.row,
      message: "ERROR: #{data.filename} row #{data.row} — #{data.error}",
      status: "error"
    }

    {:noreply, update(socket, :processing_logs, &[log_entry | &1])}
  end

  @impl true
  def handle_info({:backfill_complete, summary}, socket) do
    # Reload the job from DB to get final tallies
    job = Repo.get(BackfillJob, summary.job_id)

    {:noreply,
     socket
     |> assign(:phase, :complete)
     |> assign(:job, job)
     |> assign(:summary, summary)}
  end

  # Catch-all for any other PubSub messages
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Private: Process Uploads ─────────────────────────────────

  defp process_uploads(socket) do
    product_group = socket.assigns.selected_product_group
    job_ref = "backfill_#{product_group}_#{System.system_time(:second)}"
    file_count = length(socket.assigns.uploads.sap_files.entries)

    # Create the BackfillJob record
    {:ok, job} =
      %BackfillJob{}
      |> BackfillJob.changeset(%{
        job_reference: job_ref,
        product_group: product_group,
        status: "processing",
        file_count: file_count,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    # Subscribe to PubSub for this job
    Phoenix.PubSub.subscribe(TradingDesk.PubSub, "backfill:#{job.id}")

    # Consume uploaded files and queue Oban jobs
    uploaded_files =
      consume_uploaded_entries(socket, :sap_files, fn %{path: tmp_path}, entry ->
        # Copy the temp file to a stable location so Oban workers can read it
        upload_dir = Path.join([Application.app_dir(:trading_desk, "priv"), "uploads", "backfill", job.id])
        File.mkdir_p!(upload_dir)
        dest = Path.join(upload_dir, entry.client_name)
        File.cp!(tmp_path, dest)

        {:ok, %{path: dest, filename: entry.client_name, size: entry.client_size}}
      end)

    # Queue an Oban job for each file
    Enum.each(uploaded_files, fn file_info ->
      %{
        "job_id" => job.id,
        "file_path" => file_info.path,
        "filename" => file_info.filename,
        "file_size" => file_info.size
      }
      |> BackfillFileWorker.new()
      |> Oban.insert()
    end)

    Logger.info("Backfill job #{job.id} started: #{file_count} files queued for #{product_group}")

    socket =
      socket
      |> assign(:phase, :processing)
      |> assign(:job, job)
      |> assign(:error_message, nil)
      |> assign(:processing_logs, [
        %{
          timestamp: DateTime.utc_now(),
          type: :system,
          message: "Backfill job started — #{file_count} file(s) queued for processing",
          status: "started"
        }
      ])

    {:noreply, socket}
  end

  # ── Render ───────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div style="min-height: 100vh; background: #080c14; color: #c8d6e5; font-family: 'Inter', system-ui, sans-serif; padding: 2rem;">
      <!-- Header -->
      <div style="max-width: 1000px; margin: 0 auto;">
        <div style="display: flex; align-items: center; gap: 1rem; margin-bottom: 0.5rem;">
          <h1 style="font-size: 1.5rem; font-weight: 700; color: #f1f5f9; margin: 0;">
            Historical Backfill
          </h1>
          <span style="font-size: 0.75rem; background: #1e293b; color: #94a3b8; padding: 0.25rem 0.75rem; border-radius: 9999px;">
            Phase 4 — SAP Contract Vectorization
          </span>
        </div>
        <p style="color: #64748b; font-size: 0.875rem; margin: 0 0 2rem 0;">
          Upload SAP contract history files to generate semantic vectors for the trading desk memory layer.
        </p>

        <!-- Phase indicator -->
        <div style="display: flex; gap: 0.5rem; margin-bottom: 2rem;">
          <.phase_pill label="1. Upload" active={@phase == :upload} complete={@phase in [:processing, :complete]} />
          <.phase_pill label="2. Processing" active={@phase == :processing} complete={@phase == :complete} />
          <.phase_pill label="3. Complete" active={@phase == :complete} complete={false} />
        </div>

        <!-- Phase content -->
        <%= case @phase do %>
          <% :upload -> %>
            <.upload_phase
              uploads={@uploads}
              product_groups={@product_groups}
              selected_product_group={@selected_product_group}
              error_message={@error_message}
            />
          <% :processing -> %>
            <.processing_phase
              job={@job}
              processing_logs={@processing_logs}
              file_statuses={@file_statuses}
            />
          <% :complete -> %>
            <.complete_phase
              job={@job}
              summary={@summary}
              processing_logs={@processing_logs}
            />
        <% end %>
      </div>
    </div>
    """
  end

  # ── Component: Phase Pill ────────────────────────────────────

  defp phase_pill(assigns) do
    bg =
      cond do
        assigns.active -> "#2563eb"
        assigns.complete -> "#10b981"
        true -> "#1e293b"
      end

    text_color =
      cond do
        assigns.active or assigns.complete -> "#ffffff"
        true -> "#64748b"
      end

    assigns = assign(assigns, :bg, bg)
    assigns = assign(assigns, :text_color, text_color)

    ~H"""
    <span style={"font-size: 0.75rem; padding: 0.375rem 1rem; border-radius: 9999px; font-weight: 600; background: #{@bg}; color: #{@text_color};"}>
      {@label}
    </span>
    """
  end

  # ── Component: Upload Phase ──────────────────────────────────

  defp upload_phase(assigns) do
    ~H"""
    <div>
      <!-- Product Group Selection -->
      <div style="background: #0f1724; border: 1px solid #1e293b; border-radius: 0.75rem; padding: 1.5rem; margin-bottom: 1.5rem;">
        <h2 style="font-size: 1rem; font-weight: 600; color: #f1f5f9; margin: 0 0 1rem 0;">
          Product Group
        </h2>
        <div style="display: flex; gap: 0.75rem; flex-wrap: wrap;">
          <%= for {label, value} <- @product_groups do %>
            <button
              phx-click="select_product_group"
              phx-value-product_group={value}
              style={"padding: 0.625rem 1.25rem; border-radius: 0.5rem; font-size: 0.875rem; font-weight: 500; cursor: pointer; transition: all 0.15s; border: 1px solid #{if @selected_product_group == value, do: "#2563eb", else: "#1e293b"}; background: #{if @selected_product_group == value, do: "#2563eb22", else: "#080c14"}; color: #{if @selected_product_group == value, do: "#60a5fa", else: "#94a3b8"};"}
            >
              {label}
            </button>
          <% end %>
        </div>
      </div>

      <!-- File Upload -->
      <div style="background: #0f1724; border: 1px solid #1e293b; border-radius: 0.75rem; padding: 1.5rem; margin-bottom: 1.5rem;">
        <h2 style="font-size: 1rem; font-weight: 600; color: #f1f5f9; margin: 0 0 0.5rem 0;">
          SAP History Files
        </h2>
        <p style="color: #64748b; font-size: 0.8rem; margin: 0 0 1rem 0;">
          Upload CSV or JSON files exported from SAP. Max 50 files, 100 MB each.
        </p>

        <form id="upload-form" phx-submit="start_processing" phx-change="validate">
          <!-- Drop zone -->
          <div
            phx-drop-target={@uploads.sap_files.ref}
            style="border: 2px dashed #1e293b; border-radius: 0.75rem; padding: 2.5rem; text-align: center; cursor: pointer; transition: border-color 0.15s;"
          >
            <div style="color: #475569; margin-bottom: 0.75rem;">
              <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#475569" stroke-width="1.5" style="margin: 0 auto;">
                <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
                <polyline points="17 8 12 3 7 8"></polyline>
                <line x1="12" y1="3" x2="12" y2="15"></line>
              </svg>
            </div>
            <p style="color: #94a3b8; font-size: 0.875rem; margin: 0 0 0.5rem 0;">
              Drag and drop files here, or click to browse
            </p>
            <.live_file_input upload={@uploads.sap_files} style="display: none;" />
            <label
              for={@uploads.sap_files.ref}
              style="display: inline-block; padding: 0.5rem 1.25rem; background: #1e293b; color: #c8d6e5; border-radius: 0.5rem; font-size: 0.8rem; cursor: pointer; font-weight: 500;"
            >
              Choose Files
            </label>
            <p style="color: #475569; font-size: 0.75rem; margin: 0.75rem 0 0 0;">
              Accepted formats: .csv, .json
            </p>
          </div>

          <!-- Selected files list -->
          <%= if Enum.any?(@uploads.sap_files.entries) do %>
            <div style="margin-top: 1rem;">
              <div style="font-size: 0.8rem; color: #94a3b8; margin-bottom: 0.5rem; font-weight: 600;">
                {length(@uploads.sap_files.entries)} file(s) selected
              </div>
              <%= for entry <- @uploads.sap_files.entries do %>
                <div style="display: flex; align-items: center; justify-content: space-between; padding: 0.625rem 1rem; background: #080c14; border: 1px solid #1e293b; border-radius: 0.5rem; margin-bottom: 0.375rem;">
                  <div style="display: flex; align-items: center; gap: 0.75rem;">
                    <span style={"display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #{if entry.valid?, do: "#10b981", else: "#ef4444"};"}></span>
                    <span style="font-size: 0.85rem; color: #c8d6e5; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
                      {entry.client_name}
                    </span>
                    <span style="font-size: 0.75rem; color: #475569;">
                      {format_file_size(entry.client_size)}
                    </span>
                  </div>
                  <div style="display: flex; align-items: center; gap: 0.75rem;">
                    <!-- Upload progress -->
                    <div style="width: 80px; height: 4px; background: #1e293b; border-radius: 2px; overflow: hidden;">
                      <div style={"width: #{entry.progress}%; height: 100%; background: #2563eb; transition: width 0.3s;"}></div>
                    </div>
                    <!-- Error messages -->
                    <%= for err <- upload_errors(@uploads.sap_files, entry) do %>
                      <span style="font-size: 0.75rem; color: #ef4444;">{error_to_string(err)}</span>
                    <% end %>
                    <!-- Cancel button -->
                    <button
                      type="button"
                      phx-click="cancel_upload"
                      phx-value-ref={entry.ref}
                      style="background: none; border: none; color: #64748b; cursor: pointer; font-size: 1rem; padding: 0; line-height: 1;"
                    >
                      &times;
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <!-- Error message -->
          <%= if @error_message do %>
            <div style="margin-top: 1rem; padding: 0.75rem 1rem; background: #1c0a0a; border: 1px solid #7f1d1d; border-radius: 0.5rem; color: #fca5a5; font-size: 0.85rem;">
              {@error_message}
            </div>
          <% end %>

          <!-- Submit button -->
          <div style="margin-top: 1.5rem; display: flex; justify-content: flex-end;">
            <button
              type="submit"
              disabled={Enum.empty?(@uploads.sap_files.entries)}
              style={"padding: 0.75rem 2rem; border-radius: 0.5rem; font-size: 0.9rem; font-weight: 600; border: none; cursor: #{if Enum.empty?(@uploads.sap_files.entries), do: "not-allowed", else: "pointer"}; background: #{if Enum.empty?(@uploads.sap_files.entries), do: "#1e293b", else: "#2563eb"}; color: #{if Enum.empty?(@uploads.sap_files.entries), do: "#475569", else: "#ffffff"};"}
            >
              Start Processing
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── Component: Processing Phase ──────────────────────────────

  defp processing_phase(assigns) do
    ~H"""
    <div>
      <!-- Job info bar -->
      <div style="background: #0f1724; border: 1px solid #1e293b; border-radius: 0.75rem; padding: 1.25rem 1.5rem; margin-bottom: 1.5rem; display: flex; justify-content: space-between; align-items: center;">
        <div>
          <span style="font-size: 0.8rem; color: #64748b;">Job ID: </span>
          <span style="font-size: 0.8rem; color: #94a3b8; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
            {if @job, do: @job.id, else: "—"}
          </span>
        </div>
        <div>
          <span style="font-size: 0.8rem; color: #64748b;">Product Group: </span>
          <span style="font-size: 0.8rem; color: #60a5fa; font-weight: 600;">
            {if @job, do: format_product_group(@job.product_group), else: "—"}
          </span>
        </div>
        <div>
          <span style="font-size: 0.8rem; color: #64748b;">Files: </span>
          <span style="font-size: 0.8rem; color: #c8d6e5; font-weight: 600;">
            {if @job, do: @job.file_count, else: 0}
          </span>
        </div>
        <div style="display: flex; align-items: center; gap: 0.5rem;">
          <span style="display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #f59e0b; animation: pulse 1.5s ease-in-out infinite;"></span>
          <span style="font-size: 0.8rem; color: #f59e0b; font-weight: 600;">Processing</span>
        </div>
      </div>

      <!-- File statuses -->
      <%= if map_size(@file_statuses) > 0 do %>
        <div style="background: #0f1724; border: 1px solid #1e293b; border-radius: 0.75rem; padding: 1.25rem 1.5rem; margin-bottom: 1.5rem;">
          <h3 style="font-size: 0.875rem; font-weight: 600; color: #f1f5f9; margin: 0 0 0.75rem 0;">File Status</h3>
          <%= for {filename, status} <- @file_statuses do %>
            <div style="display: flex; align-items: center; gap: 0.75rem; padding: 0.5rem 0; border-bottom: 1px solid #1e293b22;">
              <span style={"display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: #{status_color(status)};"}></span>
              <span style="font-size: 0.8rem; color: #c8d6e5; font-family: 'JetBrains Mono', 'Fira Code', monospace; flex: 1;">
                {filename}
              </span>
              <span style={"font-size: 0.75rem; font-weight: 600; color: #{status_color(status)};"}>
                {status}
              </span>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Processing log -->
      <div style="background: #0a0e18; border: 1px solid #1e293b; border-radius: 0.75rem; overflow: hidden;">
        <div style="padding: 1rem 1.5rem; border-bottom: 1px solid #1e293b; display: flex; justify-content: space-between; align-items: center;">
          <h3 style="font-size: 0.875rem; font-weight: 600; color: #f1f5f9; margin: 0;">
            Processing Log
          </h3>
          <span style="font-size: 0.75rem; color: #64748b;">
            {length(@processing_logs)} entries
          </span>
        </div>
        <div id="processing-log" style="max-height: 500px; overflow-y: auto; padding: 0.5rem 0;">
          <%= for {log, idx} <- Enum.with_index(@processing_logs) do %>
            <.log_entry log={log} idx={idx} />
          <% end %>
          <%= if Enum.empty?(@processing_logs) do %>
            <div style="padding: 2rem; text-align: center; color: #475569; font-size: 0.85rem;">
              Waiting for processing updates...
            </div>
          <% end %>
        </div>
      </div>

      <style>
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.4; }
        }
      </style>
    </div>
    """
  end

  # ── Component: Log Entry ─────────────────────────────────────

  defp log_entry(assigns) do
    border_color =
      case assigns.log.type do
        :error -> "#7f1d1d"
        :contract_vectorized -> "#064e3b"
        :contract_framed -> "#1e3a5f"
        _ -> "#1e293b22"
      end

    text_color =
      case assigns.log.type do
        :error -> "#fca5a5"
        :contract_vectorized -> "#6ee7b7"
        :contract_framed -> "#93c5fd"
        :system -> "#f59e0b"
        _ -> "#94a3b8"
      end

    assigns = assign(assigns, :border_color, border_color)
    assigns = assign(assigns, :text_color, text_color)

    ~H"""
    <div style={"padding: 0.5rem 1.5rem; border-left: 3px solid #{@border_color}; margin: 0.25rem 0;"}>
      <div style="display: flex; align-items: flex-start; gap: 0.75rem;">
        <span style="font-size: 0.7rem; color: #475569; font-family: 'JetBrains Mono', 'Fira Code', monospace; white-space: nowrap; padding-top: 2px;">
          {if Map.has_key?(@log, :timestamp) && @log.timestamp, do: Calendar.strftime(@log.timestamp, "%H:%M:%S"), else: "--:--:--"}
        </span>
        <div style="flex: 1; min-width: 0;">
          <div style={"font-size: 0.8rem; color: #{@text_color}; font-family: 'JetBrains Mono', 'Fira Code', monospace;"}>
            {@log.message}
          </div>
          <%= if Map.has_key?(@log, :snippet) && @log.snippet do %>
            <div style="font-size: 0.75rem; color: #475569; font-family: 'JetBrains Mono', 'Fira Code', monospace; margin-top: 0.25rem; padding: 0.5rem; background: #080c14; border-radius: 0.375rem; white-space: pre-wrap; word-break: break-all;">
              {@log.snippet}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Component: Complete Phase ────────────────────────────────

  defp complete_phase(assigns) do
    error_count =
      assigns.processing_logs
      |> Enum.count(fn log -> log.type == :error end)

    framed_count =
      assigns.processing_logs
      |> Enum.count(fn log -> log.type == :contract_framed end)

    vectorized_count =
      assigns.processing_logs
      |> Enum.count(fn log -> log.type == :contract_vectorized end)

    # Prefer DB values from the job/summary if available
    total_contracts = if assigns.summary, do: assigns.summary.total_contracts, else: framed_count
    total_vectors = if assigns.summary, do: assigns.summary.total_vectors, else: vectorized_count
    total_errors = if assigns.job && assigns.job.errors_encountered > 0, do: assigns.job.errors_encountered, else: error_count

    assigns =
      assigns
      |> assign(:total_contracts, total_contracts)
      |> assign(:total_vectors, total_vectors)
      |> assign(:total_errors, total_errors)

    ~H"""
    <div>
      <!-- Success banner -->
      <div style="background: linear-gradient(135deg, #064e3b, #0f1724); border: 1px solid #10b981; border-radius: 0.75rem; padding: 1.5rem; margin-bottom: 1.5rem; text-align: center;">
        <div style="font-size: 2rem; margin-bottom: 0.5rem;">
          <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="#10b981" stroke-width="2" style="margin: 0 auto;">
            <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path>
            <polyline points="22 4 12 14.01 9 11.01"></polyline>
          </svg>
        </div>
        <h2 style="font-size: 1.25rem; font-weight: 700; color: #10b981; margin: 0.5rem 0;">
          Backfill Complete
        </h2>
        <p style="color: #6ee7b7; font-size: 0.85rem; margin: 0;">
          All files have been processed and vectors generated.
        </p>
      </div>

      <!-- Summary cards -->
      <div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; margin-bottom: 1.5rem;">
        <.summary_card
          label="Contracts Processed"
          value={@total_contracts}
          color="#60a5fa"
          bg="#1e3a5f22"
        />
        <.summary_card
          label="Vectors Created"
          value={@total_vectors}
          color="#10b981"
          bg="#064e3b22"
        />
        <.summary_card
          label="Errors"
          value={@total_errors}
          color={if @total_errors > 0, do: "#ef4444", else: "#475569"}
          bg={if @total_errors > 0, do: "#7f1d1d22", else: "#1e293b22"}
        />
      </div>

      <!-- Job details -->
      <div style="background: #0f1724; border: 1px solid #1e293b; border-radius: 0.75rem; padding: 1.25rem 1.5rem; margin-bottom: 1.5rem;">
        <h3 style="font-size: 0.875rem; font-weight: 600; color: #f1f5f9; margin: 0 0 1rem 0;">Job Details</h3>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 0.75rem;">
          <div>
            <span style="font-size: 0.75rem; color: #64748b;">Job ID</span>
            <div style="font-size: 0.8rem; color: #c8d6e5; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
              {if @job, do: @job.id, else: "—"}
            </div>
          </div>
          <div>
            <span style="font-size: 0.75rem; color: #64748b;">Product Group</span>
            <div style="font-size: 0.8rem; color: #60a5fa; font-weight: 600;">
              {if @job, do: format_product_group(@job.product_group), else: "—"}
            </div>
          </div>
          <div>
            <span style="font-size: 0.75rem; color: #64748b;">Files Processed</span>
            <div style="font-size: 0.8rem; color: #c8d6e5;">
              {if @job, do: @job.file_count, else: 0}
            </div>
          </div>
          <div>
            <span style="font-size: 0.75rem; color: #64748b;">Started</span>
            <div style="font-size: 0.8rem; color: #c8d6e5; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
              {if @job && @job.started_at, do: Calendar.strftime(@job.started_at, "%Y-%m-%d %H:%M:%S UTC"), else: "—"}
            </div>
          </div>
          <div>
            <span style="font-size: 0.75rem; color: #64748b;">Completed</span>
            <div style="font-size: 0.8rem; color: #c8d6e5; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
              {if @job && @job.completed_at, do: Calendar.strftime(@job.completed_at, "%Y-%m-%d %H:%M:%S UTC"), else: "—"}
            </div>
          </div>
          <div>
            <span style="font-size: 0.75rem; color: #64748b;">Job Reference</span>
            <div style="font-size: 0.8rem; color: #c8d6e5; font-family: 'JetBrains Mono', 'Fira Code', monospace;">
              {if @job, do: @job.job_reference, else: "—"}
            </div>
          </div>
        </div>
      </div>

      <!-- Processing log (collapsed by default in complete phase) -->
      <details style="background: #0a0e18; border: 1px solid #1e293b; border-radius: 0.75rem; overflow: hidden;">
        <summary style="padding: 1rem 1.5rem; cursor: pointer; color: #94a3b8; font-size: 0.85rem; font-weight: 600;">
          Processing Log ({length(@processing_logs)} entries)
        </summary>
        <div style="max-height: 400px; overflow-y: auto; padding: 0.5rem 0;">
          <%= for {log, idx} <- Enum.with_index(@processing_logs) do %>
            <.log_entry log={log} idx={idx} />
          <% end %>
        </div>
      </details>

      <!-- Reset button -->
      <div style="margin-top: 2rem; display: flex; justify-content: center;">
        <button
          phx-click="reset"
          style="padding: 0.75rem 2rem; border-radius: 0.5rem; font-size: 0.9rem; font-weight: 600; border: 1px solid #1e293b; cursor: pointer; background: #0f1724; color: #c8d6e5;"
        >
          Start New Backfill
        </button>
      </div>
    </div>
    """
  end

  # ── Component: Summary Card ──────────────────────────────────

  defp summary_card(assigns) do
    ~H"""
    <div style={"background: #{@bg}; border: 1px solid #1e293b; border-radius: 0.75rem; padding: 1.5rem; text-align: center;"}>
      <div style={"font-size: 2rem; font-weight: 700; color: #{@color}; font-family: 'JetBrains Mono', 'Fira Code', monospace;"}>
        {@value}
      </div>
      <div style="font-size: 0.8rem; color: #94a3b8; margin-top: 0.25rem;">
        {@label}
      </div>
    </div>
    """
  end

  # ── Helpers ──────────────────────────────────────────────────

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_product_group("ammonia_domestic"), do: "Ammonia Domestic"
  defp format_product_group("sulphur_international"), do: "Sulphur International"
  defp format_product_group("petcoke"), do: "Petcoke"
  defp format_product_group("ammonia_international"), do: "Ammonia International"
  defp format_product_group(other), do: other

  defp status_color("parsing"), do: "#f59e0b"
  defp status_color("framing"), do: "#3b82f6"
  defp status_color("vectorizing"), do: "#8b5cf6"
  defp status_color("complete"), do: "#10b981"
  defp status_color("error"), do: "#ef4444"
  defp status_color(_), do: "#64748b"

  defp error_to_string(:too_large), do: "File too large (max 100 MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 50)"
  defp error_to_string(:not_accepted), do: "Invalid file type (CSV or JSON only)"
  defp error_to_string(err), do: inspect(err)
end
