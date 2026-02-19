defmodule TradingDesk.Data.AIS.AISStreamConnector do
  @moduledoc """
  Persistent WebSocket client for aisstream.io — the best free real-time AIS feed.

  Connects to wss://stream.aisstream.io/v0/stream with a bounding box covering
  the Lower Mississippi River corridor. Incoming position reports are cached in ETS
  and read by TradingDesk.Data.API.VesselTracking.fetch/0.

  ## Setup

  1. Register at https://aisstream.io (free, instant key)
  2. Set env: AISSTREAM_API_KEY=your_key_here
  3. The connector starts automatically and reconnects if disconnected.

  ## ETS cache

  Vessel positions are stored in the `:ais_vessel_cache` ETS table, keyed by MMSI.
  Each entry is `{mmsi, vessel_map}` where vessel_map matches the shape returned
  by VesselTracking.

  ## Notes on bounding box

  AISstream uses TopLeft (NW corner) + BottomRight (SE corner):
    - TopLeft:     37.2°N, 91.5°W  (Cairo, IL)
    - BottomRight: 29.0°N, 88.5°W  (Gulf approaches)

  To track ocean vessels (ammonia carriers, sulphur bulk), add a second bounding box
  by setting AISSTREAM_EXTRA_BBOX="lat_tl,lon_tl,lat_br,lon_br" in env.
  """

  use WebSockex
  require Logger

  @url "wss://stream.aisstream.io/v0/stream"
  @ets_table :ais_vessel_cache

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
    api_key = System.get_env("AISSTREAM_API_KEY")

    if api_key in [nil, ""] do
      :ignore
    else
      ensure_ets_table()
      Logger.info("AISStreamConnector: connecting to #{@url}")

      extra_bbox = parse_extra_bbox()
      bboxes = [@bbox_mississippi | extra_bbox]

      state = %{api_key: api_key, bboxes: bboxes, connected: false}

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

  # ──────────────────────────────────────────────
  # WebSockex callbacks
  # ──────────────────────────────────────────────

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("AISStreamConnector: connected, subscribing to #{length(state.bboxes)} bounding box(es)")

    sub =
      Jason.encode!(%{
        "ApiKey"       => state.api_key,
        "BoundingBoxes" => state.bboxes,
        "FilterMessageTypes" => ["PositionReport", "StandardClassBPositionReport",
                                 "ExtendedClassBPositionReport"]
      })

    {:reply, {:text, sub}, %{state | connected: true}}
  end

  @impl true
  def handle_frame({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, msg} -> handle_ais_message(msg)
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
  def handle_cast(:ping, state) do
    {:reply, :ping, state}
  end

  # ──────────────────────────────────────────────
  # Message parsing
  # ──────────────────────────────────────────────

  defp handle_ais_message(%{"MessageType" => type, "MetaData" => meta, "Message" => msg})
       when type in ["PositionReport", "StandardClassBPositionReport",
                     "ExtendedClassBPositionReport"] do
    mmsi = to_string(meta["MMSI"] || "")
    name = String.trim(meta["ShipName"] || "Unknown")

    position =
      case type do
        "PositionReport" ->
          pr = msg["PositionReport"] || %{}
          %{
            cog:     pr["Cog"],
            sog:     pr["Sog"],
            heading: pr["TrueHeading"],
            status:  pr["NavigationalStatus"]
          }

        _ ->
          cb = msg["StandardClassBPositionReport"] || msg["ExtendedClassBPositionReport"] || %{}
          %{
            cog:     cb["Cog"],
            sog:     cb["Sog"],
            heading: cb["TrueHeading"],
            status:  nil
          }
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

  defp handle_ais_message(_), do: :ok

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

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
