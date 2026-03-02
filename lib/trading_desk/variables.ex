defmodule TradingDesk.Variables do
  @moduledoc """
  The core solver variables.

  Variable definitions (names, labels, units, sources, defaults) are stored in
  the `variable_definitions` database table and managed via the Variable Manager
  UI at `/variables`.  This module reads from that table at runtime.

  The struct is retained for backward compatibility with existing code that
  pattern-matches on `%Variables{}`, but `metadata/0` and `to_binary/1` are
  driven by the DB.
  """

  alias TradingDesk.Variables.VariableStore

  @enforce_keys [
    :river_stage, :lock_hrs, :temp_f, :wind_mph, :vis_mi, :precip_in,
    :inv_mer, :inv_nio, :mer_outage, :nio_outage, :barge_count,
    :nola_buy, :sell_stl, :sell_mem,
    :fr_mer_stl, :fr_mer_mem, :fr_nio_stl, :fr_nio_mem,
    :nat_gas, :working_cap
  ]

  defstruct [
    river_stage: 18.0,
    lock_hrs: 12.0,
    temp_f: 45.0,
    wind_mph: 12.0,
    vis_mi: 5.0,
    precip_in: 1.0,
    inv_mer: 12_000.0,
    inv_nio: 8_000.0,
    mer_outage: false,
    nio_outage: false,
    barge_count: 14.0,
    committed_lift_mer: 0.0,
    nola_buy: 320.0,
    sell_stl: 410.0,
    sell_mem: 385.0,
    fr_mer_stl: 55.0,
    fr_mer_mem: 32.0,
    fr_nio_stl: 58.0,
    fr_nio_mem: 34.0,
    nat_gas: 2.80,
    working_cap: 0.0
  ]

  @type t :: %__MODULE__{}

  @doc """
  Variable metadata — reads from the `variable_definitions` table.

  Falls back to a hardcoded list if the DB is unavailable (e.g. during
  compilation or before migrations have run).
  """
  def metadata do
    VariableStore.metadata("global")
  rescue
    # DB not available yet (before Repo starts, or migrations not run)
    _ -> metadata_fallback()
  end

  @doc """
  Pack into binary for Zig port.

  Builds the binary dynamically from the `solver_position` column in the
  `variable_definitions` table.  Each variable with a solver_position is
  packed as a float-little-64 in position order.
  """
  def to_binary(%__MODULE__{} = v) do
    to_binary_from_map(Map.from_struct(v))
  end

  @doc """
  Pack a plain map of variable values into the solver binary.

  Uses `variable_definitions.solver_position` to determine the order.
  Keys can be atoms or strings.
  """
  def to_binary_from_map(vars) when is_map(vars) do
    solver_keys = VariableStore.solver_keys("global")

    solver_keys
    |> Enum.map(fn {key_str, type} ->
      atom_key = String.to_atom(key_str)
      val = Map.get(vars, atom_key) || Map.get(vars, key_str, 0.0)
      encode_f64(val, type)
    end)
    |> IO.iodata_to_binary()
  rescue
    # DB not available — fall back to hardcoded struct order
    _ -> to_binary_fallback(vars)
  end

  # ──────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────

  defp encode_f64(true, _type), do: <<1.0::float-little-64>>
  defp encode_f64(false, _type), do: <<0.0::float-little-64>>
  defp encode_f64(val, "boolean") when is_number(val), do: <<(if val != 0, do: 1.0, else: 0.0)::float-little-64>>
  defp encode_f64(val, _type) when is_number(val), do: <<(val / 1.0)::float-little-64>>
  defp encode_f64(_, _type), do: <<0.0::float-little-64>>

  # Hardcoded fallback used only when DB is unavailable
  defp to_binary_fallback(v) when is_map(v) do
    get = fn key, default -> Map.get(v, key) || Map.get(v, Atom.to_string(key), default) end
    bool = fn key -> if get.(key, false), do: 1.0, else: 0.0 end

    <<
      (get.(:river_stage, 18.0) / 1.0)::float-little-64,
      (get.(:lock_hrs, 12.0) / 1.0)::float-little-64,
      (get.(:temp_f, 45.0) / 1.0)::float-little-64,
      (get.(:wind_mph, 12.0) / 1.0)::float-little-64,
      (get.(:vis_mi, 5.0) / 1.0)::float-little-64,
      (get.(:precip_in, 1.0) / 1.0)::float-little-64,
      (get.(:inv_mer, 12_000.0) / 1.0)::float-little-64,
      (get.(:inv_nio, 8_000.0) / 1.0)::float-little-64,
      bool.(:mer_outage)::float-little-64,
      bool.(:nio_outage)::float-little-64,
      (get.(:barge_count, 14.0) / 1.0)::float-little-64,
      (get.(:nola_buy, 320.0) / 1.0)::float-little-64,
      (get.(:sell_stl, 410.0) / 1.0)::float-little-64,
      (get.(:sell_mem, 385.0) / 1.0)::float-little-64,
      (get.(:fr_mer_stl, 55.0) / 1.0)::float-little-64,
      (get.(:fr_mer_mem, 32.0) / 1.0)::float-little-64,
      (get.(:fr_nio_stl, 58.0) / 1.0)::float-little-64,
      (get.(:fr_nio_mem, 34.0) / 1.0)::float-little-64,
      (get.(:nat_gas, 2.80) / 1.0)::float-little-64,
      (get.(:working_cap, 0.0) / 1.0)::float-little-64
    >>
  end

  # Hardcoded metadata fallback — only used when DB is unavailable
  defp metadata_fallback do
    [
      %{key: :river_stage, label: "River Stage", unit: "ft", min: 2, max: 55, step: 0.1, source: :usgs, group: :environment},
      %{key: :lock_hrs, label: "Lock Delays", unit: "hrs", min: 0, max: 96, step: 1, source: :usace, group: :environment},
      %{key: :temp_f, label: "Temperature", unit: "°F", min: -20, max: 115, step: 1, source: :noaa, group: :environment},
      %{key: :wind_mph, label: "Wind Speed", unit: "mph", min: 0, max: 55, step: 1, source: :noaa, group: :environment},
      %{key: :vis_mi, label: "Visibility", unit: "mi", min: 0.05, max: 15, step: 0.1, source: :noaa, group: :environment},
      %{key: :precip_in, label: "Precip (3-day)", unit: "in", min: 0, max: 8, step: 0.1, source: :noaa, group: :environment},
      %{key: :inv_mer, label: "Meredosia Inv", unit: "tons", min: 0, max: 15000, step: 100, source: :insight, group: :operations},
      %{key: :inv_nio, label: "Niota Inv", unit: "tons", min: 0, max: 10000, step: 100, source: :insight, group: :operations},
      %{key: :mer_outage, label: "Meredosia Outage", unit: "", min: 0, max: 1, step: 1, source: :manual, group: :operations, type: :boolean},
      %{key: :nio_outage, label: "Niota Outage", unit: "", min: 0, max: 1, step: 1, source: :manual, group: :operations, type: :boolean},
      %{key: :barge_count, label: "Barges Available", unit: "", min: 1, max: 30, step: 1, source: :internal, group: :operations},
      %{key: :nola_buy, label: "NH3 NOLA Buy", unit: "$/t", min: 200, max: 600, step: 5, source: :market, group: :commercial},
      %{key: :sell_stl, label: "NH3 StL Delivered", unit: "$/t", min: 300, max: 600, step: 5, source: :market, group: :commercial},
      %{key: :sell_mem, label: "NH3 Memphis Delivered", unit: "$/t", min: 280, max: 550, step: 5, source: :market, group: :commercial},
      %{key: :fr_mer_stl, label: "Freight Mer→StL", unit: "$/t", min: 20, max: 130, step: 1, source: :broker, group: :commercial},
      %{key: :fr_mer_mem, label: "Freight Mer→Mem", unit: "$/t", min: 10, max: 80, step: 1, source: :broker, group: :commercial},
      %{key: :fr_nio_stl, label: "Freight Nio→StL", unit: "$/t", min: 20, max: 135, step: 1, source: :broker, group: :commercial},
      %{key: :fr_nio_mem, label: "Freight Nio→Mem", unit: "$/t", min: 10, max: 85, step: 1, source: :broker, group: :commercial},
      %{key: :nat_gas, label: "Nat Gas (Henry Hub)", unit: "$/MMBtu", min: 1.0, max: 8.0, step: 0.05, source: :eia, group: :commercial},
      %{key: :working_cap, label: "Working Capital", unit: "$", min: 500_000, max: 10_000_000, step: 100_000, source: :sap_fi, group: :commercial}
    ]
  end
end
