defmodule TradingDesk.Seeds.VariableDefinitionsSeed do
  @moduledoc """
  Seeds the 20 core solver variables into the variable_definitions table.

  All 20 live under product_group = "global" so they are shared across every
  product group.  The `solver_position` (1-20) encodes the position each
  variable occupies in the Zig solver binary blob (matches `variables.ex`
  `to_binary/1` field order).

  Safe to re-run — uses upsert on (product_group, key).
  """

  alias TradingDesk.Variables.VariableStore

  @variables [
    # ── ENVIRONMENT (solver positions 1-6) ───────────────────────────────────
    %{
      product_group: "global", key: "river_stage",
      label: "River Stage",        unit: "ft",      group_name: "environment",
      type: "float",               source_type: "api", source_id: "usgs",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.USGS",
      response_path: "river_stage",
      default_value: 18.0,  min_val: 2.0,  max_val: 55.0,  step: 0.1,
      solver_position: 1,   display_order: 10
    },
    %{
      product_group: "global", key: "lock_hrs",
      label: "Lock Delays",        unit: "hrs",     group_name: "environment",
      type: "float",               source_type: "api", source_id: "usace",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.USACE",
      response_path: "lock_hrs",
      default_value: 12.0,  min_val: 0.0,  max_val: 96.0,  step: 1.0,
      solver_position: 2,   display_order: 20
    },
    %{
      product_group: "global", key: "temp_f",
      label: "Temperature",        unit: "°F",      group_name: "environment",
      type: "float",               source_type: "api", source_id: "noaa",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.NOAA",
      response_path: "temp_f",
      default_value: 45.0,  min_val: -20.0, max_val: 115.0, step: 1.0,
      solver_position: 3,   display_order: 30
    },
    %{
      product_group: "global", key: "wind_mph",
      label: "Wind Speed",         unit: "mph",     group_name: "environment",
      type: "float",               source_type: "api", source_id: "noaa",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.NOAA",
      response_path: "wind_mph",
      default_value: 12.0,  min_val: 0.0,  max_val: 55.0,  step: 1.0,
      solver_position: 4,   display_order: 40
    },
    %{
      product_group: "global", key: "vis_mi",
      label: "Visibility",         unit: "mi",      group_name: "environment",
      type: "float",               source_type: "api", source_id: "noaa",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.NOAA",
      response_path: "vis_mi",
      default_value: 5.0,   min_val: 0.05, max_val: 15.0,  step: 0.1,
      solver_position: 5,   display_order: 50
    },
    %{
      product_group: "global", key: "precip_in",
      label: "Precip (3-day)",     unit: "in",      group_name: "environment",
      type: "float",               source_type: "api", source_id: "noaa",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.NOAA",
      response_path: "precip_in",
      default_value: 1.0,   min_val: 0.0,  max_val: 8.0,   step: 0.1,
      solver_position: 6,   display_order: 60
    },

    # ── OPERATIONS (solver positions 7-11) ───────────────────────────────────
    %{
      product_group: "global", key: "inv_mer",
      label: "Meredosia Inv",      unit: "tons",    group_name: "operations",
      type: "float",               source_type: "api", source_id: "insight",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Internal",
      response_path: "inv_mer",
      default_value: 12_000.0, min_val: 0.0, max_val: 15_000.0, step: 100.0,
      solver_position: 7,   display_order: 70
    },
    %{
      product_group: "global", key: "inv_nio",
      label: "Niota Inv",          unit: "tons",    group_name: "operations",
      type: "float",               source_type: "api", source_id: "insight",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Internal",
      response_path: "inv_nio",
      default_value: 8_000.0,  min_val: 0.0, max_val: 10_000.0, step: 100.0,
      solver_position: 8,   display_order: 80
    },
    %{
      product_group: "global", key: "mer_outage",
      label: "Meredosia Outage",   unit: "",        group_name: "operations",
      type: "boolean",             source_type: "api", source_id: "insight",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Internal",
      response_path: "mer_outage",
      default_value: 0.0,   min_val: 0.0,  max_val: 1.0,   step: 1.0,
      solver_position: 9,   display_order: 90
    },
    %{
      product_group: "global", key: "nio_outage",
      label: "Niota Outage",       unit: "",        group_name: "operations",
      type: "boolean",             source_type: "api", source_id: "insight",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Internal",
      response_path: "nio_outage",
      default_value: 0.0,   min_val: 0.0,  max_val: 1.0,   step: 1.0,
      solver_position: 10,  display_order: 100
    },
    %{
      product_group: "global", key: "barge_count",
      label: "Barges Available",   unit: "",        group_name: "operations",
      type: "float",               source_type: "api", source_id: "tms",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Internal",
      response_path: "barge_count",
      default_value: 14.0,  min_val: 1.0,  max_val: 30.0,  step: 1.0,
      solver_position: 11,  display_order: 110
    },

    # ── COMMERCIAL (solver positions 12-20) ──────────────────────────────────
    %{
      product_group: "global", key: "nola_buy",
      label: "NH3 NOLA Buy",       unit: "$/t",     group_name: "commercial",
      type: "float",               source_type: "api", source_id: "delivered_prices",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Market",
      response_path: "nola_buy",
      default_value: 320.0, min_val: 200.0, max_val: 600.0, step: 5.0,
      solver_position: 12,  display_order: 120
    },
    %{
      product_group: "global", key: "sell_stl",
      label: "NH3 StL Delivered",  unit: "$/t",     group_name: "commercial",
      type: "float",               source_type: "api", source_id: "delivered_prices",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Market",
      response_path: "sell_stl",
      default_value: 410.0, min_val: 300.0, max_val: 600.0, step: 5.0,
      solver_position: 13,  display_order: 130
    },
    %{
      product_group: "global", key: "sell_mem",
      label: "NH3 Memphis Delivered", unit: "$/t",  group_name: "commercial",
      type: "float",               source_type: "api", source_id: "delivered_prices",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Market",
      response_path: "sell_mem",
      default_value: 385.0, min_val: 280.0, max_val: 550.0, step: 5.0,
      solver_position: 14,  display_order: 140
    },
    %{
      product_group: "global", key: "fr_mer_stl",
      label: "Freight Mer→StL",    unit: "$/t",     group_name: "commercial",
      type: "float",               source_type: "api", source_id: "broker",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Broker",
      response_path: "fr_mer_stl",
      default_value: 55.0,  min_val: 20.0,  max_val: 130.0, step: 1.0,
      solver_position: 15,  display_order: 150
    },
    %{
      product_group: "global", key: "fr_mer_mem",
      label: "Freight Mer→Mem",    unit: "$/t",     group_name: "commercial",
      type: "float",               source_type: "api", source_id: "broker",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Broker",
      response_path: "fr_mer_mem",
      default_value: 32.0,  min_val: 10.0,  max_val: 80.0,  step: 1.0,
      solver_position: 16,  display_order: 160
    },
    %{
      product_group: "global", key: "fr_nio_stl",
      label: "Freight Nio→StL",    unit: "$/t",     group_name: "commercial",
      type: "float",               source_type: "api", source_id: "broker",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Broker",
      response_path: "fr_nio_stl",
      default_value: 58.0,  min_val: 20.0,  max_val: 135.0, step: 1.0,
      solver_position: 17,  display_order: 170
    },
    %{
      product_group: "global", key: "fr_nio_mem",
      label: "Freight Nio→Mem",    unit: "$/t",     group_name: "commercial",
      type: "float",               source_type: "api", source_id: "broker",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Broker",
      response_path: "fr_nio_mem",
      default_value: 34.0,  min_val: 10.0,  max_val: 85.0,  step: 1.0,
      solver_position: 18,  display_order: 180
    },
    %{
      product_group: "global", key: "nat_gas",
      label: "Nat Gas (Henry Hub)", unit: "$/MMBtu", group_name: "commercial",
      type: "float",               source_type: "api", source_id: "eia",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.EIA",
      response_path: "nat_gas",
      default_value: 2.80,  min_val: 1.0,   max_val: 8.0,   step: 0.05,
      solver_position: 19,  display_order: 190
    },
    %{
      product_group: "global", key: "working_cap",
      label: "Working Capital",    unit: "$",       group_name: "commercial",
      type: "float",               source_type: "api", source_id: "sap",
      fetch_mode: "module",        module_name: "TradingDesk.Data.API.Internal",
      response_path: "working_cap",
      default_value: 0.0,   min_val: 500_000.0, max_val: 10_000_000.0, step: 100_000.0,
      solver_position: 20,  display_order: 200
    }
  ]

  def run do
    IO.puts("  → Seeding variable definitions (#{length(@variables)} core solver variables)...")

    results = Enum.map(@variables, fn attrs ->
      case VariableStore.upsert(attrs) do
        {:ok, _}    -> :ok
        {:error, cs} ->
          IO.puts("    ⚠ Failed to seed #{attrs.key}: #{inspect(cs.errors)}")
          :error
      end
    end)

    ok_count    = Enum.count(results, & &1 == :ok)
    error_count = Enum.count(results, & &1 == :error)

    IO.puts("  ✓ Variable definitions: #{ok_count} upserted, #{error_count} failed")
  end
end
