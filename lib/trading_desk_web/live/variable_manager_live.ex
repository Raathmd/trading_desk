defmodule TradingDesk.VariableManagerLive do
  @moduledoc """
  LiveView for managing variable definitions.

  Route: /variables

  Features:
    - View all variables grouped by product_group and group_name
    - Add / edit / delete variable definitions
    - For manual variables: set current value directly from the UI
    - For file-based variables: upload a CSV to populate values
    - Real-time current-value column pulled from LiveState

  Adding a new variable with source_type = "api" and fetch_mode = "json_get"
  automatically makes it polled on the next :custom poller tick — no Elixir
  code change required.
  """
  use Phoenix.LiveView

  alias TradingDesk.Variables.{VariableDefinition, VariableStore}
  alias TradingDesk.Data.LiveState

  @group_order ~w(environment operations commercial)
  @source_type_opts [{"API (auto-polled)", "api"}, {"Manual (trader sets)", "manual"}, {"File (CSV upload)", "file"}]
  @fetch_mode_opts  [{"Elixir module (built-in sources)", "module"}, {"Generic JSON GET", "json_get"}]
  @type_opts        [{"Float / numeric", "float"}, {"Boolean (on/off)", "boolean"}]
  @group_name_opts  [{"Environment", "environment"}, {"Operations", "operations"}, {"Commercial", "commercial"}]

  # ──────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TradingDesk.PubSub, "live_data")
    end

    allow_upload(socket, :csv_file,
      accept: ~w(.csv .txt),
      max_entries: 1,
      max_file_size: 5_000_000
    )

    groups = VariableStore.product_groups()
    selected = List.first(groups) || "global"

    socket =
      socket
      |> assign(:product_groups, groups)
      |> assign(:selected_group, selected)
      |> assign(:editing, nil)
      |> assign(:changeset, nil)
      |> assign(:upload_state, %{var_key: nil, status: :idle, message: nil})
      |> assign(:delete_confirm, nil)
      |> load_variables(selected)
      |> load_live_values()

    {:ok, socket}
  end

  @impl true
  def handle_info({:data_updated, _source}, socket) do
    {:noreply, load_live_values(socket)}
  end

  @impl true
  def handle_info({:supplementary_updated, _}, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  # ──────────────────────────────────────────────────────────
  # Events — navigation
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_group", %{"group" => group}, socket) do
    socket =
      socket
      |> assign(:selected_group, group)
      |> assign(:editing, nil)
      |> assign(:changeset, nil)
      |> load_variables(group)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_group", %{"name" => name}, socket) do
    name = name |> String.trim() |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_")

    if name == "" do
      {:noreply, put_flash(socket, :error, "Group name cannot be empty")}
    else
      groups = (socket.assigns.product_groups ++ [name]) |> Enum.uniq() |> Enum.sort()

      socket =
        socket
        |> assign(:product_groups, groups)
        |> assign(:selected_group, name)
        |> assign(:variables, [])
        |> assign(:editing, nil)

      {:noreply, socket}
    end
  end

  # ──────────────────────────────────────────────────────────
  # Events — CRUD
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("new_variable", _params, socket) do
    default = %VariableDefinition{product_group: socket.assigns.selected_group}
    cs      = VariableStore.change(default, %{})

    {:noreply, socket |> assign(:editing, :new) |> assign(:changeset, cs)}
  end

  @impl true
  def handle_event("edit_variable", %{"id" => id}, socket) do
    var = VariableStore.get!(String.to_integer(id))
    cs  = VariableStore.change(var, %{})

    {:noreply, socket |> assign(:editing, var) |> assign(:changeset, cs)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(:editing, nil) |> assign(:changeset, nil)}
  end

  @impl true
  def handle_event("validate", %{"variable_definition" => params}, socket) do
    var = editing_struct(socket)
    cs  = VariableStore.change(var, params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, cs)}
  end

  @impl true
  def handle_event("save_variable", %{"variable_definition" => params}, socket) do
    # Attach the product_group from the current UI selection (can't be changed in form)
    params = Map.put(params, "product_group", socket.assigns.selected_group)

    result =
      case socket.assigns.editing do
        :new ->
          VariableStore.create(params)

        %VariableDefinition{} = existing ->
          VariableStore.update(existing, params)
      end

    case result do
      {:ok, _var} ->
        socket =
          socket
          |> put_flash(:info, "Variable saved.")
          |> assign(:editing, nil)
          |> assign(:changeset, nil)
          |> load_variables(socket.assigns.selected_group)
          |> refresh_product_groups()

        {:noreply, socket}

      {:error, cs} ->
        {:noreply, assign(socket, :changeset, cs)}
    end
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, :delete_confirm, String.to_integer(id))}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  @impl true
  def handle_event("delete_variable", %{"id" => id}, socket) do
    VariableStore.delete(String.to_integer(id))

    socket =
      socket
      |> put_flash(:info, "Variable deleted.")
      |> assign(:delete_confirm, nil)
      |> assign(:editing, nil)
      |> load_variables(socket.assigns.selected_group)
      |> refresh_product_groups()

    {:noreply, socket}
  end

  # ──────────────────────────────────────────────────────────
  # Events — manual value set
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("set_manual_value", %{"key" => key, "value" => raw_value}, socket) do
    var = Enum.find(socket.assigns.variables, &(&1.key == key))

    if var do
      parsed =
        case var.type do
          "boolean" -> raw_value in ~w(true 1)
          _         ->
            case Float.parse(raw_value) do
              {f, _} -> f
              :error  -> var.default_value
            end
        end

      # For core solver variables → update the Variables struct via LiveState
      # For extra variables → put into extra_vars
      if var.solver_position do
        LiveState.update(:manual, %{String.to_atom(key) => parsed})
      else
        LiveState.set_extra(%{key => parsed})
      end

      {:noreply, load_live_values(socket)}
    else
      {:noreply, socket}
    end
  end

  # ──────────────────────────────────────────────────────────
  # Events — file upload
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_event("open_upload", %{"key" => key}, socket) do
    {:noreply, assign(socket, :upload_state, %{var_key: key, status: :idle, message: nil})}
  end

  @impl true
  def handle_event("close_upload", _params, socket) do
    {:noreply, assign(socket, :upload_state, %{var_key: nil, status: :idle, message: nil})}
  end

  @impl true
  def handle_event("process_csv", _params, socket) do
    file_vars = VariableStore.file_vars_for_group(socket.assigns.selected_group)

    result =
      consume_uploaded_entries(socket, :csv_file, fn %{path: path}, _entry ->
        parse_csv_for_vars(path, file_vars)
      end)

    case result do
      [{:ok, updates}] when map_size(updates) > 0 ->
        # Push updates into LiveState
        {struct_updates, extra_updates} = partition_updates(updates)

        if map_size(struct_updates) > 0 do
          LiveState.update(:file, struct_updates)
        end

        if map_size(extra_updates) > 0 do
          LiveState.set_extra(extra_updates)
        end

        updated_keys = Map.keys(updates) |> Enum.join(", ")

        socket =
          socket
          |> assign(:upload_state, %{var_key: nil, status: :done,
               message: "Updated: #{updated_keys}"})
          |> load_live_values()

        {:noreply, socket}

      _ ->
        socket =
          assign(socket, :upload_state, %{var_key: nil, status: :error,
            message: "No matching columns found. Check file_column settings."})

        {:noreply, socket}
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
            VARIABLE MANAGER
          </div>
          <div style="font-size:11px;color:#475569;margin-top:2px">
            Database-driven variable definitions · all solver inputs · dynamic polling
          </div>
        </div>
        <div style="display:flex;gap:8px;align-items:center">
          <a href="/" style="font-size:11px;color:#475569;text-decoration:none;padding:4px 10px;
               border:1px solid #1e293b;border-radius:4px">← Dashboard</a>
          <button phx-click="new_variable"
            style="font-size:11px;font-weight:700;padding:6px 16px;border-radius:5px;cursor:pointer;
                   background:#1e3a5f;border:1px solid #2563eb;color:#93c5fd;letter-spacing:0.5px">
            + ADD VARIABLE
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

      <%!-- Upload status --%>
      <%= if @upload_state.message do %>
        <div style={"background:#{if @upload_state.status == :error, do: "#1f0000", else: "#052e16"};
                     border:1px solid #{if @upload_state.status == :error, do: "#dc2626", else: "#16a34a"};
                     border-radius:6px;padding:8px 14px;margin-bottom:14px;font-size:12px;
                     color:#{if @upload_state.status == :error, do: "#fca5a5", else: "#86efac"}"}>
          <%= @upload_state.message %>
        </div>
      <% end %>

      <div style="display:grid;grid-template-columns:minmax(0,1fr) #{if @editing, do: "420px", else: "0px"};gap:20px;transition:grid-template-columns 0.2s">

        <%!-- LEFT: Variable table --%>
        <div>
          <%!-- Product group tabs --%>
          <div style="display:flex;gap:4px;margin-bottom:14px;flex-wrap:wrap;align-items:center">
            <%= for pg <- @product_groups do %>
              <button phx-click="select_group" phx-value-group={pg}
                style={"font-size:11px;font-weight:700;padding:4px 12px;border-radius:4px;cursor:pointer;
                        letter-spacing:0.5px;border:1px solid #{if pg == @selected_group, do: "#2563eb", else: "#1e293b"};
                        background:#{if pg == @selected_group, do: "#0d1f3c", else: "#0a0f18"};
                        color:#{if pg == @selected_group, do: "#60a5fa", else: "#475569"}"}>
                <%= String.upcase(pg) %>
                <span style="font-size:10px;font-weight:400;color:#475569">
                  (<%= Enum.count(@variables, &(&1.product_group == pg)) %>)
                </span>
              </button>
            <% end %>

            <%!-- Add new product group --%>
            <form phx-submit="add_group" style="display:flex;gap:4px;margin-left:8px">
              <input type="text" name="name" placeholder="new-group"
                style="font-size:11px;background:#0a0f18;border:1px solid #1e293b;border-radius:4px;
                       color:#c8d6e5;padding:3px 8px;width:110px;font-family:monospace" />
              <button type="submit"
                style="font-size:11px;padding:3px 8px;border-radius:4px;cursor:pointer;
                       border:1px solid #1e293b;background:#0a0f18;color:#64748b">
                + group
              </button>
            </form>
          </div>

          <%!-- Variable groups --%>
          <%= for group_name <- @group_order do %>
            <%
              group_vars = Enum.filter(@variables, &(&1.group_name == group_name))
            %>
            <%= if group_vars != [] do %>
              <div style="margin-bottom:20px">
                <div style="font-size:11px;color:#475569;letter-spacing:1px;font-weight:700;
                            margin-bottom:8px;display:flex;align-items:center;gap:8px">
                  <%= String.upcase(group_name) %>
                  <span style="font-size:10px;color:#1e293b">━━━━━━━━━━━━━━━━━━━━━</span>
                </div>

                <table style="width:100%;border-collapse:collapse">
                  <thead>
                    <tr style="font-size:10px;color:#334155;letter-spacing:0.5px">
                      <th style="text-align:left;padding:4px 8px;font-weight:700">KEY</th>
                      <th style="text-align:left;padding:4px 8px;font-weight:700">LABEL</th>
                      <th style="text-align:left;padding:4px 8px;font-weight:700">UNIT</th>
                      <th style="text-align:left;padding:4px 8px;font-weight:700">SOURCE</th>
                      <th style="text-align:right;padding:4px 8px;font-weight:700">CURRENT</th>
                      <th style="text-align:left;padding:4px 8px;font-weight:700">SOLVER#</th>
                      <th style="padding:4px 8px"></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for var <- group_vars do %>
                      <%
                        current_val = get_current_value(var, assigns)
                        source_color = source_color(var.source_type, var.source_id)
                        is_editing_this = match?(%VariableDefinition{id: ^(var.id)}, @editing)
                        is_manual = var.source_type == "manual"
                        is_file   = var.source_type == "file"
                      %>
                      <tr style={"background:#{if is_editing_this, do: "#0d1f3c", else: "transparent"};
                                  border-bottom:1px solid #0f172a;transition:background 0.15s"}
                          phx-click="edit_variable" phx-value-id={var.id}
                          style="cursor:pointer">
                        <td style="padding:6px 8px;font-size:11px;font-family:monospace;color:#60a5fa">
                          <%= var.key %>
                          <%= unless var.active do %>
                            <span style="font-size:9px;color:#475569;margin-left:4px">INACTIVE</span>
                          <% end %>
                        </td>
                        <td style="padding:6px 8px;font-size:11px;color:#c8d6e5"><%= var.label %></td>
                        <td style="padding:6px 8px;font-size:11px;color:#64748b"><%= var.unit %></td>
                        <td style="padding:6px 8px">
                          <span style={"font-size:10px;font-weight:700;padding:2px 6px;border-radius:4px;#{source_color}"}>
                            <%= source_badge(var) %>
                          </span>
                        </td>

                        <%!-- Current value cell: input for manual, display for others --%>
                        <td style="padding:4px 8px;text-align:right" phx-click="" phx-value="">
                          <%= if is_manual do %>
                            <form phx-submit="set_manual_value" phx-click="set_manual_value"
                                  style="display:flex;justify-content:flex-end;gap:4px"
                                  onclick="event.stopPropagation()">
                              <input type="hidden" name="key" value={var.key} />
                              <%= if var.type == "boolean" do %>
                                <button type="button"
                                  phx-click="set_manual_value"
                                  phx-value-key={var.key}
                                  phx-value-value={if truthy_value?(current_val), do: "false", else: "true"}
                                  onclick="event.stopPropagation()"
                                  style={"font-size:10px;font-weight:700;padding:2px 10px;border-radius:4px;cursor:pointer;
                                          border:1px solid #{if truthy_value?(current_val), do: "#16a34a", else: "#475569"};
                                          background:#{if truthy_value?(current_val), do: "#052e16", else: "#0a0f18"};
                                          color:#{if truthy_value?(current_val), do: "#86efac", else: "#64748b"}"}>
                                  <%= if truthy_value?(current_val), do: "ON", else: "OFF" %>
                                </button>
                              <% else %>
                                <input type="number" name="value"
                                  value={format_value(current_val)}
                                  step={var.step || "any"}
                                  min={var.min_val} max={var.max_val}
                                  onclick="event.stopPropagation()"
                                  style="font-size:11px;background:#111827;border:1px solid #1e293b;
                                         border-radius:4px;color:#c8d6e5;padding:2px 6px;
                                         width:90px;text-align:right;font-family:monospace" />
                                <button type="submit" onclick="event.stopPropagation()"
                                  style="font-size:10px;padding:2px 6px;border-radius:4px;cursor:pointer;
                                         border:1px solid #1e3a5f;background:#0d1f3c;color:#60a5fa">
                                  SET
                                </button>
                              <% end %>
                            </form>
                          <% else %>
                            <span style="font-size:12px;font-weight:700;color:#f1f5f9;font-family:monospace">
                              <%= format_value(current_val) %>
                            </span>
                            <span style="font-size:10px;color:#475569;margin-left:2px"><%= var.unit %></span>
                          <% end %>
                        </td>

                        <td style="padding:6px 8px;font-size:10px;color:#334155;font-family:monospace">
                          <%= if var.solver_position, do: "##{var.solver_position}", else: "—" %>
                        </td>

                        <td style="padding:6px 8px;text-align:right">
                          <div style="display:flex;gap:4px;justify-content:flex-end"
                               onclick="event.stopPropagation()">
                            <%= if is_file do %>
                              <button phx-click="open_upload" phx-value-key={var.key}
                                style="font-size:10px;padding:2px 8px;border-radius:3px;cursor:pointer;
                                       border:1px solid #1e3a5f;background:#0d1f3c;color:#60a5fa">
                                ↑ CSV
                              </button>
                            <% end %>
                            <button phx-click="edit_variable" phx-value-id={var.id}
                              style="font-size:10px;padding:2px 8px;border-radius:3px;cursor:pointer;
                                     border:1px solid #1e293b;background:#0a0f18;color:#94a3b8">
                              ✎
                            </button>
                            <%= if @delete_confirm == var.id do %>
                              <button phx-click="delete_variable" phx-value-id={var.id}
                                style="font-size:10px;padding:2px 8px;border-radius:3px;cursor:pointer;
                                       border:1px solid #dc2626;background:#1f0000;color:#fca5a5;font-weight:700">
                                CONFIRM
                              </button>
                              <button phx-click="cancel_delete"
                                style="font-size:10px;padding:2px 8px;border-radius:3px;cursor:pointer;
                                       border:1px solid #1e293b;background:#0a0f18;color:#64748b">
                                ✕
                              </button>
                            <% else %>
                              <button phx-click="confirm_delete" phx-value-id={var.id}
                                style="font-size:10px;padding:2px 8px;border-radius:3px;cursor:pointer;
                                       border:1px solid #1e293b;background:#0a0f18;color:#64748b">
                                ✕
                              </button>
                            <% end %>
                          </div>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>

          <%!-- File upload modal (shown when upload_state has a var_key) --%>
          <%= if @upload_state.var_key do %>
            <div style="position:fixed;inset:0;background:rgba(0,0,0,0.7);z-index:50;
                        display:flex;align-items:center;justify-content:center">
              <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:10px;
                          padding:24px;width:440px">
                <div style="font-size:14px;font-weight:700;color:#f1f5f9;margin-bottom:4px">
                  Upload CSV — <%= @upload_state.var_key %>
                </div>
                <div style="font-size:11px;color:#475569;margin-bottom:16px">
                  First row = headers. The system reads each column whose name matches
                  a variable's <code>file_column</code> setting and takes the last row's value.
                </div>

                <form phx-submit="process_csv" phx-change="validate">
                  <div phx-drop-target={@uploads.csv_file.ref}
                    style="border:2px dashed #1e3a5f;border-radius:8px;padding:24px;text-align:center;
                           margin-bottom:12px;cursor:pointer">
                    <label for={@uploads.csv_file.ref}
                      style="font-size:12px;color:#64748b;cursor:pointer">
                      Drop CSV here or click to select
                    </label>
                    <.live_file_input upload={@uploads.csv_file} style="display:none" />
                  </div>

                  <%= for entry <- @uploads.csv_file.entries do %>
                    <div style="font-size:11px;color:#86efac;margin-bottom:8px">
                      ✓ <%= entry.client_name %> (<%= Float.round(entry.client_size / 1024, 1) %> KB)
                    </div>
                  <% end %>

                  <div style="display:flex;gap:8px;justify-content:flex-end">
                    <button type="button" phx-click="close_upload"
                      style="font-size:11px;padding:5px 14px;border-radius:4px;cursor:pointer;
                             border:1px solid #1e293b;background:#0a0f18;color:#64748b">
                      Cancel
                    </button>
                    <button type="submit" disabled={@uploads.csv_file.entries == []}
                      style="font-size:11px;font-weight:700;padding:5px 14px;border-radius:4px;cursor:pointer;
                             border:1px solid #2563eb;background:#0d1f3c;color:#60a5fa">
                      Process File
                    </button>
                  </div>
                </form>
              </div>
            </div>
          <% end %>

        </div>

        <%!-- RIGHT: Edit / Add panel --%>
        <%= if @editing && @changeset do %>
          <div style="background:#0a0f18;border:1px solid #1e293b;border-radius:10px;
                      padding:18px;height:fit-content;position:sticky;top:20px">
            <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:14px">
              <div style="font-size:13px;font-weight:700;color:#f1f5f9">
                <%= if @editing == :new, do: "Add Variable", else: "Edit Variable" %>
              </div>
              <button phx-click="cancel_edit"
                style="font-size:11px;color:#475569;background:none;border:none;cursor:pointer">
                ✕ Cancel
              </button>
            </div>

            <.form for={@changeset} phx-change="validate" phx-submit="save_variable"
                   style="display:flex;flex-direction:column;gap:10px">

              <%!-- Key (immutable after create) --%>
              <div>
                <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">KEY *</label>
                <.input field={@changeset[:key]} type="text" placeholder="snake_case_key"
                  disabled={@editing != :new}
                  style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                         color:#60a5fa;padding:5px 8px;font-size:11px;font-family:monospace;box-sizing:border-box" />
                <div style="font-size:10px;color:#475569;margin-top:2px">Letters, digits, underscores. Cannot change after save.</div>
              </div>

              <%!-- Label --%>
              <div>
                <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">LABEL *</label>
                <.input field={@changeset[:label]} type="text" placeholder="Display name"
                  style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                         color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
              </div>

              <%!-- Unit + Group in a row --%>
              <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">UNIT</label>
                  <.input field={@changeset[:unit]} type="text" placeholder="ft, $/t, °F…"
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                </div>
                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">TYPE</label>
                  <.input field={@changeset[:type]} type="select" options={@type_opts}
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                </div>
              </div>

              <%!-- Group name --%>
              <div>
                <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">DISPLAY GROUP</label>
                <.input field={@changeset[:group_name]} type="select" options={@group_name_opts}
                  style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                         color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
              </div>

              <%!-- Source type --%>
              <div>
                <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">SOURCE TYPE</label>
                <.input field={@changeset[:source_type]} type="select" options={@source_type_opts}
                  style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                         color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
              </div>

              <%!-- API-specific fields --%>
              <%
                current_source_type = Ecto.Changeset.get_field(@changeset, :source_type, "manual")
                current_fetch_mode  = Ecto.Changeset.get_field(@changeset, :fetch_mode, "manual")
              %>
              <%= if current_source_type == "api" do %>
                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">SOURCE ID</label>
                  <.input field={@changeset[:source_id]} type="text"
                    placeholder="e.g. eia, usgs, my_custom_feed"
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;font-family:monospace;box-sizing:border-box" />
                  <div style="font-size:10px;color:#475569;margin-top:2px">
                    Must match an entry in the API tab (api_configs table).
                  </div>
                </div>

                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">FETCH MODE</label>
                  <.input field={@changeset[:fetch_mode]} type="select" options={@fetch_mode_opts}
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                </div>

                <%= if current_fetch_mode == "module" do %>
                  <div>
                    <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">MODULE NAME</label>
                    <.input field={@changeset[:module_name]} type="text"
                      placeholder="TradingDesk.Data.API.EIA"
                      style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                             color:#c8d6e5;padding:5px 8px;font-size:11px;font-family:monospace;box-sizing:border-box" />
                  </div>
                <% end %>

                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">RESPONSE PATH</label>
                  <.input field={@changeset[:response_path]} type="text"
                    placeholder="nat_gas  or  data.price.value"
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;font-family:monospace;box-sizing:border-box" />
                  <div style="font-size:10px;color:#475569;margin-top:2px">
                    Key in the module's return map, or dot-separated JSON path for json_get.
                  </div>
                </div>
              <% end %>

              <%!-- File column --%>
              <%= if current_source_type == "file" do %>
                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">FILE COLUMN</label>
                  <.input field={@changeset[:file_column]} type="text"
                    placeholder="inventory_tons"
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;font-family:monospace;box-sizing:border-box" />
                  <div style="font-size:10px;color:#475569;margin-top:2px">
                    CSV column header name. The last row's value is used.
                  </div>
                </div>
              <% end %>

              <%!-- Default + min/max/step --%>
              <%= if Ecto.Changeset.get_field(@changeset, :type) != "boolean" do %>
                <div>
                  <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">DEFAULT VALUE</label>
                  <.input field={@changeset[:default_value]} type="number" step="any"
                    style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                           color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                </div>
                <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:6px">
                  <div>
                    <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">MIN</label>
                    <.input field={@changeset[:min_val]} type="number" step="any"
                      style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                             color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                  </div>
                  <div>
                    <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">MAX</label>
                    <.input field={@changeset[:max_val]} type="number" step="any"
                      style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                             color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                  </div>
                  <div>
                    <label style="font-size:10px;color:#64748b;font-weight:700;display:block;margin-bottom:3px">STEP</label>
                    <.input field={@changeset[:step]} type="number" step="any"
                      style="width:100%;background:#111827;border:1px solid #1e293b;border-radius:4px;
                             color:#c8d6e5;padding:5px 8px;font-size:11px;box-sizing:border-box" />
                  </div>
                </div>
              <% end %>

              <%!-- Active --%>
              <div style="display:flex;align-items:center;gap:8px;margin-top:4px">
                <.input field={@changeset[:active]} type="checkbox" />
                <label style="font-size:11px;color:#c8d6e5">Active (included in polling)</label>
              </div>

              <%!-- Errors --%>
              <%= if @changeset.action do %>
                <div style="font-size:10px;color:#fca5a5;background:#1f0000;border:1px solid #dc2626;
                            border-radius:4px;padding:8px">
                  <%= for {field, {msg, _}} <- @changeset.errors do %>
                    <div><strong><%= field %>:</strong> <%= msg %></div>
                  <% end %>
                </div>
              <% end %>

              <button type="submit"
                style="font-size:12px;font-weight:700;padding:8px;border-radius:5px;cursor:pointer;
                       border:1px solid #2563eb;background:#0d1f3c;color:#60a5fa;margin-top:4px">
                SAVE VARIABLE
              </button>
            </.form>
          </div>
        <% end %>

      </div>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────

  defp load_variables(socket, group) do
    all = VariableStore.list_all()
    # Show selected group's vars (and global vars when a specific group is selected)
    visible =
      Enum.filter(all, fn v ->
        v.product_group == group or (group != "global" and v.product_group == "global")
      end)

    assign(socket, :variables, visible)
  end

  defp load_live_values(socket) do
    vars   = LiveState.get()
    extra  = LiveState.get_extra()
    struct_map = Map.from_struct(vars) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    combined   = Map.merge(struct_map, extra)

    assign(socket, :live_values, combined)
  end

  defp refresh_product_groups(socket) do
    groups = VariableStore.product_groups()
    assign(socket, :product_groups, groups)
  end

  defp editing_struct(%{assigns: %{editing: :new, selected_group: pg}}),
    do: %VariableDefinition{product_group: pg}
  defp editing_struct(%{assigns: %{editing: %VariableDefinition{} = var}}), do: var

  defp get_current_value(var, assigns) do
    Map.get(assigns.live_values, var.key, var.default_value)
  end

  defp format_value(nil), do: "—"
  defp format_value(true), do: "true"
  defp format_value(false), do: "false"
  defp format_value(v) when is_float(v) do
    if v == Float.round(v, 0), do: to_string(trunc(v)), else: Float.round(v, 2) |> to_string()
  end
  defp format_value(v), do: to_string(v)

  defp truthy_value?(true), do: true
  defp truthy_value?("true"), do: true
  defp truthy_value?(1), do: true
  defp truthy_value?(1.0), do: true
  defp truthy_value?(_), do: false

  defp source_badge(%{source_type: "manual"}), do: "MANUAL"
  defp source_badge(%{source_type: "file"}),   do: "FILE"
  defp source_badge(%{source_id: nil}),         do: "API"
  defp source_badge(%{source_id: id}),          do: String.upcase(id)

  defp source_color("manual", _),              do: "color:#94a3b8;background:#1e293b"
  defp source_color("file",   _),              do: "color:#f59e0b;background:#292100"
  defp source_color("api",    "usgs"),         do: "color:#34d399;background:#052e16"
  defp source_color("api",    "noaa"),         do: "color:#34d399;background:#052e16"
  defp source_color("api",    "usace"),        do: "color:#34d399;background:#052e16"
  defp source_color("api",    "eia"),          do: "color:#60a5fa;background:#0d1f3c"
  defp source_color("api",    "delivered_prices"), do: "color:#a78bfa;background:#1a0f2e"
  defp source_color("api",    "argus"),        do: "color:#a78bfa;background:#1a0f2e"
  defp source_color("api",    "icis"),         do: "color:#a78bfa;background:#1a0f2e"
  defp source_color("api",    "broker"),       do: "color:#f9a8d4;background:#2d0a1a"
  defp source_color("api",    "tms"),          do: "color:#f9a8d4;background:#2d0a1a"
  defp source_color("api",    "insight"),      do: "color:#fbbf24;background:#292100"
  defp source_color("api",    "sap"),          do: "color:#fb923c;background:#2d1000"
  defp source_color("api",    _),              do: "color:#60a5fa;background:#0d1f3c"
  defp source_color(_, _),                    do: "color:#64748b;background:#1e293b"

  # ──────────────────────────────────────────────────────────
  # CSV parsing
  # ──────────────────────────────────────────────────────────

  defp parse_csv_for_vars(path, file_vars) do
    with {:ok, content} <- File.read(path),
         [header_row | data_rows] when data_rows != [] <- String.split(content, ~r/\r?\n/, trim: true) do
      headers = header_row |> String.split(",") |> Enum.map(&String.trim/1)

      # Take the last non-empty data row
      last_row =
        data_rows
        |> Enum.filter(&(String.trim(&1) != ""))
        |> List.last()
        |> String.split(",")
        |> Enum.map(&String.trim/1)

      row_map = Enum.zip(headers, last_row) |> Map.new()

      updates =
        Enum.reduce(file_vars, %{}, fn var_def, acc ->
          col = var_def.file_column

          case Map.get(row_map, col) do
            nil -> acc
            raw ->
              parsed =
                case var_def.type do
                  "boolean" -> raw in ~w(true 1 yes TRUE YES)
                  _ ->
                    case Float.parse(raw) do
                      {f, _} -> f
                      :error  -> nil
                    end
                end

              if parsed != nil, do: Map.put(acc, var_def.key, parsed), else: acc
          end
        end)

      {:ok, updates}
    else
      _ -> {:ok, %{}}
    end
  end

  defp partition_updates(updates) do
    struct_keys = Map.keys(%TradingDesk.Variables{}) |> Enum.map(&to_string/1)

    Enum.reduce(updates, {%{}, %{}}, fn {key, val}, {struct_acc, extra_acc} ->
      if key in struct_keys do
        {Map.put(struct_acc, String.to_existing_atom(key), val), extra_acc}
      else
        {struct_acc, Map.put(extra_acc, key, val)}
      end
    end)
  end
end
