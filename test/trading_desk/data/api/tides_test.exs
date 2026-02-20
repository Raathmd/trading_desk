defmodule TradingDesk.Data.API.TidesTest do
  @moduledoc """
  Unit tests for the NOAA CO-OPS tidal API integration.

  Tests cover:
    - Station configuration (IDs, roles, coordinates)
    - Nearest-station geometry
    - JSON response parsing for water level, tidal predictions, and currents
    - parse_float edge cases

  These tests are fully offline — they exercise the parsing and configuration
  logic using inline JSON fixtures that mirror real NOAA API responses.
  Live API calls (`fetch/0`, `fetch_water_level/1`, etc.) are integration tests
  that require network access and are not run in the standard suite.
  """
  use ExUnit.Case, async: true

  alias TradingDesk.Data.API.Tides

  # ──────────────────────────────────────────────────────────
  # STATION CONFIGURATION
  # ──────────────────────────────────────────────────────────

  describe "stations/0" do
    test "returns all 5 configured stations" do
      stations = Tides.stations()
      assert map_size(stations) == 5
    end

    test "all expected station keys are present" do
      stations = Tides.stations()
      assert Map.has_key?(stations, :pilottown)
      assert Map.has_key?(stations, :shell_beach)
      assert Map.has_key?(stations, :new_canal)
      assert Map.has_key?(stations, :port_fourchon)
      assert Map.has_key?(stations, :bonnet_carre)
    end

    test "each station has required fields" do
      Tides.stations() |> Enum.each(fn {_key, station} ->
        assert is_binary(station.id),   "station missing :id"
        assert is_binary(station.name), "station missing :name"
        assert is_float(station.lat),   "station missing :lat"
        assert is_float(station.lon),   "station missing :lon"
        assert is_atom(station.role),   "station missing :role"
      end)
    end

    test "Pilottown is the tidal boundary station with correct NOAA ID" do
      pt = Tides.stations()[:pilottown]
      assert pt.id   == "8760721"
      assert pt.role == :tidal_boundary
    end

    test "New Canal is the NOLA reference station" do
      nc = Tides.stations()[:new_canal]
      assert nc.id   == "8761927"
      assert nc.role == :nola_reference
    end

    test "Port Fourchon covers Gulf access" do
      pf = Tides.stations()[:port_fourchon]
      assert pf.id   == "8762075"
      assert pf.role == :gulf_access
    end
  end

  describe "current_stations/0" do
    test "contains the SW Pass currents station" do
      cs = Tides.current_stations()
      assert Map.has_key?(cs, :sw_pass)
    end

    test "SW Pass has correct NOAA PORTS station ID" do
      assert Tides.current_stations()[:sw_pass].id == "LMN0101"
    end
  end

  # ──────────────────────────────────────────────────────────
  # NEAREST STATION GEOMETRY
  # ──────────────────────────────────────────────────────────

  describe "nearest_station/2" do
    test "returns Pilottown for coordinates right at Head of Passes" do
      # Pilottown: 29.1783, -89.2583
      station = Tides.nearest_station(29.1783, -89.2583)
      assert station.id == "8760721"
    end

    test "returns New Canal for coordinates in central New Orleans" do
      # New Canal: 30.0272, -90.1133  — NOLA latitude, near lake
      station = Tides.nearest_station(29.95, -90.07)
      assert station.id == "8761927"
    end

    test "returns Port Fourchon for coordinates near the Gulf terminus" do
      # Port Fourchon: 29.1142, -90.1992
      station = Tides.nearest_station(29.11, -90.20)
      assert station.id == "8762075"
    end

    test "returns Bonnet Carre for coordinates upriver from NOLA" do
      # Bonnet Carre: 30.0669, -90.3839
      station = Tides.nearest_station(30.07, -90.38)
      assert station.id == "8762483"
    end

    test "nearest_station is deterministic for repeated calls" do
      lat = 29.87
      lon = -89.67
      assert Tides.nearest_station(lat, lon) == Tides.nearest_station(lat, lon)
    end
  end

  # ──────────────────────────────────────────────────────────
  # PARSE FLOAT
  # ──────────────────────────────────────────────────────────

  describe "parse_float/1" do
    test "returns nil for nil" do
      assert Tides.parse_float(nil) == nil
    end

    test "returns nil for empty string" do
      assert Tides.parse_float("") == nil
    end

    test "parses a valid decimal string" do
      assert Tides.parse_float("2.34") == 2.34
    end

    test "parses a negative string" do
      assert Tides.parse_float("-0.52") == -0.52
    end

    test "passes through integers as floats" do
      assert Tides.parse_float(3) == 3.0
    end

    test "passes through floats unchanged" do
      assert Tides.parse_float(1.5) == 1.5
    end

    test "returns nil for non-numeric strings" do
      assert Tides.parse_float("N/A") == nil
    end
  end

  # ──────────────────────────────────────────────────────────
  # WATER LEVEL RESPONSE PARSING
  # ──────────────────────────────────────────────────────────

  describe "parse_water_level_response/1" do
    @water_level_fixture Jason.encode!(%{
      "metadata" => %{"id" => "8760721", "name" => "Pilottown, LA"},
      "data" => [
        %{"t" => "2024-01-15 12:00", "v" => "2.34", "s" => "0.012",
          "f" => "0,0,0,0", "q" => "p"},
        %{"t" => "2024-01-15 11:54", "v" => "2.28", "s" => "0.010",
          "f" => "0,0,0,0", "q" => "p"}
      ]
    })

    test "extracts the latest (first) reading" do
      assert {:ok, data} = Tides.parse_water_level_response(@water_level_fixture)
      assert data[:water_level] == 2.34
    end

    test "includes sigma (quality/uncertainty)" do
      {:ok, data} = Tides.parse_water_level_response(@water_level_fixture)
      assert_in_delta data[:sigma], 0.012, 0.0001
    end

    test "preserves raw flags and quality strings" do
      {:ok, data} = Tides.parse_water_level_response(@water_level_fixture)
      assert data[:flags]   == "0,0,0,0"
      assert data[:quality] == "p"
    end

    test "includes the observation timestamp" do
      {:ok, data} = Tides.parse_water_level_response(@water_level_fixture)
      assert data[:timestamp] == "2024-01-15 12:00"
    end

    test "returns error tuple on NOAA API error message" do
      body = Jason.encode!(%{"error" => %{"message" => "No data was found."}})
      assert {:error, {:api_error, msg}} = Tides.parse_water_level_response(body)
      assert msg =~ "No data"
    end

    test "returns error tuple on malformed JSON" do
      assert {:error, :parse_failed} = Tides.parse_water_level_response("not json")
    end

    test "returns error tuple when data key is missing" do
      body = Jason.encode!(%{"metadata" => %{"id" => "8760721"}})
      assert {:error, :parse_failed} = Tides.parse_water_level_response(body)
    end

    test "returns error tuple when data list is empty" do
      body = Jason.encode!(%{"data" => []})
      assert {:error, :parse_failed} = Tides.parse_water_level_response(body)
    end

    test "handles negative water level (below MLLW datum)" do
      body = Jason.encode!(%{"data" => [%{"t" => "2024-01-15 06:00", "v" => "-0.52",
                                          "s" => "0.008", "f" => "0,0,0,0", "q" => "p"}]})
      assert {:ok, data} = Tides.parse_water_level_response(body)
      assert data[:water_level] == -0.52
    end
  end

  # ──────────────────────────────────────────────────────────
  # TIDAL PREDICTIONS RESPONSE PARSING
  # ──────────────────────────────────────────────────────────

  describe "parse_tidal_predictions_response/1" do
    # Fixture: 2 highs and 2 lows over 24 hours at Pilottown
    @predictions_fixture Jason.encode!(%{
      "predictions" => [
        %{"t" => "2024-01-15 01:12", "v" => "0.20", "type" => "L"},
        %{"t" => "2024-01-15 06:24", "v" => "2.10", "type" => "H"},
        %{"t" => "2024-01-15 12:36", "v" => "0.30", "type" => "L"},
        %{"t" => "2024-01-15 18:54", "v" => "1.80", "type" => "H"}
      ]
    })

    test "parses all 4 predictions" do
      {:ok, data} = Tides.parse_tidal_predictions_response(@predictions_fixture)
      assert data[:count] == 4
      assert length(data[:predictions]) == 4
    end

    test "maps H/L type strings to :high/:low atoms" do
      {:ok, data} = Tides.parse_tidal_predictions_response(@predictions_fixture)
      types = Enum.map(data[:predictions], & &1[:type])
      assert :high in types
      assert :low  in types
    end

    test "calculates tidal range as max_high - min_low" do
      # max high = 2.10, min low = 0.20  → range = 1.90
      {:ok, data} = Tides.parse_tidal_predictions_response(@predictions_fixture)
      assert_in_delta data[:range], 1.90, 0.001
    end

    test "identifies the first upcoming high" do
      {:ok, data} = Tides.parse_tidal_predictions_response(@predictions_fixture)
      next_high = data[:next_high]
      assert next_high[:type]  == :high
      assert next_high[:level] == 2.10
      assert next_high[:time]  == "2024-01-15 06:24"
    end

    test "identifies the first upcoming low" do
      {:ok, data} = Tides.parse_tidal_predictions_response(@predictions_fixture)
      next_low = data[:next_low]
      assert next_low[:type]  == :low
      assert next_low[:level] == 0.20
      assert next_low[:time]  == "2024-01-15 01:12"
    end

    test "returns nil range when no highs or lows are present" do
      body = Jason.encode!(%{"predictions" => []})
      {:ok, data} = Tides.parse_tidal_predictions_response(body)
      assert data[:range] == nil
      assert data[:count] == 0
    end

    test "returns nil next_high when no H prediction exists" do
      body = Jason.encode!(%{"predictions" => [
        %{"t" => "2024-01-15 06:00", "v" => "0.25", "type" => "L"}
      ]})
      {:ok, data} = Tides.parse_tidal_predictions_response(body)
      assert data[:next_high] == nil
    end

    test "returns error tuple on NOAA API error message" do
      body = Jason.encode!(%{"error" => %{"message" => "Station not found."}})
      assert {:error, {:api_error, _}} = Tides.parse_tidal_predictions_response(body)
    end

    test "returns error tuple on malformed JSON" do
      assert {:error, :parse_failed} = Tides.parse_tidal_predictions_response("oops")
    end
  end

  # ──────────────────────────────────────────────────────────
  # CURRENT VELOCITY RESPONSE PARSING
  # ──────────────────────────────────────────────────────────

  describe "parse_current_response/1" do
    @current_fixture Jason.encode!(%{
      "data" => [
        %{"t" => "2024-01-15 12:00", "s" => "1.35", "d" => "270.0", "b" => "1"},
        %{"t" => "2024-01-15 11:54", "s" => "1.28", "d" => "268.5", "b" => "1"}
      ]
    })

    test "extracts the latest (first) reading" do
      assert {:ok, data} = Tides.parse_current_response(@current_fixture)
      assert data[:speed] == 1.35
    end

    test "extracts current direction in degrees" do
      {:ok, data} = Tides.parse_current_response(@current_fixture)
      assert data[:direction] == 270.0
    end

    test "includes the bin identifier" do
      {:ok, data} = Tides.parse_current_response(@current_fixture)
      assert data[:bin] == "1"
    end

    test "includes the observation timestamp" do
      {:ok, data} = Tides.parse_current_response(@current_fixture)
      assert data[:timestamp] == "2024-01-15 12:00"
    end

    test "handles slack water (zero speed)" do
      body = Jason.encode!(%{"data" => [%{"t" => "2024-01-15 09:30",
                                          "s" => "0.00", "d" => "0.0", "b" => "1"}]})
      assert {:ok, data} = Tides.parse_current_response(body)
      assert data[:speed] == 0.0
    end

    test "returns error tuple on NOAA API error" do
      body = Jason.encode!(%{"error" => %{"message" => "Currents not available."}})
      assert {:error, {:api_error, _}} = Tides.parse_current_response(body)
    end

    test "returns error tuple on malformed JSON" do
      assert {:error, :parse_failed} = Tides.parse_current_response("{bad json")
    end

    test "returns error tuple when data list is empty" do
      body = Jason.encode!(%{"data" => []})
      assert {:error, :parse_failed} = Tides.parse_current_response(body)
    end
  end
end
