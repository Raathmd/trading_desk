defmodule TradingDesk.Traders do
  @moduledoc """
  Query helpers for the traders and trader_product_groups tables.

  Used by the UI to populate the trader dropdown and to determine
  which product group to default when a trader selects their session.
  """

  import Ecto.Query
  alias TradingDesk.Repo
  alias TradingDesk.DB.{TraderRecord, TraderProductGroupRecord}

  @doc """
  All active traders, ordered by name, with their product group assignments
  preloaded.

      iex> TradingDesk.Traders.list_active()
      [%TraderRecord{name: "Alice", product_groups: [...]}, ...]
  """
  @spec list_active() :: [TraderRecord.t()]
  def list_active do
    Repo.all(
      from t in TraderRecord,
        where: t.active == true,
        order_by: t.name,
        preload: [product_groups: ^product_groups_query()]
    )
  rescue
    _ -> []
  end

  @doc """
  Returns the primary product group atom for a trader, or falls back to
  the first assigned group, or `:ammonia_domestic` if nothing is set.
  """
  @spec primary_product_group(TraderRecord.t()) :: atom()
  def primary_product_group(%TraderRecord{product_groups: groups})
      when is_list(groups) and groups != [] do
    primary = Enum.find(groups, &(&1.is_primary)) || hd(groups)
    String.to_existing_atom(primary.product_group)
  rescue
    _ -> :ammonia_domestic
  end
  def primary_product_group(_), do: :ammonia_domestic

  @doc """
  Product group atoms assigned to a trader (for restricting the dropdown).
  Returns all groups if trader has no assignments.
  """
  @spec assigned_product_groups(TraderRecord.t()) :: [atom()]
  def assigned_product_groups(%TraderRecord{product_groups: []}), do: all_groups()
  def assigned_product_groups(%TraderRecord{product_groups: groups}) when is_list(groups) do
    Enum.map(groups, fn g ->
      String.to_existing_atom(g.product_group)
    end)
  rescue
    _ -> all_groups()
  end
  def assigned_product_groups(_), do: all_groups()

  defp all_groups, do: [:ammonia_domestic, :ammonia_international, :petcoke, :sulphur_international]

  defp product_groups_query do
    from g in TraderProductGroupRecord, order_by: [desc: g.is_primary, asc: g.product_group]
  end
end
