defmodule TradingDesk.DB.ApiConfigRecord do
  @moduledoc """
  Ecto schema for persisting API configuration per product group.

  Stores the URL and API key for each data source used by a product group.
  Keyed by product_group — one row per product group.

  The `api_entries` JSONB map has the shape:

      %{
        "eia"      => %{"url" => "https://api.eia.gov/v2", "api_key" => "..."},
        "usgs"     => %{"url" => "https://waterservices.usgs.gov/nwis", "api_key" => ""},
        "noaa"     => %{"url" => "https://api.weather.gov", "api_key" => ""},
        "usace"    => %{"url" => "...", "api_key" => ""},
        "market"   => %{"url" => "...", "api_key" => ""},
        "broker"   => %{"url" => "...", "api_key" => ""},
        "internal" => %{"url" => "...", "api_key" => ""},
        "vessel_tracking" => %{"url" => "...", "api_key" => ""},
        "tides"    => %{"url" => "...", "api_key" => ""}
      }
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:product_group, :string, autogenerate: false}
  schema "api_configs" do
    field :api_entries, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:product_group, :api_entries])
    |> validate_required([:product_group])
  end
end
