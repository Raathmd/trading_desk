defmodule TradingDesk.Trader.DeliverySchedule do
  @moduledoc """
  Delivery schedule extracted from a contract's DELIVERY_SCHEDULE_TERMS clause.

  Each active contract carries one DELIVERY_SCHEDULE_TERMS clause that encodes:
    - how often deliveries are required
    - what volume per delivery window
    - the grace period before penalties accrue
    - the penalty rate per MT per day

  This struct is used by the IntentMapper to build delivery context for Claude,
  and by the solver pipeline to calculate penalty exposure when a trader scenario
  changes the allocation plan.

  ## Penalty calculation

  If a delivery of `scheduled_qty_mt` tonnes is delayed by `d` days beyond
  `grace_period_days`, the exposure is:

      penalty = min(
        (d - grace_period_days) × scheduled_qty_mt × penalty_per_mt_per_day,
        scheduled_qty_mt × avg_price × penalty_cap_pct / 100
      )

  ## Usage

      schedules = DeliverySchedule.from_contracts(active_contracts)
      DeliverySchedule.format_for_prompt(schedules)  # → string for Claude prompt
      DeliverySchedule.total_daily_exposure(schedules)  # → total $/day at risk
  """

  defstruct [
    :counterparty,
    :contract_number,
    :direction,              # :purchase | :sale
    :scheduled_qty_mt,       # MT per delivery window
    :frequency,              # :spot | :monthly | :quarterly | :annual
    :delivery_window_days,   # days the loading/delivery window stays open
    :grace_period_days,      # days of tolerance before penalty clock starts
    :penalty_per_mt_per_day, # $/MT/day after grace period
    :penalty_cap_pct,        # max penalty as % of contract value (e.g. 10 = 10%)
    :open_qty_mt,            # current open position from SAP (remaining to deliver)
    :next_window_days        # days until next delivery window opens (0 = open now)
  ]

  @type t :: %__MODULE__{
    counterparty: String.t(),
    contract_number: String.t() | nil,
    direction: :purchase | :sale,
    scheduled_qty_mt: float(),
    frequency: atom(),
    delivery_window_days: non_neg_integer(),
    grace_period_days: non_neg_integer(),
    penalty_per_mt_per_day: float(),
    penalty_cap_pct: float(),
    open_qty_mt: float(),
    next_window_days: non_neg_integer()
  }

  # ──────────────────────────────────────────────────────────
  # EXTRACTION
  # ──────────────────────────────────────────────────────────

  @doc """
  Extract delivery schedules from a list of active contracts.

  Returns one `%DeliverySchedule{}` per contract that has a
  `DELIVERY_SCHEDULE_TERMS` clause. Contracts without this clause are skipped.
  """
  @spec from_contracts([map()]) :: [t()]
  def from_contracts(contracts) do
    contracts
    |> Enum.map(&from_contract/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Extract delivery schedule from a single contract. Returns nil if the contract
  has no DELIVERY_SCHEDULE_TERMS clause.
  """
  @spec from_contract(map()) :: t() | nil
  def from_contract(contract) do
    clause = Enum.find(contract.clauses || [], fn c ->
      c.clause_id == "DELIVERY_SCHEDULE_TERMS" and c.type == :delivery
    end)

    if clause do
      f = clause.extracted_fields || %{}

      %__MODULE__{
        counterparty:            contract.counterparty,
        contract_number:         contract.contract_number,
        direction:               if(contract.counterparty_type == :supplier, do: :purchase, else: :sale),
        scheduled_qty_mt:        Map.get(f, "scheduled_qty_mt", 0.0),
        frequency:               Map.get(f, "frequency", "spot") |> maybe_atomize(),
        delivery_window_days:    Map.get(f, "delivery_window_days", 14),
        grace_period_days:       Map.get(f, "grace_period_days", 3),
        penalty_per_mt_per_day:  Map.get(f, "penalty_per_mt_per_day", 0.0),
        penalty_cap_pct:         Map.get(f, "penalty_cap_pct", 10.0),
        open_qty_mt:             contract.open_position || 0.0,
        next_window_days:        Map.get(f, "next_window_days", 0)
      }
    end
  end

  # ──────────────────────────────────────────────────────────
  # PENALTY CALCULATIONS
  # ──────────────────────────────────────────────────────────

  @doc """
  Total $/day penalty exposure if ALL deliveries slip past their grace period
  by one additional day. This is the marginal daily exposure across the book.
  """
  @spec total_daily_exposure([t()]) :: float()
  def total_daily_exposure(schedules) do
    Enum.reduce(schedules, 0.0, fn s, acc ->
      acc + (s.scheduled_qty_mt || 0.0) * (s.penalty_per_mt_per_day || 0.0)
    end)
  end

  @doc """
  Estimate penalty exposure for a specific delivery delayed by `delay_days`
  beyond the contract's grace period.

  Returns 0.0 if the delay is within the grace period.
  """
  @spec penalty_for_delay(t(), non_neg_integer()) :: float()
  def penalty_for_delay(%__MODULE__{} = schedule, delay_days) do
    excess = max(0, delay_days - schedule.grace_period_days)
    if excess == 0 do
      0.0
    else
      raw = excess * schedule.scheduled_qty_mt * schedule.penalty_per_mt_per_day
      # Cap is percentage of contract value — approximate at $380/MT average
      cap = schedule.scheduled_qty_mt * 380.0 * (schedule.penalty_cap_pct / 100.0)
      min(raw, cap)
    end
  end

  @doc """
  Find the schedule for a specific counterparty (case-insensitive partial match).
  """
  @spec find_by_counterparty([t()], String.t()) :: t() | nil
  def find_by_counterparty(schedules, name) do
    target = String.downcase(name)
    Enum.find(schedules, fn s ->
      String.contains?(String.downcase(s.counterparty), target)
    end)
  end

  # ──────────────────────────────────────────────────────────
  # FORMATTING (for Claude API prompt)
  # ──────────────────────────────────────────────────────────

  @doc """
  Format delivery schedules as a human-readable string for inclusion in the
  Claude IntentMapper prompt. Sorted by daily penalty exposure descending
  so the highest-risk schedules appear first.
  """
  @spec format_for_prompt([t()]) :: String.t()
  def format_for_prompt(schedules) do
    schedules
    |> Enum.sort_by(&daily_exposure/1, :desc)
    |> Enum.map_join("\n", fn s ->
      dir = if s.direction == :purchase, do: "PURCHASE from", else: "SALE to"
      daily = daily_exposure(s)
      status = if s.next_window_days == 0, do: "WINDOW OPEN NOW", else: "window opens in #{s.next_window_days}d"

      "- #{dir} #{s.counterparty} (#{s.contract_number}): " <>
      "#{s.scheduled_qty_mt} MT #{s.frequency}, " <>
      "#{s.delivery_window_days}-day window, " <>
      "#{s.grace_period_days}-day grace, " <>
      "$#{:erlang.float_to_binary(s.penalty_per_mt_per_day, decimals: 2)}/MT/day penalty " <>
      "($#{round(daily)}/day total), " <>
      "#{s.open_qty_mt} MT open, #{status}"
    end)
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE
  # ──────────────────────────────────────────────────────────

  defp daily_exposure(%__MODULE__{scheduled_qty_mt: q, penalty_per_mt_per_day: p}) do
    (q || 0.0) * (p || 0.0)
  end

  defp maybe_atomize(s) when is_binary(s), do: String.to_atom(s)
  defp maybe_atomize(a) when is_atom(a), do: a
  defp maybe_atomize(_), do: :spot
end
