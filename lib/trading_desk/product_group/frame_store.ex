defmodule TradingDesk.ProductGroup.FrameStore do
  @moduledoc """
  Context for loading product group frame definitions from the database.

  Replaces the hardcoded Frame modules as the primary source of frame data.
  Reads from `product_group_configs`, `variable_definitions`,
  `route_definitions`, and `constraint_definitions` tables and assembles
  the same map shape that `Frame.frame/0` returned.

  Uses `:persistent_term` for caching since frame definitions change rarely.
  Call `invalidate/0` or `invalidate/1` after admin edits to refresh.

  ## Usage

      # Get a full solver frame (cached)
      FrameStore.frame(:ammonia_domestic)

      # List all configured product groups
      FrameStore.list()

      # Force-refresh cache after editing config in the admin UI
      FrameStore.invalidate(:ammonia_domestic)
  """

  import Ecto.Query
  alias TradingDesk.Repo
  alias TradingDesk.DB.{ProductGroupConfig, RouteDefinition, ConstraintDefinition}
  alias TradingDesk.Variables.VariableDefinition

  @cache_prefix :frame_store_

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc "Get the full solver frame for a product group, assembled from DB rows."
  @spec frame(atom()) :: map() | nil
  def frame(product_group) do
    key = cache_key(product_group)

    case safe_get(key) do
      nil ->
        case load_frame(product_group) do
          nil -> nil
          frame ->
            :persistent_term.put(key, frame)
            frame
        end

      frame ->
        frame
    end
  end

  @doc "List all active product group keys from the database."
  @spec list() :: [atom()]
  def list do
    Repo.all(
      from c in ProductGroupConfig,
        where: c.active == true,
        select: c.key,
        order_by: c.key
    )
    |> Enum.map(&String.to_atom/1)
  end

  @doc "List all product groups with display info."
  @spec list_with_info() :: [map()]
  def list_with_info do
    Repo.all(
      from c in ProductGroupConfig,
        where: c.active == true,
        order_by: c.key
    )
    |> Enum.map(fn c ->
      pg = String.to_atom(c.key)
      var_count = Repo.one(from v in VariableDefinition,
        where: v.product_group == ^c.key and v.active == true,
        select: count())
      route_count = Repo.one(from r in RouteDefinition,
        where: r.product_group == ^c.key and r.active == true,
        select: count())

      %{
        id: pg,
        name: c.name,
        product: c.product,
        transport_mode: String.to_atom(c.transport_mode),
        variable_count: var_count,
        route_count: route_count
      }
    end)
  end

  @doc "Resolve an alias or canonical key to the canonical product group key."
  @spec resolve_alias(atom()) :: atom() | nil
  def resolve_alias(product_group) do
    pg_str = Atom.to_string(product_group)

    # Check canonical first
    case Repo.get_by(ProductGroupConfig, key: pg_str, active: true) do
      %ProductGroupConfig{} -> product_group
      nil ->
        # Check aliases
        case Repo.one(
          from c in ProductGroupConfig,
            where: ^pg_str in c.aliases and c.active == true,
            select: c.key,
            limit: 1
        ) do
          nil -> nil
          key -> String.to_atom(key)
        end
    end
  end

  @doc "Check if a product group (or alias) exists in the database."
  @spec exists?(atom()) :: boolean()
  def exists?(product_group), do: resolve_alias(product_group) != nil

  @doc "Invalidate the cached frame for one or all product groups."
  @spec invalidate(atom()) :: :ok
  def invalidate(product_group) do
    :persistent_term.erase(cache_key(product_group))
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec invalidate() :: :ok
  def invalidate do
    list()
    |> Enum.each(&invalidate/1)
  end

  # ──────────────────────────────────────────────────────────
  # WRITE — DB mutations + cache invalidation + seed export
  # ──────────────────────────────────────────────────────────

  @doc "Upsert a product group config. Invalidates cache and exports seed."
  def upsert_config(attrs) do
    result =
      %ProductGroupConfig{}
      |> ProductGroupConfig.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:key]
      )

    case result do
      {:ok, config} ->
        invalidate(String.to_atom(config.key))
        async_export()
        {:ok, config}

      error ->
        error
    end
  end

  @doc "Upsert a route definition. Invalidates cache and exports seed."
  def upsert_route(attrs) do
    result =
      %RouteDefinition{}
      |> RouteDefinition.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:product_group, :key]
      )

    case result do
      {:ok, route} ->
        invalidate(String.to_atom(route.product_group))
        async_export()
        {:ok, route}

      error ->
        error
    end
  end

  @doc "Upsert a constraint definition. Invalidates cache and exports seed."
  def upsert_constraint(attrs) do
    result =
      %ConstraintDefinition{}
      |> ConstraintDefinition.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:product_group, :key]
      )

    case result do
      {:ok, constraint} ->
        invalidate(String.to_atom(constraint.product_group))
        async_export()
        {:ok, constraint}

      error ->
        error
    end
  end

  @doc "Upsert a variable definition. Invalidates cache and exports seed."
  def upsert_variable(attrs) do
    alias TradingDesk.Variables.VariableStore
    result = VariableStore.upsert(attrs)

    case result do
      {:ok, var} ->
        invalidate(String.to_atom(var.product_group))
        async_export()
        {:ok, var}

      error ->
        error
    end
  end

  @doc "Delete a route definition by id."
  def delete_route(id) do
    route = Repo.get!(RouteDefinition, id)
    result = Repo.delete(route)

    case result do
      {:ok, deleted} ->
        invalidate(String.to_atom(deleted.product_group))
        async_export()
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc "Delete a constraint definition by id."
  def delete_constraint(id) do
    constraint = Repo.get!(ConstraintDefinition, id)
    result = Repo.delete(constraint)

    case result do
      {:ok, deleted} ->
        invalidate(String.to_atom(deleted.product_group))
        async_export()
        {:ok, deleted}

      error ->
        error
    end
  end

  # Export seed file asynchronously so it doesn't block the request.
  defp async_export do
    Task.start(fn ->
      try do
        TradingDesk.ProductGroup.SeedExporter.export!()
      rescue
        _ -> :ok
      end
    end)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE — DB loading + frame assembly
  # ──────────────────────────────────────────────────────────

  defp load_frame(product_group) do
    pg_str = Atom.to_string(product_group)

    case Repo.get_by(ProductGroupConfig, key: pg_str, active: true) do
      nil -> nil
      config -> assemble_frame(config)
    end
  end

  defp assemble_frame(%ProductGroupConfig{} = c) do
    variables = load_variables(c.key)
    routes = load_routes(c.key)
    constraints = load_constraints(c.key)

    %{
      id: String.to_atom(c.key),
      name: c.name,
      product: c.product,
      transport_mode: String.to_atom(c.transport_mode),
      geography: c.geography,

      variables: variables,
      routes: routes,
      constraints: constraints,
      api_sources: build_api_sources(variables),
      signal_thresholds: atomize_keys(c.signal_thresholds),
      contract_term_map: atomize_values(c.contract_term_map),
      location_anchors: atomize_values(c.location_anchors),
      price_anchors: atomize_nullable_values(c.price_anchors),
      product_patterns: compile_patterns(c.product_patterns),
      chain_magic: c.chain_magic,
      chain_product_code: c.chain_product_code,
      default_poll_intervals: build_poll_intervals(c.default_poll_intervals),
      solver_binary: c.solver_binary || "solver"
    }
  end

  defp load_variables(product_group) do
    Repo.all(
      from v in VariableDefinition,
        where: v.product_group == ^product_group and v.active == true,
        order_by: [asc: v.display_order, asc: v.key]
    )
    |> Enum.map(&variable_to_map/1)
  end

  defp variable_to_map(%VariableDefinition{} = v) do
    base = %{
      key: String.to_atom(v.key),
      label: v.label,
      unit: v.unit || "",
      min: v.min_val,
      max: v.max_val,
      step: v.step,
      default: default_for_type(v),
      source: if(v.source_id, do: String.to_atom(v.source_id), else: :manual),
      group: String.to_atom(v.group_name),
      type: if(v.type == "boolean", do: :boolean, else: :float),
      delta_threshold: v.delta_threshold || 1.0,
      perturbation: build_perturbation(v)
    }

    base
  end

  defp default_for_type(%{type: "boolean"} = v) do
    (v.default_value || 0.0) != 0.0
  end
  defp default_for_type(v), do: v.default_value || 0.0

  defp build_perturbation(%{type: "boolean"} = v) do
    %{flip_prob: v.perturbation_flip_prob || 0.0}
  end
  defp build_perturbation(v) do
    %{
      stddev: v.perturbation_stddev || 0.0,
      min: v.perturbation_min || v.min_val,
      max: v.perturbation_max || v.max_val
    }
  end

  defp load_routes(product_group) do
    Repo.all(
      from r in RouteDefinition,
        where: r.product_group == ^product_group and r.active == true,
        order_by: [asc: r.display_order, asc: r.key]
    )
    |> Enum.map(&route_to_map/1)
  end

  defp route_to_map(%RouteDefinition{} = r) do
    distance_key = case r.distance_unit do
      "nm" -> :distance_nm
      "km" -> :distance_km
      _    -> :distance_mi
    end

    %{
      key: String.to_atom(r.key),
      name: r.name,
      origin: r.origin,
      destination: r.destination,
      transport_mode: String.to_atom(r.transport_mode),
      freight_variable: safe_atom(r.freight_variable),
      buy_variable: safe_atom(r.buy_variable),
      sell_variable: safe_atom(r.sell_variable),
      typical_transit_days: r.typical_transit_days,
      transit_cost_per_day: r.transit_cost_per_day,
      unit_capacity: r.unit_capacity
    }
    |> Map.put(distance_key, r.distance)
  end

  defp load_constraints(product_group) do
    Repo.all(
      from c in ConstraintDefinition,
        where: c.product_group == ^product_group and c.active == true,
        order_by: [asc: c.display_order, asc: c.key]
    )
    |> Enum.map(&constraint_to_map/1)
  end

  defp constraint_to_map(%ConstraintDefinition{} = c) do
    base = %{
      key: String.to_atom(c.key),
      name: c.name,
      type: String.to_atom(c.constraint_type),
      bound_variable: String.to_atom(c.bound_variable),
      routes: Enum.map(c.routes, &String.to_atom/1)
    }

    base
    |> maybe_put(:terminal, c.terminal)
    |> maybe_put(:destination, c.destination)
    |> maybe_put_atom(:bound_min_variable, c.bound_min_variable)
    |> maybe_put_atom(:outage_variable, c.outage_variable)
    |> maybe_put(:outage_factor, c.outage_factor)
  end

  defp build_api_sources(variables) do
    variables
    |> Enum.group_by(& &1[:source])
    |> Map.new(fn {source, vars} ->
      {source, %{
        module: nil,
        variables: Enum.map(vars, & &1[:key])
      }}
    end)
  end

  defp build_poll_intervals(nil), do: %{}
  defp build_poll_intervals(intervals) when is_map(intervals) do
    Map.new(intervals, fn {k, v} ->
      {String.to_atom(k), v}
    end)
  end

  defp compile_patterns(nil), do: []
  defp compile_patterns(patterns) do
    Enum.map(patterns, fn pat ->
      case Regex.compile(pat, "i") do
        {:ok, regex} -> regex
        _ -> ~r/#{Regex.escape(pat)}/i
      end
    end)
  end

  # ──────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────

  defp cache_key(product_group), do: {:"#{@cache_prefix}#{product_group}"}

  defp safe_get(key) do
    :persistent_term.get(key, nil)
  end

  defp safe_atom(nil), do: nil
  defp safe_atom(s) when is_binary(s), do: String.to_atom(s)

  defp atomize_keys(nil), do: %{}
  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp atomize_values(nil), do: %{}
  defp atomize_values(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, String.to_atom(v)} end)
  end

  defp atomize_nullable_values(nil), do: %{}
  defp atomize_nullable_values(map) when is_map(map) do
    Map.new(map, fn
      {k, nil} -> {k, nil}
      {k, v} -> {k, String.to_atom(v)}
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_atom(map, _key, nil), do: map
  defp maybe_put_atom(map, key, value), do: Map.put(map, key, String.to_atom(value))
end
