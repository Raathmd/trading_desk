defmodule TradingDesk.Variables do
  @moduledoc """
  The core solver variables.

  Variable definitions (names, labels, units, sources, defaults) are stored in
  the `variable_definitions` database table and managed via the Variable Manager
  UI at `/variables`.  API endpoint URLs and credentials live in the `api_configs`
  table.  This module reads from those tables at runtime — there are no hardcoded
  fallback lists.

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

  Returns a list of maps with `:key`, `:label`, `:unit`, `:min`, `:max`,
  `:step`, `:source`, `:group`, and `:type`.
  """
  def metadata do
    VariableStore.metadata("global")
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
  end

  # ──────────────────────────────────────────────────────────
  # Private helpers
  # ──────────────────────────────────────────────────────────

  defp encode_f64(true, _type), do: <<1.0::float-little-64>>
  defp encode_f64(false, _type), do: <<0.0::float-little-64>>
  defp encode_f64(val, "boolean") when is_number(val), do: <<(if val != 0, do: 1.0, else: 0.0)::float-little-64>>
  defp encode_f64(val, _type) when is_number(val), do: <<(val / 1.0)::float-little-64>>
  defp encode_f64(_, _type), do: <<0.0::float-little-64>>
end
