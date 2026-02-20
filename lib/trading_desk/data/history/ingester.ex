defmodule TradingDesk.Data.History.Ingester do
  @moduledoc """
  Market history ingestion pipeline.

  Populates three history tables in Postgres (TradingDesk.Repo):

    - `river_stage_history`   — daily USGS gauge readings (all four gauges)
    - `ammonia_price_history` — ammonia benchmark price snapshots
    - `freight_rate_history`  — barge freight rate snapshots

  ## USGS river data

  USGS publishes daily mean values via a free, unauthenticated API:

      https://waterservices.usgs.gov/nwis/dv/

  `backfill_river/2` fetches the full date range in one request per gauge
  and upserts rows. Safe to call repeatedly — existing rows are skipped.

  ## Ammonia prices and freight rates

  There is no public historical API for Argus/Fertecon pricing or broker
  freight rates. These are available only via paid subscriptions. The approach
  here is twofold:

    1. **Snapshot today** — `snapshot_prices/0` and `snapshot_freight/0`
       record whatever the live feed currently returns. Call these on a
       schedule (e.g. daily after market close) to build history over time.

    2. **Manual import** — `import_prices/1` and `import_freight/1` accept
       a list of maps, allowing you to paste in a CSV export from Argus/Fertecon.

  ## Convenience entry points

      # One-shot: backfill everything from last 5 years
      TradingDesk.Data.History.Ingester.run_full_backfill()

      # On-demand: record today's live values
      TradingDesk.Data.History.Ingester.snapshot_today()

  """

  require Logger

  alias TradingDesk.Repo
  alias TradingDesk.Data.History.{RiverStageHistory, AmmoniaPriceHistory, FreightRateHistory}
  alias TradingDesk.Data.AmmoniaPrices
  alias TradingDesk.Data.API.{USGS, Broker}

  # USGS daily values endpoint (different from the IV endpoint in USGS module)
  @usgs_dv_url "https://waterservices.usgs.gov/nwis/dv/"

  @gauges %{
    baton_rouge: "07374000",
    vicksburg:   "07289000",
    memphis:     "07032000",
    cairo:       "03612500"
  }

  @param_gauge_height "00065"
  @param_discharge    "00060"

  # ──────────────────────────────────────────────────────────
  # CONVENIENCE ENTRY POINTS
  # ──────────────────────────────────────────────────────────

  @doc """
  Full backfill — fetch river history going back `years_back` years,
  then snapshot current prices and freight.

  Call this once to seed the database. Safe to re-run (upserts).

      TradingDesk.Data.History.Ingester.run_full_backfill()
      TradingDesk.Data.History.Ingester.run_full_backfill(years_back: 3)
  """
  @spec run_full_backfill(keyword()) :: :ok
  def run_full_backfill(opts \\ []) do
    years_back = Keyword.get(opts, :years_back, 5)

    end_date   = Date.utc_today()
    start_date = Date.add(end_date, -(years_back * 365))

    Logger.info("HistoryIngester: starting full backfill #{start_date} → #{end_date}")

    backfill_river(start_date, end_date)
    snapshot_prices()
    snapshot_freight()

    Logger.info("HistoryIngester: full backfill complete")
    :ok
  end

  @doc """
  Record today's current prices and freight rates.

  Call this daily (e.g. from a scheduled job after market close) to build
  an ongoing history of live values.
  """
  @spec snapshot_today() :: :ok
  def snapshot_today do
    snapshot_prices()
    snapshot_freight()
    :ok
  end

  # ──────────────────────────────────────────────────────────
  # RIVER STAGE BACKFILL
  # ──────────────────────────────────────────────────────────

  @doc """
  Fetch USGS daily values for all four gauges over the given date range.

  Uses the USGS daily values (dv) service, which returns daily mean
  gauge height and discharge. Upserts rows — safe to call repeatedly.

      iex> TradingDesk.Data.History.Ingester.backfill_river(~D[2021-01-01], ~D[2026-02-19])
  """
  @spec backfill_river(Date.t(), Date.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def backfill_river(start_date, end_date) do
    Logger.info("HistoryIngester: fetching USGS river history #{start_date} → #{end_date}")

    site_ids = @gauges |> Map.values() |> Enum.join(",")

    url = build_dv_url(site_ids, start_date, end_date)

    case http_get(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"value" => %{"timeSeries" => series}}} ->
            rows = parse_daily_series(series)
            now = DateTime.utc_now()
            count = upsert_river_rows(rows, now)
            Logger.info("HistoryIngester: upserted #{count} river stage rows")
            {:ok, count}

          {:ok, _} ->
            {:error, :unexpected_usgs_format}

          {:error, reason} ->
            {:error, {:json_parse_failed, reason}}
        end

      {:error, reason} ->
        Logger.warning("HistoryIngester: USGS fetch failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PRICE SNAPSHOTS
  # ──────────────────────────────────────────────────────────

  @doc """
  Record today's ammonia benchmark prices from the live price feed.

  Skips benchmarks where price is nil or zero. Upserts — safe to call multiple
  times per day (the unique index is on date + benchmark_key, so re-runs
  on the same date are no-ops unless you want to update intra-day).
  """
  @spec snapshot_prices() :: {:ok, non_neg_integer()} | {:error, term()}
  def snapshot_prices do
    today = Date.utc_today()
    now   = DateTime.utc_now()

    benchmarks = AmmoniaPrices.benchmarks()

    rows =
      Enum.flat_map(benchmarks, fn {key, data} ->
        price = data[:price]
        if is_number(price) and price > 0 do
          [%{
            date:          today,
            benchmark_key: to_string(key),
            price_usd:     price / 1.0,
            unit:          data[:unit],
            source:        data[:source] && String.downcase(data[:source]),
            fetched_at:    now
          }]
        else
          []
        end
      end)

    count = upsert_price_rows(rows)
    Logger.info("HistoryIngester: recorded #{count} price snapshots for #{today}")
    {:ok, count}
  end

  @doc """
  Import historical ammonia prices from a list of maps.

  Use this to load a CSV export from Argus or Fertecon.
  Each entry must have: `:date`, `:benchmark_key`, `:price_usd`.
  Optional: `:unit`, `:source`, `:notes`.

      rows = [
        %{date: ~D[2024-03-15], benchmark_key: "fob_nola", price_usd: 310.0, source: "fertecon"},
        %{date: ~D[2024-03-15], benchmark_key: "cfr_tampa", price_usd: 395.0, source: "fertecon"},
      ]
      TradingDesk.Data.History.Ingester.import_prices(rows)
  """
  @spec import_prices([map()]) :: {:ok, non_neg_integer()}
  def import_prices(rows) when is_list(rows) do
    now = DateTime.utc_now()

    normalized =
      Enum.map(rows, fn r ->
        r
        |> Map.put_new(:source, "manual")
        |> Map.put(:fetched_at, now)
      end)

    count = upsert_price_rows(normalized)
    Logger.info("HistoryIngester: imported #{count} historical price rows")
    {:ok, count}
  end

  # ──────────────────────────────────────────────────────────
  # FREIGHT RATE SNAPSHOTS
  # ──────────────────────────────────────────────────────────

  @doc """
  Record today's freight rates from the live broker feed.

  Falls back gracefully if the broker API is not configured — returns
  `{:ok, 0}` rather than an error, since missing freight history is
  non-fatal.
  """
  @spec snapshot_freight() :: {:ok, non_neg_integer()} | {:error, term()}
  def snapshot_freight do
    today = Date.utc_today()
    now   = DateTime.utc_now()

    case Broker.fetch() do
      {:ok, rates} ->
        source = to_string(rates[:source] || "broker_api")

        rows =
          for route <- [:don_stl, :don_mem, :geis_stl, :geis_mem],
              rate = rates[String.to_atom("fr_#{route}") |> to_string() |> String.to_atom()],
              is_number(rate) do
            %{
              date:         today,
              route:        to_string(route),
              rate_per_ton: rate / 1.0,
              source:       source,
              fetched_at:   now
            }
          end

        count = upsert_freight_rows(rows)
        Logger.info("HistoryIngester: recorded #{count} freight snapshots for #{today}")
        {:ok, count}

      {:error, :no_feed_configured} ->
        Logger.debug("HistoryIngester: no broker feed configured, skipping freight snapshot")
        {:ok, 0}

      {:error, reason} ->
        Logger.warning("HistoryIngester: freight snapshot failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Import historical freight rates from a list of maps.

  Each entry must have: `:date`, `:route`, `:rate_per_ton`.
  Optional: `:source`, `:notes`.

      rows = [
        %{date: ~D[2024-06-01], route: "don_stl", rate_per_ton: 95.0, source: "broker_api"},
        %{date: ~D[2024-06-01], route: "don_mem", rate_per_ton: 52.0, source: "broker_api"},
      ]
      TradingDesk.Data.History.Ingester.import_freight(rows)
  """
  @spec import_freight([map()]) :: {:ok, non_neg_integer()}
  def import_freight(rows) when is_list(rows) do
    now = DateTime.utc_now()

    normalized =
      Enum.map(rows, fn r ->
        r
        |> Map.put_new(:source, "manual")
        |> Map.put(:fetched_at, now)
      end)

    count = upsert_freight_rows(normalized)
    Logger.info("HistoryIngester: imported #{count} historical freight rows")
    {:ok, count}
  end

  # ──────────────────────────────────────────────────────────
  # USGS PARSING
  # ──────────────────────────────────────────────────────────

  # Reverse-index site_id → gauge_key for the response parser
  @site_to_gauge Map.new(@gauges, fn {k, v} -> {v, to_string(k)} end)

  defp parse_daily_series(series) when is_list(series) do
    # Group by (site_id, parameter_code) — USGS returns one timeSeries per combo
    Enum.reduce(series, %{}, fn ts, acc ->
      site_id   = get_in(ts, ["sourceInfo", "siteCode", Access.at(0), "value"])
      param     = get_in(ts, ["variable", "variableCode", Access.at(0), "value"])
      gauge_key = Map.get(@site_to_gauge, site_id)

      unless gauge_key do
        acc
      else
        values = get_in(ts, ["values", Access.at(0), "value"]) || []

        Enum.reduce(values, acc, fn v, inner_acc ->
          date_str = v["dateTime"]
          val      = parse_float(v["value"])

          case Date.from_iso8601(String.slice(date_str, 0, 10)) do
            {:ok, date} ->
              row_key = {date, gauge_key}
              existing = Map.get(inner_acc, row_key, %{date: date, gauge_key: gauge_key})

              updated =
                case param do
                  @param_gauge_height -> Map.put(existing, :stage_ft, val)
                  @param_discharge    -> Map.put(existing, :flow_cfs, val)
                  _                  -> existing
                end

              Map.put(inner_acc, row_key, updated)

            _ ->
              inner_acc
          end
        end)
      end
    end)
    |> Map.values()
  end

  # ──────────────────────────────────────────────────────────
  # UPSERTS
  # ──────────────────────────────────────────────────────────

  defp upsert_river_rows(rows, now) do
    rows
    |> Enum.map(fn r -> Map.put_new(r, :fetched_at, now) end)
    |> Enum.reduce(0, fn attrs, count ->
      attrs = Map.put_new(attrs, :source, "usgs")

      case %RiverStageHistory{}
           |> RiverStageHistory.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:date, :gauge_key]) do
        {:ok, _}    -> count + 1
        {:error, _} -> count
      end
    end)
  rescue
    e ->
      Logger.error("HistoryIngester: river upsert crashed: #{Exception.message(e)}")
      0
  end

  defp upsert_price_rows(rows) do
    Enum.reduce(rows, 0, fn attrs, count ->
      case %AmmoniaPriceHistory{}
           |> AmmoniaPriceHistory.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:date, :benchmark_key]) do
        {:ok, _}    -> count + 1
        {:error, _} -> count
      end
    end)
  rescue
    e ->
      Logger.error("HistoryIngester: price upsert crashed: #{Exception.message(e)}")
      0
  end

  defp upsert_freight_rows(rows) do
    Enum.reduce(rows, 0, fn attrs, count ->
      case %FreightRateHistory{}
           |> FreightRateHistory.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: [:date, :route]) do
        {:ok, _}    -> count + 1
        {:error, _} -> count
      end
    end)
  rescue
    e ->
      Logger.error("HistoryIngester: freight upsert crashed: #{Exception.message(e)}")
      0
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp build_dv_url(site_ids, start_date, end_date) do
    params = URI.encode_query(%{
      "format"      => "json",
      "sites"       => site_ids,
      "parameterCd" => "#{@param_gauge_height},#{@param_discharge}",
      "statCd"      => "00003",   # daily mean
      "startDT"     => Date.to_iso8601(start_date),
      "endDT"       => Date.to_iso8601(end_date)
    })

    "#{@usgs_dv_url}?#{params}"
  end

  defp parse_float(nil), do: nil
  defp parse_float("-999999" <> _), do: nil   # USGS sentinel for missing data
  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
  defp parse_float(v) when is_number(v), do: v / 1.0

  defp http_get(url) do
    case Req.get(url, receive_timeout: 60_000) do
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
