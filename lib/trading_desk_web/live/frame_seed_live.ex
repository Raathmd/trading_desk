defmodule TradingDesk.FrameSeedLive do
  @moduledoc """
  Admin LiveView for managing product group frame seeds.

  Route: /admin/seeds

  Provides two core operations:
  1. **Export** — Dump current DB state to the seed file (log current config)
  2. **Seed** — Load the seed file into the DB (restore from log)

  The seed file at `priv/repo/seeds/product_group_frames_seed.exs` acts as
  a persistent log. Every time config is changed through the UI, the seed
  file is regenerated so it always reflects the latest state. If the database
  needs to be reinitialized, an admin can seed from this file.
  """
  use Phoenix.LiveView

  alias TradingDesk.ProductGroup.{FrameStore, SeedExporter}
  alias TradingDesk.DB.{ProductGroupConfig, RouteDefinition, ConstraintDefinition}
  alias TradingDesk.Variables.{VariableDefinition, VariableStore}
  alias TradingDesk.Repo

  import Ecto.Query

  # ──────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:seed_path, SeedExporter.seed_path())
      |> assign(:last_export, nil)
      |> assign(:confirm_seed, false)
      |> assign(:seeding, false)
      |> assign(:seed_log, [])
      |> load_stats()
      |> load_seed_file_info()

    {:ok, socket}
  end

  # ──────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("export_seed", _params, socket) do
    case SeedExporter.export() do
      {:ok, source} ->
        line_count = source |> String.split("\n") |> length()
        socket =
          socket
          |> put_flash(:info, "Seed file exported (#{line_count} lines). DB state is now logged.")
          |> assign(:last_export, DateTime.utc_now())
          |> load_seed_file_info()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Export failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("confirm_seed", _params, socket) do
    {:noreply, assign(socket, :confirm_seed, true)}
  end

  @impl true
  def handle_event("cancel_seed", _params, socket) do
    {:noreply, assign(socket, :confirm_seed, false)}
  end

  @impl true
  def handle_event("run_seed", _params, socket) do
    socket = assign(socket, seeding: true, confirm_seed: false, seed_log: [])

    send(self(), :do_seed)
    {:noreply, socket}
  end

  @impl true
  def handle_info(:do_seed, socket) do
    log = []
    seed_path = SeedExporter.seed_path()

    result =
      try do
        if File.exists?(seed_path) do
          # The seed file defines a module with a run/0 function.
          # We need to re-require it to pick up any changes.
          Code.unrequire_files([seed_path])
          [{mod, _}] = Code.require_file(seed_path)
          mod.run()
          {:ok, ["Seed completed successfully."]}
        else
          {:error, ["Seed file not found at #{seed_path}. Export first."]}
        end
      rescue
        e ->
          {:error, ["Seed failed: #{Exception.message(e)}"]}
      end

    {flash_type, messages} = case result do
      {:ok, msgs} -> {:info, msgs}
      {:error, msgs} -> {:error, msgs}
    end

    # Invalidate frame cache after seeding
    FrameStore.invalidate()

    socket =
      socket
      |> assign(:seeding, false)
      |> assign(:seed_log, log ++ messages)
      |> put_flash(flash_type, List.last(messages))
      |> load_stats()

    {:noreply, socket}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────
  # Render
  # ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#030712;min-height:100vh;color:#c8d6e5;font-family:'Inter',sans-serif;padding:24px">

      <%!-- Header --%>
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:20px">
        <div>
          <div style="font-size:18px;font-weight:800;letter-spacing:1.5px;color:#f1f5f9">
            FRAME SEED MANAGER
          </div>
          <div style="font-size:11px;color:#475569;margin-top:2px">
            Export DB config to seed file (log) or restore DB from seed file
          </div>
        </div>
        <div style="display:flex;gap:8px;align-items:center">
          <a href="/variables" style="font-size:11px;color:#475569;text-decoration:none;padding:4px 10px;
               border:1px solid #1e293b;border-radius:4px">Variables</a>
          <a href="/api-config" style="font-size:11px;color:#475569;text-decoration:none;padding:4px 10px;
               border:1px solid #1e293b;border-radius:4px">API Config</a>
          <a href="/desk" style="font-size:11px;color:#475569;text-decoration:none;padding:4px 10px;
               border:1px solid #1e293b;border-radius:4px">Dashboard</a>
        </div>
      </div>

      <%!-- Flash --%>
      <%= if live_flash(@flash, :info) do %>
        <div style="background:#052e16;border:1px solid #16a34a;border-radius:6px;padding:8px 14px;
                    margin-bottom:14px;font-size:12px;color:#86efac">
          <%= live_flash(@flash, :info) %>
        </div>
      <% end %>
      <%= if live_flash(@flash, :error) do %>
        <div style="background:#1f0000;border:1px solid #dc2626;border-radius:6px;padding:8px 14px;
                    margin-bottom:14px;font-size:12px;color:#fca5a5">
          <%= live_flash(@flash, :error) %>
        </div>
      <% end %>

      <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:24px">

        <%!-- LEFT: Current DB State --%>
        <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:8px;padding:20px">
          <div style="font-size:13px;font-weight:700;color:#f1f5f9;margin-bottom:16px">
            CURRENT DATABASE STATE
          </div>

          <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:20px">
            <%= for {label, count} <- @db_stats do %>
              <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px">
                <div style="font-size:22px;font-weight:800;color:#60a5fa"><%= count %></div>
                <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;margin-top:2px">
                  <%= label %>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Product groups detail --%>
          <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;margin-bottom:8px">
            PRODUCT GROUPS
          </div>
          <%= if @pg_details == [] do %>
            <div style="font-size:11px;color:#334155;padding:8px 0">
              No product groups in database. Seed first.
            </div>
          <% else %>
            <div style="display:flex;flex-direction:column;gap:4px">
              <%= for pg <- @pg_details do %>
                <div style="display:flex;justify-content:space-between;align-items:center;
                            background:#111827;border:1px solid #1e293b;border-radius:4px;padding:8px 12px">
                  <div>
                    <span style="font-size:12px;font-family:monospace;color:#60a5fa;font-weight:700"><%= pg.key %></span>
                    <span style="font-size:11px;color:#94a3b8;margin-left:8px"><%= pg.name %></span>
                  </div>
                  <div style="display:flex;gap:12px;font-size:10px;color:#64748b">
                    <span><%= pg.var_count %> vars</span>
                    <span><%= pg.route_count %> routes</span>
                    <span><%= pg.constraint_count %> constraints</span>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- RIGHT: Seed File --%>
        <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:8px;padding:20px">
          <div style="font-size:13px;font-weight:700;color:#f1f5f9;margin-bottom:16px">
            SEED FILE (LOG)
          </div>

          <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px;margin-bottom:16px">
            <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;margin-bottom:4px">PATH</div>
            <div style="font-size:11px;font-family:monospace;color:#94a3b8;word-break:break-all"><%= @seed_path %></div>
          </div>

          <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:16px">
            <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px">
              <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px">FILE EXISTS</div>
              <div style={"font-size:14px;font-weight:700;margin-top:4px;color:#{if @seed_file_exists, do: "#86efac", else: "#fca5a5"}"}>
                <%= if @seed_file_exists, do: "YES", else: "NO" %>
              </div>
            </div>
            <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px">
              <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px">FILE SIZE</div>
              <div style="font-size:14px;font-weight:700;margin-top:4px;color:#c8d6e5">
                <%= @seed_file_size %>
              </div>
            </div>
            <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px">
              <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px">LAST MODIFIED</div>
              <div style="font-size:11px;font-weight:700;margin-top:4px;color:#c8d6e5">
                <%= @seed_file_mtime || "—" %>
              </div>
            </div>
            <div style="background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px">
              <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px">LAST EXPORT</div>
              <div style="font-size:11px;font-weight:700;margin-top:4px;color:#c8d6e5">
                <%= if @last_export, do: Calendar.strftime(@last_export, "%Y-%m-%d %H:%M:%S UTC"), else: "—" %>
              </div>
            </div>
          </div>

          <%!-- Action buttons --%>
          <div style="display:flex;flex-direction:column;gap:12px">
            <button phx-click="export_seed"
              style="width:100%;font-size:12px;font-weight:700;padding:10px 20px;border-radius:5px;cursor:pointer;
                     background:#1e3a5f;border:1px solid #2563eb;color:#93c5fd;letter-spacing:0.5px">
              EXPORT DB → SEED FILE
            </button>
            <div style="font-size:10px;color:#334155;text-align:center;margin-top:-6px">
              Writes current DB state to seed file. Safe — does not modify DB.
            </div>

            <%= if @confirm_seed do %>
              <div style="background:#1f0000;border:1px solid #dc2626;border-radius:6px;padding:14px">
                <div style="font-size:12px;color:#fca5a5;font-weight:700;margin-bottom:8px">
                  Confirm: Load seed file into database?
                </div>
                <div style="font-size:11px;color:#94a3b8;margin-bottom:12px">
                  This will upsert all product group configs, variables, routes, and constraints
                  from the seed file. Existing data with matching keys will be overwritten.
                </div>
                <div style="display:flex;gap:8px">
                  <button phx-click="run_seed" disabled={@seeding}
                    style="font-size:11px;font-weight:700;padding:8px 20px;border-radius:5px;cursor:pointer;
                           background:#7f1d1d;border:1px solid #dc2626;color:#fca5a5;letter-spacing:0.5px">
                    <%= if @seeding, do: "SEEDING...", else: "YES, SEED NOW" %>
                  </button>
                  <button phx-click="cancel_seed"
                    style="font-size:11px;padding:8px 16px;border-radius:5px;cursor:pointer;
                           background:#0a0f18;border:1px solid #1e293b;color:#64748b">
                    Cancel
                  </button>
                </div>
              </div>
            <% else %>
              <button phx-click="confirm_seed" disabled={!@seed_file_exists}
                style={"width:100%;font-size:12px;font-weight:700;padding:10px 20px;border-radius:5px;cursor:pointer;
                       background:#1a1a2e;border:1px solid #475569;color:#94a3b8;letter-spacing:0.5px;
                       #{unless @seed_file_exists, do: "opacity:0.4;cursor:not-allowed", else: ""}"}>
                SEED FILE → DATABASE
              </button>
              <div style="font-size:10px;color:#334155;text-align:center;margin-top:-6px">
                Restores DB from seed file. Uses upsert — won't delete rows not in the file.
              </div>
            <% end %>
          </div>

          <%!-- Seed log output --%>
          <%= if @seed_log != [] do %>
            <div style="margin-top:16px;background:#111827;border:1px solid #1e293b;border-radius:6px;padding:12px">
              <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;margin-bottom:6px">LOG</div>
              <%= for line <- @seed_log do %>
                <div style="font-size:11px;font-family:monospace;color:#94a3b8;padding:2px 0"><%= line %></div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- How it works --%>
      <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:8px;padding:20px;margin-top:4px">
        <div style="font-size:11px;color:#334155;line-height:1.8">
          <strong style="color:#475569">How it works:</strong>
          The seed file is a log of your product group configuration. When you edit configs, routes, variables,
          or constraints through the UI, click <strong style="color:#60a5fa">Export</strong> to update the seed
          file. If the database ever needs to be reinitialized (new environment, data loss, etc.), click
          <strong style="color:#60a5fa">Seed</strong> to restore from the log. The seed file is also run
          automatically during <code style="color:#94a3b8">mix run priv/repo/seeds.exs</code> and
          <code style="color:#94a3b8">TradingDesk.Release.seed()</code>.
        </div>
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────

  defp load_stats(socket) do
    config_count = Repo.one(from c in ProductGroupConfig, where: c.active == true, select: count())
    var_count = Repo.one(from v in VariableDefinition,
      where: v.active == true and v.product_group != "global", select: count())
    route_count = Repo.one(from r in RouteDefinition, where: r.active == true, select: count())
    constraint_count = Repo.one(from c in ConstraintDefinition, where: c.active == true, select: count())

    pg_details = Repo.all(from c in ProductGroupConfig, where: c.active == true, order_by: c.key)
    |> Enum.map(fn c ->
      vc = Repo.one(from v in VariableDefinition,
        where: v.product_group == ^c.key and v.active == true, select: count())
      rc = Repo.one(from r in RouteDefinition,
        where: r.product_group == ^c.key and r.active == true, select: count())
      cc = Repo.one(from con in ConstraintDefinition,
        where: con.product_group == ^c.key and con.active == true, select: count())
      %{key: c.key, name: c.name, var_count: vc, route_count: rc, constraint_count: cc}
    end)

    socket
    |> assign(:db_stats, [
      {"Product Groups", config_count},
      {"Variables (per-group)", var_count},
      {"Routes", route_count},
      {"Constraints", constraint_count}
    ])
    |> assign(:pg_details, pg_details)
  rescue
    _ ->
      socket
      |> assign(:db_stats, [{"Product Groups", 0}, {"Variables", 0}, {"Routes", 0}, {"Constraints", 0}])
      |> assign(:pg_details, [])
  end

  defp load_seed_file_info(socket) do
    path = SeedExporter.seed_path()

    case File.stat(path) do
      {:ok, stat} ->
        size = format_bytes(stat.size)
        mtime = stat.mtime
                |> NaiveDateTime.from_erl!()
                |> NaiveDateTime.to_string()

        socket
        |> assign(:seed_file_exists, true)
        |> assign(:seed_file_size, size)
        |> assign(:seed_file_mtime, mtime)

      {:error, _} ->
        socket
        |> assign(:seed_file_exists, false)
        |> assign(:seed_file_size, "—")
        |> assign(:seed_file_mtime, nil)
    end
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"
end
