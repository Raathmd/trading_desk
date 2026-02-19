defmodule TradingDesk.Data.History.Stats do
  @moduledoc """
  Summary queries for the three market history tables.
  All functions accept an optional date range via opts: [from: date, to: date].
  """

  import Ecto.Query
  alias TradingDesk.Repo
  alias TradingDesk.Data.History.{RiverStageHistory, AmmoniaPriceHistory, FreightRateHistory}

  @doc """
  Full summary for all three tables filtered by date range.
  Defaults to previous year Jan 1 through today.
  """
  def all(opts \\ []) do
    %{
      river:   river_stats(opts),
      prices:  price_stats(opts),
      freight: freight_stats(opts)
    }
  rescue
    _ -> %{river: empty_stats(), prices: empty_stats(), freight: empty_stats()}
  end

  def river_stats(opts \\ []) do
    {from_date, to_date} = date_range(opts)
    base = from(r in RiverStageHistory, where: r.date >= ^from_date and r.date <= ^to_date)
    count = Repo.one(from r in base, select: count())
    {min_d, max_d} = Repo.one(from r in base, select: {min(r.date), max(r.date)}) || {nil, nil}
    recent = Repo.all(from r in base, order_by: [desc: r.date, asc: r.gauge_key], limit: 20)
    %{count: count || 0, min_date: min_d, max_date: max_d, recent: recent}
  rescue
    _ -> empty_stats()
  end

  def price_stats(opts \\ []) do
    {from_date, to_date} = date_range(opts)
    base = from(p in AmmoniaPriceHistory, where: p.date >= ^from_date and p.date <= ^to_date)
    count = Repo.one(from p in base, select: count())
    {min_d, max_d} = Repo.one(from p in base, select: {min(p.date), max(p.date)}) || {nil, nil}
    recent = Repo.all(from p in base, order_by: [desc: p.date, asc: p.benchmark_key], limit: 24)
    %{count: count || 0, min_date: min_d, max_date: max_d, recent: recent}
  rescue
    _ -> empty_stats()
  end

  def freight_stats(opts \\ []) do
    {from_date, to_date} = date_range(opts)
    base = from(f in FreightRateHistory, where: f.date >= ^from_date and f.date <= ^to_date)
    count = Repo.one(from f in base, select: count())
    {min_d, max_d} = Repo.one(from f in base, select: {min(f.date), max(f.date)}) || {nil, nil}
    recent = Repo.all(from f in base, order_by: [desc: f.date, asc: f.route], limit: 20)
    %{count: count || 0, min_date: min_d, max_date: max_d, recent: recent}
  rescue
    _ -> empty_stats()
  end

  # ── helpers ──

  def default_from do
    today = Date.utc_today()
    Date.new!(today.year - 1, 1, 1)
  end

  def default_to, do: Date.utc_today()

  defp date_range(opts) do
    {Keyword.get(opts, :from, default_from()), Keyword.get(opts, :to, default_to())}
  end

  defp empty_stats, do: %{count: 0, min_date: nil, max_date: nil, recent: []}
end
