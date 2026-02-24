defmodule TradingDesk.ApiConfig do
  @moduledoc """
  Context for managing per-product-group API configuration.

  Stores and retrieves the URL and API key for each data source
  used by a given product group. Configuration is persisted in the
  `api_configs` table, keyed by `product_group`.
  """

  import Ecto.Query
  alias TradingDesk.Repo
  alias TradingDesk.DB.ApiConfigRecord

  @doc """
  Fetch the full ApiConfigRecord for a product group, or nil if none exists.
  """
  @spec get(atom() | String.t()) :: ApiConfigRecord.t() | nil
  def get(product_group) do
    pg = to_string(product_group)
    Repo.get(ApiConfigRecord, pg)
  end

  @doc """
  Fetch the api_entries map for a product group.
  Returns %{} if no config row exists yet.
  """
  @spec get_entries(atom() | String.t()) :: map()
  def get_entries(product_group) do
    case get(product_group) do
      nil -> %{}
      record -> record.api_entries || %{}
    end
  end

  @doc """
  Insert or update the full api_entries map for a product group.
  """
  @spec upsert(atom() | String.t(), map()) :: {:ok, ApiConfigRecord.t()} | {:error, Ecto.Changeset.t()}
  def upsert(product_group, api_entries) do
    pg = to_string(product_group)

    attrs = %{product_group: pg, api_entries: api_entries}

    %ApiConfigRecord{}
    |> ApiConfigRecord.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:api_entries, :updated_at]},
      conflict_target: :product_group
    )
  end

  @doc """
  Update a single API source entry (url and api_key) within a product group.
  Merges into the existing api_entries, preserving other sources.
  """
  @spec update_source(atom() | String.t(), String.t(), String.t(), String.t()) ::
          {:ok, ApiConfigRecord.t()} | {:error, Ecto.Changeset.t()}
  def update_source(product_group, source, url, api_key) do
    existing = get_entries(product_group)

    updated = Map.put(existing, source, %{"url" => url, "api_key" => api_key})

    upsert(product_group, updated)
  end

  @doc """
  Get the effective API key for a source.

  Returns the DB-stored value (under the "global" product group) if set,
  otherwise falls back to reading the given environment variable.
  """
  @spec get_credential(String.t(), String.t()) :: String.t() | nil
  def get_credential(source, env_var) do
    db_val =
      get_entries("global")
      |> Map.get(source, %{})
      |> Map.get("api_key")

    if db_val not in [nil, ""] do
      db_val
    else
      System.get_env(env_var)
    end
  end

  @doc """
  Get the effective URL for a source.

  Returns the DB-stored value (under the "global" product group) if set,
  otherwise falls back to reading `env_var`, then `default`.
  """
  @spec get_url(String.t(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def get_url(source, env_var, default \\ nil) do
    db_val =
      get_entries("global")
      |> Map.get(source, %{})
      |> Map.get("url")

    if db_val not in [nil, ""] do
      db_val
    else
      (env_var && System.get_env(env_var)) || default
    end
  end
end
