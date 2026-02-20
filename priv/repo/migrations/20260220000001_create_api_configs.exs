defmodule TradingDesk.Repo.Migrations.CreateApiConfigs do
  use Ecto.Migration

  def change do
    # ──────────────────────────────────────────────────────────
    # API CONFIGS
    #
    # Admin-configurable per-product-group API settings:
    #   - API endpoint URLs per data source
    #   - API keys/credentials per data source
    #
    # Keyed by product_group (matching delta_configs pattern).
    # api_entries shape (JSONB):
    #   %{
    #     "eia"      => %{"url" => "https://api.eia.gov/v2", "api_key" => "..."},
    #     "usgs"     => %{"url" => "https://waterservices.usgs.gov/nwis", "api_key" => ""},
    #     "noaa"     => %{"url" => "https://api.weather.gov", "api_key" => ""},
    #     "usace"    => %{"url" => "...", "api_key" => ""},
    #     "market"   => %{"url" => "...", "api_key" => ""},
    #     "broker"   => %{"url" => "...", "api_key" => ""},
    #     "internal" => %{"url" => "...", "api_key" => ""},
    #     "vessel_tracking" => %{"url" => "...", "api_key" => ""},
    #     "tides"    => %{"url" => "...", "api_key" => ""}
    #   }
    # ──────────────────────────────────────────────────────────

    create table(:api_configs, primary_key: false) do
      add :product_group, :string, primary_key: true
      add :api_entries,   :map,    default: %{}, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
