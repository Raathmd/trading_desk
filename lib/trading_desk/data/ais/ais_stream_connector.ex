defmodule TradingDesk.Data.AIS.AISStreamConnector do
  @moduledoc """
  Persistent WebSocket client for aisstream.io — the best free real-time AIS feed.

  Connects to wss://stream.aisstream.io/v0/stream. Tracked MMSIs are loaded from
  the `tracked_vessels` DB table (falls back to TRACKED_VESSELS env var).

  ## Setup

  1. Register at https://aisstream.io (free, instant key)
  2. Set env: AISSTREAM_API_KEY=your_key_here
  3. Add vessels via the Fleet tab or `TrackedVessel.create/1`
  4. The connector starts automatically and refreshes the tracked list every 5 min.

  ## ETS cache

  Vessel positions stored in `:ais_vessel_cache` ETS table, keyed by MMSI.
  """

  use WebSockex
  require Logger

  alias TradingDesk.Fleet.TrackedVessel

  @url "wss://stream.aisstream.io/v0/stream"
  @ets_table :ais_vessel_cache
  @refresh_interval :timer.minutes(5)

  # Mississippi River corridor
  @bbox_mississippi %{
    "TopLeftLatitude"      => 37.2,
    "TopLeftLongitude"     => -91.5,
    "BottomRightLatitude"  => 29.0,
    "BottomRightLongitude" => -88.5
  }

  # ──────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────

  @doc "Start the connector. Returns {:ignore} if AISSTREAM_API_KEY is not set."
  def start_link(_opts \\ []) do
    api_key = TradingDesk.ApiConfig.get_credential("aisstream", "AISSTREAM_API_KEY")

    if api_key in [nil, ""] do
      :ignore
    else
      ensure_ets_table()

      extra_bbox = parse_extra_bbox()
      bboxes = [@bbox_mississippi | extra_bbox]
      tracked = load_tracked_mmsis()

      Logger.info(
        "AISStreamConnector: connecting — #{length(bboxes)} bbox(es), " <>
          if(tracked == [], do: "all vessels", else: "#{length(tracked)} tracked MMSI(s)")
      )

      state = %{api_key: api_key, bboxes: bboxes, tracked: tracked, connected: false}

      WebSockex.start_link(@url, __MODULE__, state, name: __MODULE__)
    end
  end

  @doc """
  Return current cached vessel positions as a list.
  Returns [] if no data yet or the connector is not running.
  """
  @spec get_vessels() :: [map()]
  def get_vessels do
    if :ets.whereis(@ets_table) == :undefined do
      []
    else
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {_mmsi, vessel} -> vessel end)
    end
  rescue
    _ -> []
  end

  @doc "True if the ETS cache has at least one vessel position."
  def has_data?, do: get_vessels() != []

  @doc "Force a refresh of the tracked vessel list from DB."
  def refresh_tracked do
    if Process.whereis(__MODULE__) do
      WebSockex.cast(__MODULE__, :refresh_tracked)
    end
  end

  # ──────────────────────────────────────────────
  # WebSockex callbacks
  # ──────────────────────────────────────────────

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("AISStreamConnector: connected, sending subscription")

    # Schedule periodic refresh of tracked vessel list from DB
    Process.send_after(self(), :refresh_tracked_tick, @refresh_interval)

    send_subscription(state)
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, msg} -> handle_ais_message(msg, state.tracked)
      {:error, _} -> :ok
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("AISStreamConnector: disconnected (#{inspect(reason)}), reconnecting in 5s")
    Process.sleep(5_000)
    {:reconnect, %{state | connected: false}}
  end

  @impl true
  def handle_cast(:refresh_tracked, state) do
    new_tracked = load_tracked_mmsis()

    if MapSet.new(new_tracked) != MapSet.new(state.tracked) do
      Logger.info(
        "AISStreamConnector: tracked list changed (#{length(state.tracked)} → #{length(new_tracked)}), re-subscribing"
      )
      state = %{state | tracked: new_tracked}
      send_subscription(state)
    else
      {:ok, state}
    end
  end

  def handle_cast(:ping, state), do: {:reply, :ping, state}

  @impl true
  def handle_info(:refresh_tracked_tick, state) do
    new_tracked = load_tracked_mmsis()
    state = %{state | tracked: new_tracked}
    Process.send_after(self(), :refresh_tracked_tick, @refresh_interval)
    {:ok, state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  # ──────────────────────────────────────────────
  # Message parsing
  # ──────────────────────────────────────────────

  defp handle_ais_message(%{"MessageType" => type, "MetaData" => meta, "Message" => msg}, tracked)
       when type in ["PositionReport", "StandardClassBPositionReport",
                     "ExtendedClassBPositionReport"] do
    mmsi = to_string(meta["MMSI"] || "")

    if tracked == [] or mmsi in tracked do
      name = String.trim(meta["ShipName"] || "Unknown")

      position =
        case type do
          "PositionReport" ->
            pr = msg["PositionReport"] || %{}
            %{cog: pr["Cog"], sog: pr["Sog"], heading: pr["TrueHeading"], status: pr["NavigationalStatus"]}

          _ ->
            cb = msg["StandardClassBPositionReport"] || msg["ExtendedClassBPositionReport"] || %{}
            %{cog: cb["Cog"], sog: cb["Sog"], heading: cb["TrueHeading"], status: nil}
        end

      vessel = %{
        mmsi:      mmsi,
        name:      name,
        lat:       meta["latitude"],
        lon:       meta["longitude"],
        course:    position.cog,
        speed:     position.sog,
        heading:   position.heading,
        status:    nav_status(position.status),
        timestamp: meta["time_utc"],
        source:    :aisstream
      }

      if vessel.lat != nil and vessel.lon != nil do
        ensure_ets_table()
        :ets.insert(@ets_table, {mmsi, vessel})
      end
    end
  end

  defp handle_ais_message(_, _tracked), do: :ok

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp send_subscription(state) do
    sub_base = %{
      "ApiKey"             => state.api_key,
      "BoundingBoxes"      => state.bboxes,
      "FilterMessageTypes" => ["PositionReport", "StandardClassBPositionReport",
                               "ExtendedClassBPositionReport"]
    }

    sub =
      if state.tracked != [] do
        mmsis = Enum.map(state.tracked, fn m ->
          case Integer.parse(m) do
            {n, _} -> n
            :error -> m
          end
        end)
        Map.put(sub_base, "MMSIs", mmsis)
      else
        sub_base
      end

    {:reply, {:text, Jason.encode!(sub)}, %{state | connected: true}}
  end

  @doc false
  def load_tracked_mmsis do
    # Primary: DB table
    case TrackedVessel.active_mmsis() do
      mmsis when is_list(mmsis) and mmsis != [] ->
        mmsis

      _ ->
        # Fallback: env var (useful before first migration or for dev)
        case System.get_env("TRACKED_VESSELS") do
          nil -> []
          ""  -> []
          csv -> String.split(csv, ",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
        end
    end
  rescue
    # DB not yet migrated
    _ ->
      case System.get_env("TRACKED_VESSELS") do
        nil -> []
        ""  -> []
        csv -> String.split(csv, ",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end
  end

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:set, :public, :named_table])
    end
  rescue
    _ -> :ok
  end

  defp nav_status(0), do: :underway_engine
  defp nav_status(1), do: :at_anchor
  defp nav_status(5), do: :moored
  defp nav_status(8), do: :underway_sailing
  defp nav_status(_), do: :unknown

  defp parse_extra_bbox do
    case System.get_env("AISSTREAM_EXTRA_BBOX") do
      nil -> []
      "" -> []
      csv ->
        case String.split(csv, ",") |> Enum.map(&String.trim/1) |> Enum.map(&Float.parse/1) do
          [{lat_tl, _}, {lon_tl, _}, {lat_br, _}, {lon_br, _}] ->
            [%{
              "TopLeftLatitude"      => lat_tl,
              "TopLeftLongitude"     => lon_tl,
              "BottomRightLatitude"  => lat_br,
              "BottomRightLongitude" => lon_br
            }]
          _ ->
            Logger.warning("AISStreamConnector: invalid AISSTREAM_EXTRA_BBOX format, expected lat_tl,lon_tl,lat_br,lon_br")
            []
        end
    end
  end
end
