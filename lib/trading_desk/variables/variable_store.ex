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
end
