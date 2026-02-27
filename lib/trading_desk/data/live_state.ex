defmodule TradingDesk.Data.LiveState do
  @moduledoc """
  Holds the current live values for all solver variables plus supplementary
  data (vessel positions, tides, fleet weather).

  Updated by the Poller, read by LiveView and AutoRunner.

  ## Variable storage

  The 20 core solver variables are stored in `vars` as a `%TradingDesk.Variables{}`
  struct (backward-compatible with existing code).

  Variables added dynamically via the Variable Manager (beyond the core 20) are
  stored in `extra_vars` as a plain `%{String.t() => term()}` map.

  `update/2` routes incoming data to the right store automatically:
  known struct keys → `vars`, everything else → `extra_vars`.

  ## Supplementary Data

  In addition to solver variables, LiveState stores supplementary data that
  doesn't directly map to solver inputs but is displayed in the UI:

    - `:vessel_tracking` — vessel positions, fleet summary, vessel-proximate weather
    - `:tides`           — water levels, tidal predictions, currents from NOAA CO-OPS
  """
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # ──────────────────────────────────────────────────────────
  # Public API — struct vars (20 core solver variables)
  # ──────────────────────────────────────────────────────────

  @doc "Get current live values as a Variables struct (20 core solver vars)."
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Get the timestamp of last update per source."
  def last_updated do
    GenServer.call(__MODULE__, :last_updated)
  end

  @doc "Update variables from a data source."
  def update(source, data) do
    GenServer.cast(__MODULE__, {:update, source, data})
  end

  # ──────────────────────────────────────────────────────────
  # Public API — extra_vars (dynamic variables beyond the core 20)
  # ──────────────────────────────────────────────────────────

  @doc """
  Get the extra_vars map for all dynamic variables that are NOT part of the
  core 20-field `%Variables{}` struct.
  """
  def get_extra do
    GenServer.call(__MODULE__, :get_extra)
  end

  @doc """
  Get a single extra variable value by key (string).
  Returns nil if not set.
  """
  def get_extra(key) do
    GenServer.call(__MODULE__, {:get_extra, key})
  end

  @doc """
  Set extra_vars values directly (e.g. from manual trader input or file upload).
  `data` is a `%{String.t() => term()}` map.
  """
  def set_extra(data) when is_map(data) do
    GenServer.cast(__MODULE__, {:set_extra, data})
  end

  # ──────────────────────────────────────────────────────────
  # Public API — supplementary data
  # ──────────────────────────────────────────────────────────

  @doc "Get all supplementary data (vessel positions, tides, etc.)"
  def get_supplementary do
    GenServer.call(__MODULE__, :get_supplementary)
  end

  @doc "Get a specific supplementary data key."
  def get_supplementary(key) do
    GenServer.call(__MODULE__, {:get_supplementary, key})
  end

  @doc "Update supplementary data (non-variable data like vessel positions, tides)"
  def update_supplementary(key, data) do
    GenServer.cast(__MODULE__, {:update_supplementary, key, data})
  end

  # ──────────────────────────────────────────────────────────
  # GenServer — init
  # ──────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    state = %{
      vars: %TradingDesk.Variables{
        river_stage: 14.2, lock_hrs: 20.0, temp_f: 28.0, wind_mph: 18.0,
        vis_mi: 0.5, precip_in: 1.2,
        inv_mer: 12_000.0, inv_nio: 8_000.0,
        mer_outage: true, nio_outage: false, barge_count: 14.0,
        nola_buy: 320.0, sell_stl: 410.0, sell_mem: 385.0,
        fr_mer_stl: 55.0, fr_mer_mem: 32.0, fr_nio_stl: 58.0, fr_nio_mem: 34.0,
        nat_gas: 2.80, working_cap: 4_200_000.0
      },
      extra_vars:    %{},
      updated_at:    %{},
      supplementary: %{}
    }

    {:ok, state}
  end

  # ──────────────────────────────────────────────────────────
  # GenServer — handle_call
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_call(:get, _from, state),
    do: {:reply, state.vars, state}

  @impl true
  def handle_call(:last_updated, _from, state),
    do: {:reply, state.updated_at, state}

  @impl true
  def handle_call(:get_extra, _from, state),
    do: {:reply, state.extra_vars, state}

  @impl true
  def handle_call({:get_extra, key}, _from, state),
    do: {:reply, Map.get(state.extra_vars, key), state}

  @impl true
  def handle_call(:get_supplementary, _from, state),
    do: {:reply, state.supplementary, state}

  @impl true
  def handle_call({:get_supplementary, key}, _from, state),
    do: {:reply, Map.get(state.supplementary, key), state}

  # ──────────────────────────────────────────────────────────
  # GenServer — handle_cast
  # ──────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:update, source, data}, state) do
    {new_vars, new_extra} = merge_data(state.vars, state.extra_vars, data)
    new_updated = Map.put(state.updated_at, source, DateTime.utc_now())
    {:noreply, %{state | vars: new_vars, extra_vars: new_extra, updated_at: new_updated}}
  end

  @impl true
  def handle_cast({:set_extra, data}, state) do
    new_extra = Map.merge(state.extra_vars, data)
    {:noreply, %{state | extra_vars: new_extra}}
  end

  @impl true
  def handle_cast({:update_supplementary, key, data}, state) do
    new_supp    = Map.put(state.supplementary, key, data)
    new_updated = Map.put(state.updated_at, key, DateTime.utc_now())

    Phoenix.PubSub.broadcast(
      TradingDesk.PubSub,
      "live_data",
      {:supplementary_updated, key}
    )

    {:noreply, %{state | supplementary: new_supp, updated_at: new_updated}}
  end

  # ──────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────

  # Routes incoming {key, value} pairs:
  #   - string key that matches a struct field → update vars struct
  #   - atom key that matches a struct field   → update vars struct
  #   - anything else                          → put in extra_vars (string key)
  defp merge_data(vars, extra_vars, data) when is_map(data) do
    Enum.reduce(data, {vars, extra_vars}, fn {k, v}, {vs, ev} ->
      atom_key = to_atom_key(k)

      cond do
        is_nil(v) ->
          {vs, ev}

        # Known struct field (atom or matching string)
        atom_key != nil and Map.has_key?(vs, atom_key) ->
          {Map.put(vs, atom_key, v), ev}

        # Unknown key → goes into extra_vars (always stored as string)
        true ->
          {vs, Map.put(ev, to_string(k), v)}
      end
    end)
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> nil
    end
  end
  defp to_atom_key(_), do: nil
end
