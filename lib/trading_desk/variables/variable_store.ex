defmodule TradingDesk.Variables.VariableStore do
  @moduledoc """
  Context for managing variable definitions.

  Variable definitions describe every value that the system tracks or that the
  solver consumes.  They live in the `variable_definitions` table and are managed
  at runtime via the Variable Manager LiveView page (`/variables`).

  ## Usage

    # Seed or upsert
    VariableStore.upsert(%{product_group: "global", key: "my_var", label: "My Var", ...})

    # List for display
    VariableStore.list_all()
    VariableStore.list_for_group("global")

    # Dynamic poller: group API variables by their source
    VariableStore.active_api_vars() |> Enum.group_by(& &1.source_id)

    # New json_get sources not handled by legacy poller modules
    VariableStore.custom_json_sources()
  """

  import Ecto.Query
  alias TradingDesk.Repo
  alias TradingDesk.Variables.VariableDefinition

  # Legacy source_ids handled by hardcoded Elixir modules in the poller.
  # Variables referencing these sources are already polled; they are NOT
  # re-polled by the generic :custom handler.
  @legacy_sources ~w(usgs noaa usace eia market broker internal vessel_tracking tides forecast)

  # ──────────────────────────────────────────────────────────
  # READ
  # ──────────────────────────────────────────────────────────

  @doc "All variable definitions, sorted by product_group → display_order → key."
  def list_all do
    Repo.all(from v in VariableDefinition,
      order_by: [asc: v.product_group, asc: v.display_order, asc: v.key])
  end

  @doc "All variable definitions for a specific product group."
  def list_for_group(product_group) do
    Repo.all(from v in VariableDefinition,
      where: v.product_group == ^product_group,
      order_by: [asc: v.display_order, asc: v.key])
  end

  @doc "Active, API-sourced variable definitions across all product groups."
  def active_api_vars do
    Repo.all(from v in VariableDefinition,
      where: v.source_type == "api" and v.active == true)
  end

  @doc """
  Active API variables grouped by source_id, excluding legacy module sources.

  Used by the dynamic `:custom` poller to call any `json_get` source that
  was added via the Variable Manager without writing Elixir code.
  """
  def custom_json_sources do
    active_api_vars()
    |> Enum.filter(&(&1.fetch_mode == "json_get" and &1.source_id not in @legacy_sources))
    |> Enum.group_by(& &1.source_id)
  end

  @doc "All distinct product groups that have at least one variable definition."
  def product_groups do
    Repo.all(from v in VariableDefinition,
      select: v.product_group,
      distinct: true,
      order_by: v.product_group)
  end

  @doc "All file-based variable definitions for a product group."
  def file_vars_for_group(product_group) do
    Repo.all(from v in VariableDefinition,
      where: v.product_group == ^product_group and v.source_type == "file" and v.active == true,
      order_by: [asc: v.display_order, asc: v.key])
  end

  def get(id), do: Repo.get(VariableDefinition, id)
  def get!(id), do: Repo.get!(VariableDefinition, id)

  def get_by_key(product_group, key) do
    Repo.get_by(VariableDefinition, product_group: product_group, key: key)
  end

  def new_changeset(attrs \\ %{}) do
    VariableDefinition.changeset(%VariableDefinition{}, attrs)
  end

  def change(%VariableDefinition{} = var, attrs \\ %{}) do
    VariableDefinition.changeset(var, attrs)
  end

  # ──────────────────────────────────────────────────────────
  # WRITE
  # ──────────────────────────────────────────────────────────

  @doc """
  Insert a new variable definition or update all fields if (product_group, key)
  already exists.  Safe to call from seeds and CI.
  """
  def upsert(attrs) when is_map(attrs) do
    %VariableDefinition{}
    |> VariableDefinition.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:product_group, :key]
    )
  end

  @doc "Create a new variable definition."
  def create(attrs) do
    %VariableDefinition{}
    |> VariableDefinition.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Update an existing variable definition."
  def update(%VariableDefinition{} = var, attrs) do
    var
    |> VariableDefinition.changeset(attrs)
    |> Repo.update()
  end

  @doc "Delete a variable definition by id."
  def delete(id) when is_integer(id), do: id |> get!() |> Repo.delete()
  def delete(%VariableDefinition{} = var), do: Repo.delete(var)

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  @doc "Default values map for all active variables: %{\"key\" => default_value}"
  def defaults_map do
    list_all()
    |> Enum.filter(& &1.active)
    |> Map.new(fn v -> {v.key, v.default_value} end)
  end

  @doc """
  Default values as atom-keyed map for initializing LiveState.

  Returns `%{atom_key => default_value}` for all active variables in the given
  product group (defaults to "global").  Boolean-typed variables return `false`
  instead of `0.0`.
  """
  def defaults_atom_map(product_group \\ "global") do
    list_for_group(product_group)
    |> Enum.filter(& &1.active)
    |> Map.new(fn v ->
      val = if v.type == "boolean", do: v.default_value != 0.0, else: v.default_value
      {String.to_atom(v.key), val}
    end)
  end

  @doc """
  Variable metadata in the same format as `TradingDesk.Variables.metadata/0`.

  Returns a list of maps with `:key`, `:label`, `:unit`, `:min`, `:max`, `:step`,
  `:source`, `:group`, and `:type` — compatible with all existing UI consumers.
  """
  def metadata(product_group \\ "global") do
    list_for_group(product_group)
    |> Enum.filter(& &1.active)
    |> Enum.map(fn v ->
      %{
        key:    String.to_atom(v.key),
        label:  v.label,
        unit:   v.unit || "",
        min:    v.min_val,
        max:    v.max_val,
        step:   v.step,
        source: if(v.source_id, do: String.to_atom(v.source_id), else: :manual),
        group:  String.to_atom(v.group_name),
        type:   if(v.type == "boolean", do: :boolean, else: :float)
      }
    end)
  end

  @doc """
  Variable keys that have a solver_position, ordered by position.

  Used by `to_binary` to dynamically build the Zig solver binary payload
  from a values map instead of a hardcoded struct.
  """
  def solver_keys(product_group \\ "global") do
    Repo.all(from v in VariableDefinition,
      where: v.product_group == ^product_group and
             v.active == true and
             not is_nil(v.solver_position),
      order_by: [asc: v.solver_position],
      select: {v.key, v.type})
  end

  @doc """
  Active API variables grouped by source_id.

  Returns `%{source_id => [%VariableDefinition{}, ...]}` for all API-sourced
  variables.  Used by the Poller to know which keys to expect from each source.
  """
  def api_vars_by_source(product_group \\ "global") do
    Repo.all(from v in VariableDefinition,
      where: v.product_group == ^product_group and
             v.source_type == "api" and
             v.active == true)
    |> Enum.group_by(& &1.source_id)
  end

  @doc """
  API source metadata for the scenario dashboard API status tab.

  Returns a map keyed by source atom with description, variables list, etc.,
  built entirely from the variable_definitions table.
  """
  def api_source_metadata(product_group \\ "global") do
    by_source = api_vars_by_source(product_group)

    Map.new(by_source, fn {source_id, var_defs} ->
      {String.to_atom(source_id),
       %{
         variables: Enum.map(var_defs, & &1.key),
         module:    List.first(Enum.map(var_defs, & &1.module_name) |> Enum.reject(&is_nil/1))
       }}
    end)
  end

  @doc """
  Keys expected from a specific poller source.

  Returns a list of atom keys that the Poller should extract when polling
  the given source_id.
  """
  def keys_for_source(source_id) when is_binary(source_id) do
    Repo.all(from v in VariableDefinition,
      where: v.source_id == ^source_id and v.active == true,
      select: v.key)
    |> Enum.map(&String.to_atom/1)
  end

  def keys_for_source(source_id) when is_atom(source_id) do
    keys_for_source(Atom.to_string(source_id))
  end
end
