defmodule TradingDeskWeb.MobileApiController do
  @moduledoc """
  JSON API for the native mobile app.

  All endpoints require a Bearer token in the Authorization header.
  Tokens are per-trader and issued via the admin UI or seeded for dev.

  ## Endpoints

    GET  /api/v1/mobile/model          — current model: variables + metadata + descriptor
    GET  /api/v1/mobile/model/descriptor — raw binary model descriptor (base64)
    POST /api/v1/mobile/solves         — save a solve result from the mobile device
    GET  /api/v1/mobile/thresholds     — current delta thresholds for the trader's product groups
  """

  use Phoenix.Controller, formats: [:json]
  require Logger

  alias TradingDesk.{Variables, VariablesDynamic}
  alias TradingDesk.Config.DeltaConfig
  alias TradingDesk.Solver.ModelDescriptor
  alias TradingDesk.ProductGroup

  # ── Model ───────────────────────────────────────────────────────────────────

  @doc """
  Returns the full model payload the mobile app needs to run a solve:

    - `variables`  — current values (keyed by variable name)
    - `metadata`   — labels, units, min/max/step, group, source for each variable
    - `descriptor` — base64-encoded binary model descriptor (passed straight to Zig)
    - `product_group`
    - `timestamp`
  """
  def get_model(conn, params) do
    product_group = parse_product_group(params["product_group"])
    obj_mode = parse_objective(params["objective"])
    lambda = parse_float(params["lambda"], 0.0)
    profit_floor = parse_float(params["profit_floor"], 0.0)

    variables = current_variables(product_group)
    metadata = VariablesDynamic.metadata(product_group)
    descriptor_bin = ModelDescriptor.encode(product_group, [
      objective: obj_mode,
      lambda: lambda,
      profit_floor: profit_floor
    ])

    routes = ProductGroup.routes(product_group)
    constraints = ProductGroup.constraints(product_group)

    route_labels =
      routes
      |> Enum.with_index()
      |> Enum.map(fn {r, i} ->
        %{
          index: i,
          key: r[:key],
          label: r[:label] || to_string(r[:key]),
          origin: r[:origin],
          destination: r[:destination],
          unit_capacity: r[:unit_capacity] || 1500.0,
          typical_transit_days: r[:typical_transit_days] || 0.0
        }
      end)

    constraint_labels =
      constraints
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        %{
          index: i,
          type: c.type,
          label: c[:label] || to_string(c.type),
          bound_variable: c[:bound_variable]
        }
      end)

    json(conn, %{
      product_group: product_group,
      timestamp: DateTime.utc_now(),
      variables: variables,
      metadata: serialize_metadata(metadata),
      descriptor: Base.encode64(descriptor_bin),
      descriptor_byte_length: byte_size(descriptor_bin),
      variable_count: map_size(variables),
      routes: route_labels,
      constraints: constraint_labels,
      objective: obj_mode,
      lambda: lambda,
      profit_floor: profit_floor
    })
  end

  @doc """
  Returns just the binary model descriptor as base64.
  Lighter call when the app already has metadata and only needs a fresh descriptor
  (e.g., after the trader changes the objective mode).
  """
  def get_descriptor(conn, params) do
    product_group = parse_product_group(params["product_group"])
    obj_mode = parse_objective(params["objective"])
    lambda = parse_float(params["lambda"], 0.0)
    profit_floor = parse_float(params["profit_floor"], 0.0)

    descriptor_bin = ModelDescriptor.encode(product_group, [
      objective: obj_mode,
      lambda: lambda,
      profit_floor: profit_floor
    ])

    json(conn, %{
      product_group: product_group,
      descriptor: Base.encode64(descriptor_bin),
      byte_length: byte_size(descriptor_bin),
      objective: obj_mode,
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  Returns the current delta thresholds for the requested product group.
  The mobile app uses these to decide whether to show a threshold-breach alert.
  """
  def get_thresholds(conn, params) do
    product_group = parse_product_group(params["product_group"])
    config = DeltaConfig.get(product_group)

    json(conn, %{
      product_group: product_group,
      thresholds: config[:thresholds] || %{},
      enabled: config[:enabled] || false,
      timestamp: DateTime.utc_now()
    })
  end

  @doc """
  Save a solve result that was computed on the mobile device.

  The mobile app:
    1. Fetches the model from GET /model
    2. Runs the Zig solver locally
    3. If the trader wants to save, POSTs here

  The server writes the result to the audit store and marks it as
  originating from the mobile app (trigger: :mobile).

  Body (JSON):
    {
      "product_group": "ammonia_domestic",
      "variables": { ... current variable values used ... },
      "result": {
        "status": "optimal",
        "profit": 123456.78,
        "tons": 4500.0,
        "cost": 1234567.0,
        "roi": 10.5,
        "route_tons": [1500, 3000],
        "route_profits": [45000, 78456],
        "margins": [30.0, 26.15],
        "shadow_prices": [0.0, 5.2]
      },
      "mode": "solve",
      "trader_id": "trader@example.com",
      "solved_at": "2026-02-22T10:00:00Z",
      "device_id": "abc123"
    }
  """
  def save_solve(conn, params) do
    trader_id = conn.assigns[:mobile_trader_id]
    product_group = parse_product_group(params["product_group"])
    mode = parse_mode(params["mode"])
    variables = params["variables"] || %{}
    result_params = params["result"] || %{}
    solved_at = parse_datetime(params["solved_at"])
    device_id = params["device_id"]

    Logger.info("MobileAPI: save_solve from #{trader_id} on #{product_group}, device=#{device_id}")

    # Persist via the trade DB writer (same path as server-side solves)
    audit_id = generate_audit_id()

    mobile_result = %{
      status: parse_solve_status(result_params["status"]),
      profit: result_params["profit"] || 0.0,
      tons: result_params["tons"] || 0.0,
      cost: result_params["cost"] || 0.0,
      roi: result_params["roi"] || 0.0,
      route_tons: result_params["route_tons"] || [],
      route_profits: result_params["route_profits"] || [],
      margins: result_params["margins"] || [],
      shadow_prices: result_params["shadow_prices"] || []
    }

    Task.Supervisor.start_child(
      TradingDesk.Contracts.TaskSupervisor,
      fn ->
        TradingDesk.TradeDB.Writer.persist_mobile_solve(%{
          id: audit_id,
          trader_id: trader_id,
          product_group: product_group,
          mode: mode,
          trigger: :mobile,
          device_id: device_id,
          variables: atomize_keys(variables),
          result: mobile_result,
          started_at: solved_at || DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })
      end
    )

    json(conn, %{
      ok: true,
      audit_id: audit_id,
      message: "solve saved"
    })
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp current_variables(product_group) do
    try do
      case TradingDesk.Data.LiveState.get_variables(product_group) do
        {:ok, vars} -> vars
        _ -> ProductGroup.default_values(product_group)
      end
    rescue
      _ -> ProductGroup.default_values(product_group)
    end
  end

  defp serialize_metadata(metadata) do
    Enum.map(metadata, fn m ->
      m
      |> Map.take([:key, :label, :unit, :min, :max, :step, :source, :group, :type])
      |> Map.update!(:key, &to_string/1)
      |> Map.update!(:source, &to_string/1)
      |> Map.update!(:group, &to_string/1)
      |> then(fn m ->
        if Map.has_key?(m, :type),
          do: Map.update!(m, :type, &to_string/1),
          else: Map.put(m, :type, "continuous")
      end)
    end)
  end

  defp parse_product_group(nil), do: :ammonia_domestic
  defp parse_product_group(pg) when is_binary(pg) do
    case pg do
      "ammonia_domestic"        -> :ammonia_domestic
      "ammonia_international"   -> :ammonia_international
      "uan"                     -> :uan
      "urea"                    -> :urea
      "sulphur_international"   -> :sulphur_international
      "petcoke"                 -> :petcoke
      _                         -> :ammonia_domestic
    end
  end

  defp parse_objective(nil), do: :max_profit
  defp parse_objective("max_profit"), do: :max_profit
  defp parse_objective("min_cost"), do: :min_cost
  defp parse_objective("max_roi"), do: :max_roi
  defp parse_objective("cvar_adjusted"), do: :cvar_adjusted
  defp parse_objective("min_risk"), do: :min_risk
  defp parse_objective(_), do: :max_profit

  defp parse_mode(nil), do: :solve
  defp parse_mode("solve"), do: :solve
  defp parse_mode("monte_carlo"), do: :monte_carlo
  defp parse_mode(_), do: :solve

  defp parse_float(nil, default), do: default
  defp parse_float(val, _default) when is_float(val), do: val
  defp parse_float(val, _default) when is_integer(val), do: val / 1.0
  defp parse_float(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end
  defp parse_float(_, default), do: default

  defp parse_solve_status("optimal"), do: :optimal
  defp parse_solve_status("infeasible"), do: :infeasible
  defp parse_solve_status(_), do: :error

  defp parse_datetime(nil), do: nil
  defp parse_datetime(dt) when is_binary(dt) do
    case DateTime.from_iso8601(dt) do
      {:ok, d, _} -> d
      _ -> nil
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_binary(k), do: String.to_existing_atom(k), else: k
      {key, v}
    end)
  rescue
    _ -> map
  end

  defp generate_audit_id do
    :crypto.strong_rand_bytes(6) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
