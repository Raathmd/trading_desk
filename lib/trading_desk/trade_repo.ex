defmodule TradingDesk.TradeRepo do
  @moduledoc """
  SQLite repository for the portable trade history database.

  This is the third persistence layer alongside the WAL snapshot log and
  Postgres. Its purpose is different from the operational Postgres DB:

    - **Self-contained**: a single .db file — easy to backup, version, copy
    - **Chain-restorable**: every row can be reconstructed from BSV blockchain
      OP_RETURN data if the file is lost (stub until chain is live)
    - **Complete history**: stores every solve with full variable snapshots,
      route-level results, SAP contract data, and trigger causation chains
    - **Audit trail**: traders and the auto-runner both write here, making the
      file a chronological record of every trading decision

  ## Schema overview

    - `solves`               — every solve execution (auto + manual)
    - `solve_variables`      — all 20 variable values at solve time (1:1)
    - `solve_variable_sources` — API fetch timestamps per variable (1:1)
    - `solve_delta_config`   — thresholds active at solve time (1:1)
    - `solve_results_single` — LP result: profit, tons, barges, ROI (1:1)
    - `solve_result_routes`  — per-route breakdown, origin→dest (1:N)
    - `solve_results_mc`     — Monte Carlo distribution + signal (1:1)
    - `solve_mc_sensitivity` — top driver variables by correlation (1:N)
    - `auto_solve_triggers`  — which variable crossed threshold + delta (1:N)
    - `trade_contracts`      — full contract data including SAP fields (versioned)
    - `trade_contract_clauses` — normalized extracted clauses (1:N)
    - `solve_contracts`      — contracts active during each solve (N:M join)
    - `chain_commit_log`     — blockchain commit queue (pending until chain live)
    - `config_change_history` — audit log of threshold/config changes

  ## Recovery

  If the .db file is lost, run `TradingDesk.TradeDB.Restore.from_chain/0`
  once the JungleBus sync is implemented — it will replay OP_RETURN payloads
  in order and reconstruct all rows.
  """

  use Ecto.Repo,
    otp_app: :trading_desk,
    adapter: Ecto.Adapters.SQLite3
end
