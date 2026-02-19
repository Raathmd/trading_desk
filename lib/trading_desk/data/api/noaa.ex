defmodule TradingDesk.Data.API.NOAA do
  @moduledoc """
  NOAA Weather API integration.

  Fetches current weather observations relevant to barge operations on the
  Lower Mississippi River. Maps to solver variables:

    - temp_f: Air temperature (affects ammonia handling, vapor pressure)
    - wind_mph: Wind speed (affects barge navigation, loading ops)
    - vis_mi: Visibility (fog/haze affects transit, lock operations)
    - precip_in: Precipitation (affects river stage forecast)

  API documentation: https://www.weather.gov/documentation/services-web-api

  ## Stations

  We monitor weather stations along the barge route:
    - KBTR: Baton Rouge Metro (Ryan Field) — near NOLA terminals
    - KMEM: Memphis International — Memphis delivery point
    - KSTL: St. Louis Lambert — St. Louis delivery point
    - KVKS: Vicksburg Municipal — mid-route reference

  ## Rate Limits

  NOAA requires a User-Agent header with contact info.
  No strict rate limit, but courtesy suggests max 1 request/sec.
  """

  require Logger

  @stations %{
    baton_rouge: %{
      station_id: "KBTR",
      name: "Baton Rouge Metro Airport",
      role: :origin  # near NOLA terminals
    },
    memphis: %{
      station_id: "KMEM",
      name: "Memphis International Airport",
      role: :destination
    },
    st_louis: %{
      station_id: "KSTL",
      name: "St. Louis Lambert International",
      role: :destination
    },
    vicksburg: %{
      station_id: "KVKS",
      name: "Vicksburg Municipal Airport",
      role: :waypoint
    }
  }

  @base_url "https://api.weather.gov"
  @user_agent {"User-Agent", "(TradingDesk, ops@trammo.com)"}

  @doc """
  Fetch current weather observations for all stations.

  Returns `{:ok, %{temp_f: float, wind_mph: float, vis_mi: float, precip_in: float, stations: map}}`
  or `{:error, reason}`.

  Primary values come from Baton Rouge (origin).
  All station data is included for route-level weather assessment.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    results =
      @stations
      |> Enum.map(fn {key, station} ->
        {key, fetch_station(station.station_id)}
      end)
      |> Map.new()

    # Primary station for solver variables
    primary = results[:baton_rouge]

    case primary do
      {:ok, obs} ->
        station_data = Map.new(results, fn {k, v} ->
          case v do
            {:ok, data} -> {k, data}
            {:error, _} -> {k, nil}
          end
        end)

        {:ok, %{
          temp_f: obs[:temp_f],
          wind_mph: obs[:wind_mph],
          vis_mi: obs[:vis_mi],
          precip_in: obs[:precip_in] || 0.0,
          stations: station_data
        }}

      {:error, reason} ->
        Logger.warning("NOAA: primary station fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Fetch observations from a specific station."
  @spec fetch_station(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_station(station_id) do
    url = "#{@base_url}/stations/#{station_id}/observations/latest"

    case http_get(url) do
      {:ok, body} -> parse_observation(body)
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetch 3-day precipitation forecast for origin area.

  Uses the NWS gridpoint forecast to get quantitative precipitation.
  Maps to `precip_in` variable.
  """
  @spec fetch_precip_forecast() :: {:ok, float()} | {:error, term()}
  def fetch_precip_forecast do
    # Baton Rouge grid point (pre-resolved)
    url = "#{@base_url}/gridpoints/LIX/66,62/forecast"

    case http_get(url) do
      {:ok, body} -> parse_precip_forecast(body)
      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────
  # 7-DAY FORECAST (HOURLY)
  # ──────────────────────────────────────────────────────────

  # NWS gridpoints for each weather station (pre-resolved to avoid a lookup call)
  @gridpoints %{
    baton_rouge: "LIX/66,62",
    memphis:     "MEG/53,72",
    st_louis:    "LSX/85,71",
    vicksburg:   "JAN/44,78"
  }

  @doc """
  Fetch 7-day hourly forecast for all stations. Returns forecast data
  bucketed by day (D+0 through D+6) with the solver-relevant variables.

  Returns `{:ok, %{days: [day_map], worst_case_d3: map}}` where each day_map:
    - date: ISO date
    - temp_f_high / temp_f_low
    - wind_mph_max
    - precip_in: total expected precipitation
    - precip_prob_max: max probability of precipitation (%)
    - vis_mi_min: worst visibility
  """
  @spec fetch_forecast() :: {:ok, map()} | {:error, term()}
  def fetch_forecast do
    # Fetch from primary station (Baton Rouge)
    grid = @gridpoints[:baton_rouge]
    url = "#{@base_url}/gridpoints/#{grid}/forecast/hourly"

    case http_get(url) do
      {:ok, body} -> parse_hourly_forecast(body)
      {:error, _} = err -> err
    end
  end

  @doc """
  Fetch forecast for a specific station by key.
  """
  def fetch_forecast(station_key) when is_atom(station_key) do
    case @gridpoints[station_key] do
      nil -> {:error, {:unknown_station, station_key}}
      grid ->
        url = "#{@base_url}/gridpoints/#{grid}/forecast/hourly"
        case http_get(url) do
          {:ok, body} -> parse_hourly_forecast(body)
          {:error, _} = err -> err
        end
    end
  end

  @doc """
  Fetch forecast from all stations and return worst-case per day.
  This is the conservative projection the solver should use.
  """
  @spec fetch_all_forecasts() :: {:ok, map()} | {:error, term()}
  def fetch_all_forecasts do
    results =
      @gridpoints
      |> Enum.map(fn {key, grid} ->
        url = "#{@base_url}/gridpoints/#{grid}/forecast/hourly"
        {key, case http_get(url) do
          {:ok, body} -> parse_hourly_forecast(body)
          err -> err
        end}
      end)

    # Find the first successful result as baseline
    baseline =
      results
      |> Enum.find_value(fn {_k, {:ok, data}} -> data; _ -> nil end)

    if baseline do
      # Merge worst-case across all stations per day
      all_days =
        results
        |> Enum.filter(fn {_, {:ok, _}} -> true; _ -> false end)
        |> Enum.flat_map(fn {_, {:ok, %{days: days}}} -> days end)
        |> Enum.group_by(& &1.date)
        |> Enum.sort_by(fn {date, _} -> date end)
        |> Enum.map(fn {date, day_list} ->
          %{
            date:           date,
            temp_f_low:     day_list |> Enum.map(& &1.temp_f_low)     |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end),
            temp_f_high:    day_list |> Enum.map(& &1.temp_f_high)    |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
            wind_mph_max:   day_list |> Enum.map(& &1.wind_mph_max)   |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
            precip_in:      day_list |> Enum.map(& &1.precip_in)      |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
            precip_prob_max: day_list |> Enum.map(& &1.precip_prob_max) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end),
            vis_mi_min:     day_list |> Enum.map(& &1.vis_mi_min)     |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)
          }
        end)

      # D+3 worst-case for solver: conservative conditions 3 days out
      d3 = Enum.at(all_days, 3) || Enum.at(all_days, 2) || %{}
      solver_forecast = %{
        forecast_temp_f:    d3[:temp_f_low],
        forecast_wind_mph:  d3[:wind_mph_max],
        forecast_vis_mi:    d3[:vis_mi_min],
        forecast_precip_in: d3[:precip_in]
      }

      {:ok, %{
        days: all_days,
        solver_d3: solver_forecast,
        stations: Map.new(results, fn {k, v} -> {k, elem(v, 1)} end)
      }}
    else
      {:error, :all_forecasts_failed}
    end
  rescue
    _ -> {:error, :forecast_exception}
  end

  # ──────────────────────────────────────────────────────────
  # PARSING
  # ──────────────────────────────────────────────────────────

  defp parse_observation(body) do
    case Jason.decode(body) do
      {:ok, %{"properties" => props}} ->
        {:ok, %{
          temp_f: convert_temp(props["temperature"]),
          wind_mph: convert_wind(props["windSpeed"]),
          vis_mi: convert_visibility(props["visibility"]),
          precip_in: convert_precip(props["precipitationLastHour"]),
          wind_direction: get_value(props["windDirection"]),
          dewpoint_f: convert_temp(props["dewpoint"]),
          humidity: get_value(props["relativeHumidity"]),
          barometric_pressure: get_value(props["barometricPressure"]),
          timestamp: props["timestamp"],
          text_description: props["textDescription"]
        }}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_precip_forecast(body) do
    case Jason.decode(body) do
      {:ok, %{"properties" => %{"periods" => periods}}} ->
        # Sum precipitation probability over next 3 days (6 periods)
        # This is a rough estimate — real QPF would use gridded data
        total_precip =
          periods
          |> Enum.take(6)  # ~3 days of 12-hour periods
          |> Enum.reduce(0.0, fn period, acc ->
            detail = period["detailedForecast"] || ""

            cond do
              String.contains?(detail, "heavy rain") -> acc + 1.5
              String.contains?(detail, "rain") -> acc + 0.5
              String.contains?(detail, "showers") -> acc + 0.3
              String.contains?(detail, "drizzle") -> acc + 0.1
              true -> acc
            end
          end)

        {:ok, total_precip}

      _ ->
        {:error, :parse_failed}
    end
  end

  defp parse_hourly_forecast(body) do
    case Jason.decode(body) do
      {:ok, %{"properties" => %{"periods" => periods}}} when is_list(periods) ->
        # Group hourly periods by date, then aggregate per day
        by_date =
          periods
          |> Enum.group_by(fn p ->
            # startTime is ISO8601 like "2026-02-19T06:00:00-06:00"
            p["startTime"] |> String.slice(0, 10)
          end)
          |> Enum.sort_by(fn {date, _} -> date end)
          |> Enum.take(7)  # 7 days

        days =
          Enum.map(by_date, fn {date, hours} ->
            temps = hours |> Enum.map(& &1["temperature"]) |> Enum.reject(&is_nil/1)
            winds = hours |> Enum.map(&parse_wind_forecast/1) |> Enum.reject(&is_nil/1)
            precip_probs = hours |> Enum.map(&get_in(&1, ["probabilityOfPrecipitation", "value"])) |> Enum.reject(&is_nil/1)

            # Estimate precip from probability + detailed text
            precip_in =
              hours
              |> Enum.reduce(0.0, fn h, acc ->
                prob = get_in(h, ["probabilityOfPrecipitation", "value"]) || 0
                detail = h["shortForecast"] || ""

                hourly_precip = cond do
                  prob >= 70 and String.contains?(detail, "Heavy") -> 0.15
                  prob >= 70 -> 0.08
                  prob >= 40 -> 0.03
                  prob >= 20 -> 0.01
                  true -> 0.0
                end

                acc + hourly_precip
              end)

            %{
              date:            date,
              temp_f_high:     if(temps != [], do: Enum.max(temps)),
              temp_f_low:      if(temps != [], do: Enum.min(temps)),
              wind_mph_max:    if(winds != [], do: Enum.max(winds)),
              precip_in:       Float.round(precip_in, 2),
              precip_prob_max: if(precip_probs != [], do: Enum.max(precip_probs), else: 0),
              vis_mi_min:      nil  # NWS hourly doesn't always include visibility
            }
          end)

        {:ok, %{days: days}}

      _ ->
        {:error, :forecast_parse_failed}
    end
  end

  defp parse_wind_forecast(period) do
    case period["windSpeed"] do
      s when is_binary(s) ->
        # "15 mph" or "10 to 20 mph"
        case Regex.run(~r/(\d+)\s*(?:to\s*(\d+))?\s*mph/i, s) do
          [_, low, high] -> String.to_integer(high)
          [_, val]       -> String.to_integer(val)
          _              -> nil
        end
      n when is_number(n) -> n
      _ -> nil
    end
  end

  # ──────────────────────────────────────────────────────────
  # UNIT CONVERSIONS
  # ──────────────────────────────────────────────────────────

  defp convert_temp(%{"value" => v, "unitCode" => "wmoUnit:degC"}) when is_number(v) do
    v * 9.0 / 5.0 + 32.0
  end
  defp convert_temp(%{"value" => v, "unitCode" => "wmoUnit:degF"}) when is_number(v), do: v
  defp convert_temp(_), do: nil

  defp convert_wind(%{"value" => v, "unitCode" => "wmoUnit:km_h-1"}) when is_number(v) do
    v * 0.621371
  end
  defp convert_wind(%{"value" => v, "unitCode" => "wmoUnit:m_s-1"}) when is_number(v) do
    v * 2.23694
  end
  defp convert_wind(_), do: nil

  defp convert_visibility(%{"value" => v, "unitCode" => "wmoUnit:m"}) when is_number(v) do
    v / 1609.34
  end
  defp convert_visibility(_), do: nil

  defp convert_precip(%{"value" => v, "unitCode" => "wmoUnit:mm"}) when is_number(v) do
    v / 25.4  # mm to inches
  end
  defp convert_precip(_), do: 0.0

  defp get_value(%{"value" => v}) when is_number(v), do: v
  defp get_value(_), do: nil

  # ──────────────────────────────────────────────────────────
  # HTTP
  # ──────────────────────────────────────────────────────────

  defp http_get(url) do
    headers = [@user_agent, {"Accept", "application/geo+json"}]

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, Jason.encode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end
end
