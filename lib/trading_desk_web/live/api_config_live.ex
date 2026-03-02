defmodule TradingDesk.ApiConfigLive do
  @moduledoc """
  LiveView for managing API source configuration.

  Route: /api-config

  Shows every data source from the `api_configs` table alongside the
  variables it populates (from `variable_definitions`).  Admins can edit
  endpoint URLs and API keys, and see real-time poller status for each
  source.
  """
  use Phoenix.LiveView

  alias TradingDesk.ApiConfig
  alias TradingDesk.Variables.VariableStore

  # ──────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "live_data")
    end

    socket =
      socket
      |> assign(:editing_source, nil)
      |> assign(:new_source, false)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_info({:data_updated, _source}, socket) do
    {:noreply, load_poller_status(socket)}
  end

  @impl true
  def handle_info(_, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────
  # Events
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("edit_source", %{"source" => source_id}, socket) do
    entries = socket.assigns.api_entries
    entry = Map.get(entries, source_id, %{})

    socket =
      socket
      |> assign(:editing_source, source_id)
      |> assign(:edit_url, entry["url"] || "")
      |> assign(:edit_key, entry["api_key"] || "")
      |> assign(:edit_env_url, entry["env_url"] || "")
      |> assign(:edit_env_key, entry["env_key"] || "")
      |> assign(:edit_notes, entry["notes"] || "")
      |> assign(:new_source, false)

    {:noreply, socket}
  end

  @impl true
  def handle_event("new_source", _params, socket) do
    socket =
      socket
      |> assign(:new_source, true)
      |> assign(:editing_source, nil)
      |> assign(:new_source_id, "")
      |> assign(:edit_url, "")
      |> assign(:edit_key, "")
      |> assign(:edit_env_url, "")
      |> assign(:edit_env_key, "")
      |> assign(:edit_notes, "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing_source, nil) |> assign(:new_source, false)}
  end

  @impl true
  def handle_event("save_source", params, socket) do
    source_id =
      if socket.assigns.new_source do
        params["new_source_id"] |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")
      else
        socket.assigns.editing_source
      end

    if source_id == "" do
      {:noreply, put_flash(socket, :error, "Source ID cannot be empty")}
    else
      entry = %{
        "url"     => params["url"] |> String.trim(),
        "api_key" => params["api_key"] |> String.trim(),
        "env_url" => params["env_url"] |> String.trim(),
        "env_key" => params["env_key"] |> String.trim(),
        "notes"   => params["notes"] |> String.trim()
      }

      existing = socket.assigns.api_entries
      updated = Map.put(existing, source_id, entry)

      case ApiConfig.upsert("global", updated) do
        {:ok, _} ->
          socket =
            socket
            |> put_flash(:info, "Source \"#{source_id}\" saved.")
            |> assign(:editing_source, nil)
            |> assign(:new_source, false)
            |> load_data()

          {:noreply, socket}

        {:error, _cs} ->
          {:noreply, put_flash(socket, :error, "Failed to save.")}
      end
    end
  end

  @impl true
  def handle_event("delete_source", %{"source" => source_id}, socket) do
    existing = socket.assigns.api_entries
    updated = Map.delete(existing, source_id)

    case ApiConfig.upsert("global", updated) do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Source \"#{source_id}\" removed.")
          |> assign(:editing_source, nil)
          |> load_data()

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete.")}
    end
  end

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
            API CONFIGURATION
          </div>
          <div style="font-size:11px;color:#475569;margin-top:2px">
            Manage endpoint URLs, API keys, and see which variables each source populates
          </div>
        </div>
        <div style="display:flex;gap:8px;align-items:center">
          <a href="/variables" style="font-size:11px;color:#475569;text-decoration:none;padding:4px 10px;
               border:1px solid #1e293b;border-radius:4px">Variables</a>
          <a href="/desk" style="font-size:11px;color:#475569;text-decoration:none;padding:4px 10px;
               border:1px solid #1e293b;border-radius:4px">Dashboard</a>
          <button phx-click="new_source"
            style="font-size:11px;font-weight:700;padding:6px 16px;border-radius:5px;cursor:pointer;
                   background:#1e3a5f;border:1px solid #2563eb;color:#93c5fd;letter-spacing:0.5px">
            + ADD SOURCE
          </button>
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

      <div style="display:grid;grid-template-columns:minmax(0,1fr) #{if @editing_source || @new_source, do: "440px", else: "0px"};gap:20px;transition:grid-template-columns 0.2s">

        <%!-- LEFT: Source table --%>
        <div>
          <table style="width:100%;border-collapse:collapse">
            <thead>
              <tr style="font-size:10px;color:#334155;letter-spacing:0.5px">
                <th style="text-align:left;padding:6px 8px;font-weight:700">SOURCE ID</th>
                <th style="text-align:left;padding:6px 8px;font-weight:700">URL</th>
                <th style="text-align:left;padding:6px 8px;font-weight:700">KEY</th>
                <th style="text-align:left;padding:6px 8px;font-weight:700">ENV FALLBACKS</th>
                <th style="text-align:left;padding:6px 8px;font-weight:700">VARIABLES FED</th>
                <th style="text-align:center;padding:6px 8px;font-weight:700">STATUS</th>
              </tr>
            </thead>
            <tbody>
              <%= for {source_id, entry} <- Enum.sort_by(@api_entries, fn {k, _} -> k end) do %>
                <%
                  vars_fed = Map.get(@vars_by_source, source_id, [])
                  poller_info = Map.get(@poller_by_source, source_id)
                  is_editing = @editing_source == source_id
                  has_url = (entry["url"] || "") != ""
                  has_key = (entry["api_key"] || "") != ""
                %>
                <tr phx-click="edit_source" phx-value-source={source_id}
                    style={"background:#{if is_editing, do: "#0d1f3c", else: "transparent"};
                            border-bottom:1px solid #0f172a;cursor:pointer;transition:background 0.15s"}>

                  <td style="padding:8px;font-size:12px;font-family:monospace;color:#60a5fa;font-weight:700">
                    <%= source_id %>
                  </td>

                  <td style="padding:8px;font-size:11px;color:#94a3b8;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap"
                      title={entry["url"]}>
                    <%= if has_url, do: entry["url"], else: raw("<span style='color:#475569'>—</span>") %>
                  </td>

                  <td style="padding:8px;font-size:11px">
                    <%= if has_key do %>
                      <span style="color:#16a34a;font-size:10px;font-weight:700">SET</span>
                    <% else %>
                      <span style="color:#475569;font-size:10px">none</span>
                    <% end %>
                  </td>

                  <td style="padding:8px;font-size:10px;color:#64748b;font-family:monospace">
                    <%= if (entry["env_url"] || "") != "" do %>
                      <span title={"URL: $" <> entry["env_url"]}><%= entry["env_url"] %></span>
                    <% end %>
                    <%= if (entry["env_key"] || "") != "" do %>
                      <span title={"Key: $" <> entry["env_key"]}> / <%= entry["env_key"] %></span>
                    <% end %>
                    <%= if (entry["env_url"] || "") == "" and (entry["env_key"] || "") == "" do %>
                      <span style="color:#334155">—</span>
                    <% end %>
                  </td>

                  <td style="padding:8px">
                    <%= if vars_fed == [] do %>
                      <span style="font-size:10px;color:#334155">none</span>
                    <% else %>
                      <div style="display:flex;flex-wrap:wrap;gap:3px">
                        <%= for vkey <- vars_fed do %>
                          <span style="font-size:9px;font-family:monospace;padding:1px 5px;
                                       border-radius:3px;background:#111827;color:#94a3b8;
                                       border:1px solid #1e293b">
                            <%= vkey %>
                          </span>
                        <% end %>
                      </div>
                    <% end %>
                  </td>

                  <td style="padding:8px;text-align:center">
                    <%= if poller_info do %>
                      <span style={"font-size:9px;font-weight:700;padding:2px 6px;border-radius:3px;
                                    #{if poller_info.status == :ok, do: "background:#052e16;color:#86efac;border:1px solid #16a34a", else: "background:#1f0000;color:#fca5a5;border:1px solid #dc2626"}"}>
                        <%= if poller_info.status == :ok, do: "OK", else: "ERR" %>
                      </span>
                    <% else %>
                      <span style="font-size:9px;color:#334155">—</span>
                    <% end %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>

          <%= if map_size(@api_entries) == 0 do %>
            <div style="text-align:center;padding:40px;color:#475569;font-size:12px">
              No API sources configured. Click "+ ADD SOURCE" to get started.
            </div>
          <% end %>

          <%!-- Notes / description below table --%>
          <div style="margin-top:20px;font-size:11px;color:#334155;line-height:1.6">
            <strong style="color:#475569">How it works:</strong>
            Each source entry stores a URL and API key. The Poller reads credentials via
            <code style="color:#60a5fa">ApiConfig.get_url/get_credential</code> — DB values take priority,
            then env var fallbacks. Add a variable with <code style="color:#60a5fa">source_id</code> matching
            one of these keys to auto-wire it to the Poller.
          </div>
        </div>

        <%!-- RIGHT: Edit panel --%>
        <%= if @editing_source || @new_source do %>
          <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:8px;padding:20px;
                      height:fit-content;position:sticky;top:20px">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:16px">
              <div style="font-size:13px;font-weight:700;color:#f1f5f9">
                <%= if @new_source, do: "New Source", else: "Edit: #{@editing_source}" %>
              </div>
              <button phx-click="cancel_edit"
                style="font-size:11px;padding:3px 10px;border-radius:4px;cursor:pointer;
                       border:1px solid #1e293b;background:#0a0f18;color:#64748b">
                Cancel
              </button>
            </div>

            <form phx-submit="save_source">
              <%= if @new_source do %>
                <div style="margin-bottom:12px">
                  <label style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;
                                display:block;margin-bottom:4px">SOURCE ID</label>
                  <input type="text" name="new_source_id" value={assigns[:new_source_id] || ""}
                    placeholder="my_custom_api"
                    style="width:100%;box-sizing:border-box;font-size:12px;background:#111827;
                           border:1px solid #1e293b;border-radius:4px;color:#c8d6e5;padding:6px 10px;
                           font-family:monospace" />
                  <div style="font-size:10px;color:#334155;margin-top:2px">
                    Lowercase snake_case. Must match source_id in variable definitions.
                  </div>
                </div>
              <% end %>

              <div style="margin-bottom:12px">
                <label style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;
                              display:block;margin-bottom:4px">API ENDPOINT URL</label>
                <input type="text" name="url" value={@edit_url}
                  placeholder="https://api.example.com/v1/data"
                  style="width:100%;box-sizing:border-box;font-size:12px;background:#111827;
                         border:1px solid #1e293b;border-radius:4px;color:#c8d6e5;padding:6px 10px;
                         font-family:monospace" />
              </div>

              <div style="margin-bottom:12px">
                <label style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;
                              display:block;margin-bottom:4px">API KEY</label>
                <input type="password" name="api_key" value={@edit_key}
                  placeholder="Enter API key (leave blank if none)"
                  style="width:100%;box-sizing:border-box;font-size:12px;background:#111827;
                         border:1px solid #1e293b;border-radius:4px;color:#c8d6e5;padding:6px 10px;
                         font-family:monospace" />
              </div>

              <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-bottom:12px">
                <div>
                  <label style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;
                                display:block;margin-bottom:4px">ENV VAR (URL)</label>
                  <input type="text" name="env_url" value={@edit_env_url}
                    placeholder="MY_API_URL"
                    style="width:100%;box-sizing:border-box;font-size:11px;background:#111827;
                           border:1px solid #1e293b;border-radius:4px;color:#c8d6e5;padding:6px 8px;
                           font-family:monospace" />
                </div>
                <div>
                  <label style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;
                                display:block;margin-bottom:4px">ENV VAR (KEY)</label>
                  <input type="text" name="env_key" value={@edit_env_key}
                    placeholder="MY_API_KEY"
                    style="width:100%;box-sizing:border-box;font-size:11px;background:#111827;
                           border:1px solid #1e293b;border-radius:4px;color:#c8d6e5;padding:6px 8px;
                           font-family:monospace" />
                </div>
              </div>

              <div style="margin-bottom:16px">
                <label style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;
                              display:block;margin-bottom:4px">DESCRIPTION / NOTES</label>
                <input type="text" name="notes" value={@edit_notes}
                  placeholder="Short description of this API source"
                  style="width:100%;box-sizing:border-box;font-size:12px;background:#111827;
                         border:1px solid #1e293b;border-radius:4px;color:#c8d6e5;padding:6px 10px" />
              </div>

              <%!-- Variables mapped to this source --%>
              <%= unless @new_source do %>
                <%
                  mapped_vars = Map.get(@vars_by_source, @editing_source, [])
                  var_details = Map.get(@var_details_by_source, @editing_source, [])
                %>
                <div style="margin-bottom:16px">
                  <div style="font-size:10px;color:#475569;font-weight:700;letter-spacing:0.5px;margin-bottom:6px">
                    VARIABLES FED (<%= length(mapped_vars) %>)
                  </div>
                  <%= if var_details == [] do %>
                    <div style="font-size:11px;color:#334155;padding:6px 0">
                      No variables use this source_id. Add one via
                      <a href="/variables" style="color:#60a5fa;text-decoration:none">/variables</a>.
                    </div>
                  <% else %>
                    <div style="display:flex;flex-direction:column;gap:4px">
                      <%= for vd <- var_details do %>
                        <div style="display:flex;justify-content:space-between;align-items:center;
                                    background:#111827;border:1px solid #1e293b;border-radius:4px;padding:6px 10px">
                          <div>
                            <span style="font-size:11px;font-family:monospace;color:#60a5fa"><%= vd.key %></span>
                            <span style="font-size:10px;color:#64748b;margin-left:6px"><%= vd.label %></span>
                          </div>
                          <div style="font-size:10px;color:#475569">
                            <%= vd.group_name %> · path: <code style="color:#94a3b8"><%= vd.response_path || "—" %></code>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>

              <div style="display:flex;gap:8px;justify-content:space-between">
                <button type="submit"
                  style="font-size:11px;font-weight:700;padding:8px 20px;border-radius:5px;cursor:pointer;
                         background:#1e3a5f;border:1px solid #2563eb;color:#93c5fd;letter-spacing:0.5px">
                  SAVE
                </button>
                <%= unless @new_source do %>
                  <button type="button" phx-click="delete_source" phx-value-source={@editing_source}
                    data-confirm={"Delete source \"#{@editing_source}\"? Variables referencing it will stop being polled."}
                    style="font-size:11px;padding:8px 16px;border-radius:5px;cursor:pointer;
                           background:#1f0000;border:1px solid #dc2626;color:#fca5a5;letter-spacing:0.5px">
                    DELETE
                  </button>
                <% end %>
              </div>
            </form>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────

  defp load_data(socket) do
    api_entries = ApiConfig.get_entries("global")
    var_defs = VariableStore.list_for_group("global") |> Enum.filter(& &1.active)

    # Group variable keys by source_id (for the table)
    vars_by_source =
      var_defs
      |> Enum.filter(& &1.source_id)
      |> Enum.group_by(& &1.source_id)
      |> Map.new(fn {sid, defs} -> {sid, Enum.map(defs, & &1.key)} end)

    # Group full variable details by source_id (for the edit panel)
    var_details_by_source =
      var_defs
      |> Enum.filter(& &1.source_id)
      |> Enum.group_by(& &1.source_id)

    socket
    |> assign(:api_entries, api_entries)
    |> assign(:vars_by_source, vars_by_source)
    |> assign(:var_details_by_source, var_details_by_source)
    |> load_poller_status()
  end

  defp load_poller_status(socket) do
    poller = TradingDesk.Data.Poller.status()

    by_source =
      poller.sources
      |> Map.new(fn src -> {to_string(src.source), src} end)

    assign(socket, :poller_by_source, by_source)
  end
end
