defmodule TradingDesk.TradeDB.SolveResultSingle do
  @moduledoc "LP solve result for :solve mode (1:1 with solves)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:solve_id, :string, autogenerate: false}

  schema "solve_results_single" do
    field :status, :string      # "optimal" | "infeasible" | "error"
    field :profit, :float       # total gross profit $
    field :tons, :float         # total tons shipped
    field :barges, :float       # total barges used
    field :cost, :float         # total capital deployed $
    field :roi, :float          # return on capital %
    field :eff_barge, :float    # profit per barge
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_id, :status, :profit, :tons, :barges, :cost, :roi, :eff_barge])
    |> validate_required([:solve_id, :status])
  end
end

defmodule TradingDesk.TradeDB.SolveResultMc do
  @moduledoc "Monte Carlo distribution result for :monte_carlo mode (1:1 with solves)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:solve_id, :string, autogenerate: false}

  schema "solve_results_mc" do
    field :signal, :string        # "strong_go" | "go" | "cautious" | "weak" | "no_go"
    field :n_scenarios, :integer
    field :n_feasible, :integer
    field :n_infeasible, :integer
    field :mean, :float
    field :stddev, :float
    field :p5, :float
    field :p25, :float
    field :p50, :float
    field :p75, :float
    field :p95, :float
    field :min_profit, :float
    field :max_profit, :float
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :solve_id, :signal, :n_scenarios, :n_feasible, :n_infeasible,
      :mean, :stddev, :p5, :p25, :p50, :p75, :p95, :min_profit, :max_profit
    ])
    |> validate_required([:solve_id, :signal])
  end
end

defmodule TradingDesk.TradeDB.SolveResultRoute do
  @moduledoc """
  Per-route breakdown for :solve mode (1:N with solves).

  One row per route that had non-zero allocation.
  Route index maps to: 0=Don→StL, 1=Don→Mem, 2=Geis→StL, 3=Geis→Mem.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "solve_result_routes" do
    field :solve_id, :string
    field :route_index, :integer   # 0-3
    field :origin, :string         # "don" | "geis"
    field :destination, :string    # "stl" | "mem"
    field :tons, :float
    field :profit, :float
    field :margin, :float          # $/ton
    field :transit_days, :float
    field :shadow_price, :float    # dual variable
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_id, :route_index, :origin, :destination,
                    :tons, :profit, :margin, :transit_days, :shadow_price])
    |> validate_required([:solve_id, :route_index])
  end
end

defmodule TradingDesk.TradeDB.SolveMcSensitivity do
  @moduledoc """
  Top driver variables for Monte Carlo result (1:N with solves).

  Pearson correlation of each variable with gross profit across all scenarios.
  Up to 6 rows per solve, ranked by |correlation| descending.
  Positive correlation = higher value → higher profit.
  Negative correlation = higher value → lower profit.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "solve_mc_sensitivity" do
    field :solve_id, :string
    field :variable_key, :string   # e.g. "nola_buy", "river_stage"
    field :correlation, :float     # Pearson r with profit (-1..+1)
    field :rank, :integer          # 1 = highest |correlation|
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_id, :variable_key, :correlation, :rank])
    |> validate_required([:solve_id, :variable_key, :rank])
  end
end

defmodule TradingDesk.TradeDB.AutoSolveTrigger do
  @moduledoc """
  Variables that caused an auto-solve to fire (1:N with solves, auto-runner only).

  Each row records one variable that crossed its configured threshold,
  providing the causal chain: why did the auto-runner re-solve?
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "auto_solve_triggers" do
    field :solve_id, :string
    field :variable_key, :string      # e.g. "nola_buy"
    field :variable_index, :integer   # bit position in triggered_mask
    field :baseline_value, :float     # value at time of last solve
    field :current_value, :float      # value that triggered this solve
    field :threshold, :float          # admin-configured trigger threshold
    field :delta, :float              # current - baseline (signed)
    field :direction, :string         # "up" | "down"
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:solve_id, :variable_key, :variable_index,
                    :baseline_value, :current_value, :threshold, :delta, :direction])
    |> validate_required([:solve_id, :variable_key])
  end
end
