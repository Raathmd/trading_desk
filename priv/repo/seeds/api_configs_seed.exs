defmodule TradingDesk.Seeds.ApiConfigsSeed do
  @moduledoc """
  Seeds the `api_configs` table with default endpoint URLs and API key
  env-var fallbacks for every data source that feeds the 20 core solver
  variables.

  Each source entry stores a `url` (the canonical base URL) and an
  `api_key` placeholder.  At runtime, `ApiConfig.get_credential/2` and
  `ApiConfig.get_url/3` check the DB first, then fall back to the
  corresponding environment variable.

  Safe to re-run — uses upsert on product_group.
  """

  alias TradingDesk.ApiConfig

  # Source entries for the "global" product group.
  # Keys match the source_id column in variable_definitions.
  @global_entries %{
    # ── ENVIRONMENT ───────────────────────────────────────────────────────
    "usgs" => %{
      "url"     => "https://waterservices.usgs.gov/nwis/iv/",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "",
      "notes"   => "USGS Water Services — free, no key needed"
    },
    "noaa" => %{
      "url"     => "https://api.weather.gov/",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "",
      "notes"   => "NOAA Weather API — free, no key needed (User-Agent required)"
    },
    "usace" => %{
      "url"     => "https://ndc.ops.usace.army.mil/api/lockstatus",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "",
      "notes"   => "USACE Lock Performance — free, no key needed"
    },

    # ── COMMERCIAL — pricing ──────────────────────────────────────────────
    "eia" => %{
      "url"     => "https://api.eia.gov/v2/natural-gas/pri/fut/data/",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "EIA_API_KEY",
      "notes"   => "EIA Henry Hub — free key from https://www.eia.gov/opendata/"
    },
    "delivered_prices" => %{
      "url"     => "",
      "api_key" => "",
      "env_url" => "DELIVERED_PRICES_URL",
      "env_key" => "DELIVERED_PRICES_KEY",
      "notes"   => "Custom delivered prices endpoint (primary market source)"
    },
    "argus" => %{
      "url"     => "https://api.argusmedia.com/v2",
      "api_key" => "",
      "env_url" => "ARGUS_API_URL",
      "env_key" => "ARGUS_API_KEY",
      "notes"   => "Argus Media ammonia assessments (subscription)"
    },
    "icis" => %{
      "url"     => "https://api.icis.com/v1",
      "api_key" => "",
      "env_url" => "ICIS_API_URL",
      "env_key" => "ICIS_API_KEY",
      "notes"   => "ICIS/Profercy ammonia pricing (subscription)"
    },
    "market" => %{
      "url"     => "",
      "api_key" => "",
      "env_url" => "MARKET_FEED_URL",
      "env_key" => "MARKET_FEED_KEY",
      "notes"   => "Fallback custom market feed"
    },

    # ── COMMERCIAL — freight ──────────────────────────────────────────────
    "broker" => %{
      "url"     => "",
      "api_key" => "",
      "env_url" => "BROKER_API_URL",
      "env_key" => "BROKER_API_KEY",
      "notes"   => "Barge freight broker API"
    },

    # ── OPERATIONS — inventory, fleet, capital ────────────────────────────
    "insight" => %{
      "url"     => "",
      "api_key" => "",
      "env_url" => "INSIGHT_API_URL",
      "env_key" => "INSIGHT_API_KEY",
      "notes"   => "Insight TMS — terminal inventory and outages"
    },
    "tms" => %{
      "url"     => "",
      "api_key" => "",
      "env_url" => "TMS_URL",
      "env_key" => "TMS_API_KEY",
      "notes"   => "Fleet TMS — barge count and freight rates"
    },
    "sap" => %{
      "url"     => "",
      "api_key" => "",
      "env_url" => "SAP_API_URL",
      "env_key" => "SAP_API_KEY",
      "notes"   => "SAP S/4HANA FI — working capital"
    },

    # ── SUPPLEMENTARY ─────────────────────────────────────────────────────
    "vessel_tracking" => %{
      "url"     => "wss://stream.aisstream.io/v0/stream",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "AISSTREAM_API_KEY",
      "notes"   => "AISStream WebSocket — vessel positions"
    },
    "tides" => %{
      "url"     => "https://api.tidesandcurrents.noaa.gov/api/prod/",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "",
      "notes"   => "NOAA Tides & Currents — free, no key needed"
    },
    "forecast" => %{
      "url"     => "https://api.weather.gov/",
      "api_key" => "",
      "env_url" => "",
      "env_key" => "",
      "notes"   => "NWS Extended Forecast — free via NOAA"
    }
  }

  def run do
    IO.puts("  → Seeding api_configs for \"global\" (#{map_size(@global_entries)} sources)...")

    case ApiConfig.upsert("global", @global_entries) do
      {:ok, _record} ->
        IO.puts("  ✓ api_configs: global entries upserted")
      {:error, changeset} ->
        IO.puts("  ⚠ api_configs seed failed: #{inspect(changeset.errors)}")
    end
  end
end
