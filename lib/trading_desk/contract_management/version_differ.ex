defmodule TradingDesk.ContractManagement.VersionDiffer do
  @moduledoc """
  Computes JSON diff between contract versions.
  Used for the version comparison feature.
  """

  def diff(old_terms, new_terms) when is_map(old_terms) and is_map(new_terms) do
    old_keys = Map.keys(old_terms) |> MapSet.new()
    new_keys = Map.keys(new_terms) |> MapSet.new()

    added =
      MapSet.difference(new_keys, old_keys)
      |> Enum.into(%{}, fn key -> {key, Map.get(new_terms, key)} end)

    removed =
      MapSet.difference(old_keys, new_keys)
      |> Enum.into(%{}, fn key -> {key, Map.get(old_terms, key)} end)

    modified =
      MapSet.intersection(old_keys, new_keys)
      |> Enum.filter(fn key -> Map.get(old_terms, key) != Map.get(new_terms, key) end)
      |> Enum.into(%{}, fn key ->
        {key, %{old: Map.get(old_terms, key), new: Map.get(new_terms, key)}}
      end)

    %{added: added, removed: removed, modified: modified}
  end

  def diff(_, _), do: %{added: %{}, removed: %{}, modified: %{}}
end
