defmodule TradingDesk.Seeds.ProductGroupFramesSeed do
  @moduledoc """
  Seeds product_group_configs, route_definitions, constraint_definitions,
  and per-product-group variable_definitions from the existing hardcoded
  Frame modules.

  Idempotent — uses upsert on unique keys. Safe to re-run.
  """

  alias TradingDesk.Repo
  alias TradingDesk.DB.{ProductGroupConfig, RouteDefinition, ConstraintDefinition}
  alias TradingDesk.Variables.VariableDefinition

  @frames [
    {TradingDesk.ProductGroup.Frames.AmmoniaDomestic, ["ammonia", "uan", "urea"]},
    {TradingDesk.ProductGroup.Frames.AmmoniaInternational, []},
    {TradingDesk.ProductGroup.Frames.SulphurInternational, []},
    {TradingDesk.ProductGroup.Frames.Petcoke, []}
  ]

  def run do
    IO.puts("  → Seeding product group frames (#{length(@frames)} product groups)...")

    for {frame_mod, aliases} <- @frames do
      frame = frame_mod.frame()
      pg = Atom.to_string(frame.id)

      IO.puts("    • #{pg} (#{frame.name})")
      seed_config(frame, aliases)
      seed_variables(frame, pg)
      seed_routes(frame, pg)
      seed_constraints(frame, pg)
    end

    IO.puts("  ✓ Product group frames seeded")
  end

  # ── Product Group Config ──────────────────────────────────────────

  defp seed_config(frame, aliases) do
    attrs = %{
      key: Atom.to_string(frame.id),
      name: frame.name,
      product: frame.product,
      transport_mode: Atom.to_string(frame.transport_mode),
      geography: frame[:geography],
      product_patterns: patterns_to_strings(frame[:product_patterns] || []),
      chain_magic: frame[:chain_magic],
      chain_product_code: frame[:chain_product_code],
      solver_binary: frame[:solver_binary] || "solver",
      signal_thresholds: stringify_keys(frame[:signal_thresholds] || %{}),
      contract_term_map: stringify_term_map(frame[:contract_term_map] || %{}),
      location_anchors: stringify_anchor_map(frame[:location_anchors] || %{}),
      price_anchors: stringify_anchor_map(frame[:price_anchors] || %{}),
      default_poll_intervals: stringify_poll_intervals(frame[:default_poll_intervals] || %{}),
      aliases: aliases,
      active: true
    }

    %ProductGroupConfig{}
    |> ProductGroupConfig.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:key]
    )
  end

  # ── Variables ─────────────────────────────────────────────────────

  defp seed_variables(frame, pg) do
    variables = frame[:variables] || []

    Enum.each(Enum.with_index(variables), fn {v, idx} ->
      source_id = if v[:source], do: Atom.to_string(v[:source]), else: nil

      # Determine source_type and fetch_mode from the api_sources map
      {source_type, fetch_mode, module_name} =
        resolve_source(frame[:api_sources], v[:source], v[:key])

      attrs = %{
        product_group: pg,
        key: Atom.to_string(v.key),
        label: v.label,
        unit: v[:unit] || "",
        group_name: Atom.to_string(v[:group] || :commercial),
        type: Atom.to_string(v[:type] || :float),
        source_type: source_type,
        source_id: source_id,
        fetch_mode: fetch_mode,
        module_name: module_name,
        response_path: Atom.to_string(v.key),
        default_value: normalize_default(v),
        min_val: v[:min] && v[:min] / 1,
        max_val: v[:max] && v[:max] / 1,
        step: v[:step] && v[:step] / 1,
        solver_position: idx + 1,
        display_order: (idx + 1) * 10,
        active: true,
        delta_threshold: v[:delta_threshold],
        perturbation_stddev: get_in(v, [:perturbation, :stddev]),
        perturbation_min: get_in(v, [:perturbation, :min]) && get_in(v, [:perturbation, :min]) / 1,
        perturbation_max: get_in(v, [:perturbation, :max]) && get_in(v, [:perturbation, :max]) / 1,
        perturbation_flip_prob: get_in(v, [:perturbation, :flip_prob])
      }

      %VariableDefinition{}
      |> VariableDefinition.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:product_group, :key]
      )
    end)
  end

  # ── Routes ────────────────────────────────────────────────────────

  defp seed_routes(frame, pg) do
    routes = frame[:routes] || []

    Enum.each(Enum.with_index(routes), fn {r, idx} ->
      {distance, distance_unit} = extract_distance(r)

      attrs = %{
        product_group: pg,
        key: Atom.to_string(r.key),
        name: r.name,
        origin: r.origin,
        destination: r.destination,
        distance: distance,
        distance_unit: distance_unit,
        transport_mode: Atom.to_string(r[:transport_mode] || frame.transport_mode),
        freight_variable: safe_to_string(r[:freight_variable]),
        buy_variable: safe_to_string(r[:buy_variable]),
        sell_variable: safe_to_string(r[:sell_variable]),
        typical_transit_days: r[:typical_transit_days] && r[:typical_transit_days] / 1,
        transit_cost_per_day: r[:transit_cost_per_day] && r[:transit_cost_per_day] / 1,
        unit_capacity: r[:unit_capacity] && r[:unit_capacity] / 1,
        display_order: (idx + 1) * 10,
        active: true
      }

      %RouteDefinition{}
      |> RouteDefinition.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:product_group, :key]
      )
    end)
  end

  # ── Constraints ───────────────────────────────────────────────────

  defp seed_constraints(frame, pg) do
    constraints = frame[:constraints] || []

    Enum.each(Enum.with_index(constraints), fn {c, idx} ->
      attrs = %{
        product_group: pg,
        key: Atom.to_string(c.key),
        name: c.name,
        constraint_type: Atom.to_string(c.type),
        terminal: c[:terminal],
        destination: c[:destination],
        bound_variable: Atom.to_string(c.bound_variable),
        bound_min_variable: safe_to_string(c[:bound_min_variable]),
        outage_variable: safe_to_string(c[:outage_variable]),
        outage_factor: c[:outage_factor],
        routes: Enum.map(c[:routes] || [], &Atom.to_string/1),
        display_order: (idx + 1) * 10,
        active: true
      }

      %ConstraintDefinition{}
      |> ConstraintDefinition.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace_all_except, [:id, :inserted_at]},
        conflict_target: [:product_group, :key]
      )
    end)
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp patterns_to_strings(patterns) do
    Enum.map(patterns, fn
      %Regex{source: source} -> source
      s when is_binary(s) -> s
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp stringify_term_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, Atom.to_string(v)} end)
  end

  defp stringify_anchor_map(map) when is_map(map) do
    Map.new(map, fn
      {k, nil} -> {k, nil}
      {k, v} when is_atom(v) -> {k, Atom.to_string(v)}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_poll_intervals(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp resolve_source(api_sources, source_atom, _var_key) when is_map(api_sources) and is_atom(source_atom) do
    case Map.get(api_sources, source_atom) do
      %{module: nil} -> {"api", "manual", nil}
      %{module: mod} when not is_nil(mod) ->
        {"api", "module", inspect(mod)}
      _ ->
        case source_atom do
          :manual -> {"manual", "manual", nil}
          :contract -> {"manual", "manual", nil}
          :sap_fi -> {"api", "manual", nil}
          _ -> {"api", "manual", nil}
        end
    end
  end
  defp resolve_source(_, _, _), do: {"manual", "manual", nil}

  defp normalize_default(%{type: :boolean, default: true}), do: 1.0
  defp normalize_default(%{type: :boolean, default: false}), do: 0.0
  defp normalize_default(%{default: d}) when is_number(d), do: d / 1
  defp normalize_default(_), do: 0.0

  defp extract_distance(route) do
    cond do
      Map.has_key?(route, :distance_nm) -> {route.distance_nm / 1, "nm"}
      Map.has_key?(route, :distance_mi) -> {route.distance_mi / 1, "mi"}
      Map.has_key?(route, :distance_km) -> {route.distance_km / 1, "km"}
      true -> {nil, "mi"}
    end
  end

  defp safe_to_string(nil), do: nil
  defp safe_to_string(a) when is_atom(a), do: Atom.to_string(a)
  defp safe_to_string(s) when is_binary(s), do: s
end
