defmodule TradingDesk.TradeDB.Writer do
  @moduledoc """
  Retired SQLite writer — now a no-op stub.

  All solve history is captured in Postgres via TradingDesk.DB.Writer
  (solve_audits, chain_commits, config_change_log). This module is kept
  so call sites compile without changes.
  """

  def persist_solve(_audit),                    do: :ok
  def persist_auto_triggers(_id, _triggers),    do: :ok
  def persist_contract(_contract),              do: :ok
  def persist_config_change(_group, _cfg, _opts \\ []), do: :ok

  @doc """
  Persist a solve result that originated on the mobile device.
  Routes through the same Postgres audit path as server-side solves,
  but marks the trigger as `:mobile`.
  """
  def persist_mobile_solve(attrs) do
    TradingDesk.DB.Writer.persist_mobile_solve(attrs)
  end
end
