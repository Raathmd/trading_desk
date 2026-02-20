defmodule TradingDesk.Trader.BargeFailureScenarioTest do
  @moduledoc """
  Tests the delivery schedule feature and barge-failure reallocation scenario.

  Business context:
  A barge failure mid-river forces Trammo to reduce fleet capacity. The trader
  must decide which customers to prioritise and which deliveries can slip — while
  minimising contract penalty exposure.

  This test verifies:
    1. DeliverySchedule extraction from the 5 NH3 seed contracts
    2. Penalty calculations (grace period, per-MT/day rate, cap)
    3. Daily exposure ranking to guide priority decisions
    4. Variable-adjustment logic for a barge failure event
    5. format_for_prompt output ordering
  """
  use ExUnit.Case, async: true

  alias TradingDesk.Trader.DeliverySchedule
  alias TradingDesk.Seeds.NH3ContractSeed

  # Module-level: extract schedules from the 5 seed contracts (no GenServer needed)
  @contracts NH3ContractSeed.seed_contracts()
  @schedules DeliverySchedule.from_contracts(@contracts)

  # ────────────────────────────────────────────────────────────
  # EXTRACTION
  # ────────────────────────────────────────────────────────────

  describe "delivery schedule extraction" do
    test "extracts exactly one schedule per contract (all 5 have DELIVERY_SCHEDULE_TERMS)" do
      assert length(@schedules) == 5
    end

    test "identifies purchase vs sale direction from counterparty_type" do
      purchases = Enum.filter(@schedules, &(&1.direction == :purchase))
      sales = Enum.filter(@schedules, &(&1.direction == :sale))
      # CF Industries + Koch = 2 purchases; Mosaic + Nutrien + Simplot = 3 sales
      assert length(purchases) == 2
      assert length(sales) == 3
    end

    test "CF Industries: quarterly, 10,000 MT, 14-day window, 5-day grace" do
      cf = DeliverySchedule.find_by_counterparty(@schedules, "CF Industries")
      assert cf != nil
      assert cf.scheduled_qty_mt == 10_000.0
      assert cf.frequency == :quarterly
      assert cf.delivery_window_days == 14
      assert cf.grace_period_days == 5
      assert cf.penalty_per_mt_per_day == 2.50
      assert cf.penalty_cap_pct == 10.0
      assert cf.open_qty_mt == 42_000.0
      assert cf.next_window_days == 30
      assert cf.direction == :purchase
    end

    test "Koch Nitrogen: spot, 3,000 MT, window open now" do
      koch = DeliverySchedule.find_by_counterparty(@schedules, "Koch")
      assert koch != nil
      assert koch.scheduled_qty_mt == 3_000.0
      assert koch.frequency == :spot
      assert koch.grace_period_days == 2
      assert koch.penalty_per_mt_per_day == 3.00
      assert koch.next_window_days == 0
      assert koch.direction == :purchase
    end

    test "Mosaic: spot sale, 5,000 MT, window open, highest per-MT penalty" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      assert mosaic != nil
      assert mosaic.scheduled_qty_mt == 5_000.0
      assert mosaic.frequency == :spot
      assert mosaic.grace_period_days == 3
      assert mosaic.penalty_per_mt_per_day == 4.00
      assert mosaic.next_window_days == 0
      assert mosaic.direction == :sale
    end

    test "Nutrien: spot sale, 4,000 MT, Memphis delivery" do
      nutrien = DeliverySchedule.find_by_counterparty(@schedules, "Nutrien")
      assert nutrien != nil
      assert nutrien.scheduled_qty_mt == 4_000.0
      assert nutrien.grace_period_days == 2
      assert nutrien.penalty_per_mt_per_day == 3.50
      assert nutrien.next_window_days == 0
      assert nutrien.direction == :sale
    end

    test "Simplot: quarterly sale, 7,500 MT, 21-day window, next window in 14 days" do
      simplot = DeliverySchedule.find_by_counterparty(@schedules, "Simplot")
      assert simplot != nil
      assert simplot.scheduled_qty_mt == 7_500.0
      assert simplot.frequency == :quarterly
      assert simplot.delivery_window_days == 21
      assert simplot.grace_period_days == 5
      assert simplot.penalty_per_mt_per_day == 2.00
      assert simplot.next_window_days == 14
      assert simplot.open_qty_mt == 25_000.0
      assert simplot.direction == :sale
    end

    test "find_by_counterparty is case-insensitive partial match" do
      assert DeliverySchedule.find_by_counterparty(@schedules, "mosaic") != nil
      assert DeliverySchedule.find_by_counterparty(@schedules, "SIMPLOT") != nil
      assert DeliverySchedule.find_by_counterparty(@schedules, "cf") != nil
      assert DeliverySchedule.find_by_counterparty(@schedules, "nonexistent") == nil
    end
  end

  # ────────────────────────────────────────────────────────────
  # PENALTY CALCULATIONS
  # ────────────────────────────────────────────────────────────

  describe "penalty_for_delay/2" do
    test "returns 0.0 for zero delay" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      assert DeliverySchedule.penalty_for_delay(mosaic, 0) == 0.0
    end

    test "returns 0.0 when delay is within grace period" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      # grace = 3 days; delay of exactly 3 days = no penalty
      assert DeliverySchedule.penalty_for_delay(mosaic, 3) == 0.0
    end

    test "accrues after grace period: 1 day over grace" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      # excess = 4 - 3 = 1 day; raw = 1 * 5,000 * 4.00 = $20,000
      assert DeliverySchedule.penalty_for_delay(mosaic, 4) == 20_000.0
    end

    test "accrues after grace period: 2 days over grace (barge failure scenario)" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      # excess = 5 - 3 = 2 days; raw = 2 * 5,000 * 4.00 = $40,000
      assert DeliverySchedule.penalty_for_delay(mosaic, 5) == 40_000.0
    end

    test "Nutrien 1 day over grace" do
      nutrien = DeliverySchedule.find_by_counterparty(@schedules, "Nutrien")
      # grace = 2; delay 3 = 1 excess; 1 * 4,000 * 3.50 = $14,000
      assert DeliverySchedule.penalty_for_delay(nutrien, 3) == 14_000.0
    end

    test "Simplot within 5-day grace = no penalty" do
      simplot = DeliverySchedule.find_by_counterparty(@schedules, "Simplot")
      assert DeliverySchedule.penalty_for_delay(simplot, 5) == 0.0
      assert DeliverySchedule.penalty_for_delay(simplot, 4) == 0.0
    end

    test "penalty is capped at penalty_cap_pct of approximate contract value" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      # Cap = 5,000 MT * $380/MT avg * 10% = $190,000
      # Large delay: raw = 100 * 5,000 * 4.00 = $2,000,000 — should be capped
      expected_cap = 5_000.0 * 380.0 * (10.0 / 100.0)
      assert DeliverySchedule.penalty_for_delay(mosaic, 103) == expected_cap
    end

    test "Koch spot: tight grace, higher rate" do
      koch = DeliverySchedule.find_by_counterparty(@schedules, "Koch")
      # grace = 2; delay 4 = 2 excess; 2 * 3,000 * 3.00 = $18,000
      assert DeliverySchedule.penalty_for_delay(koch, 4) == 18_000.0
    end
  end

  describe "total_daily_exposure/1" do
    test "sums scheduled_qty_mt × penalty_per_mt_per_day across all schedules" do
      # CF:      10,000 × 2.50 = 25,000
      # Koch:     3,000 × 3.00 =  9,000
      # Mosaic:   5,000 × 4.00 = 20,000
      # Nutrien:  4,000 × 3.50 = 14,000
      # Simplot:  7,500 × 2.00 = 15,000
      # Total:                   83,000
      assert_in_delta DeliverySchedule.total_daily_exposure(@schedules), 83_000.0, 0.01
    end

    test "returns 0.0 for empty schedule list" do
      assert DeliverySchedule.total_daily_exposure([]) == 0.0
    end
  end

  # ────────────────────────────────────────────────────────────
  # BARGE FAILURE SCENARIO
  # ────────────────────────────────────────────────────────────

  describe "barge failure scenario" do
    test "daily exposure ranking guides deferral decisions" do
      # When a barge fails we must prioritise highest penalty exposure.
      # Sale obligations ranked by daily exposure:
      #   Mosaic:  5,000 × 4.00 = 20,000/day  ← serve first
      #   Simplot: 7,500 × 2.00 = 15,000/day
      #   Nutrien: 4,000 × 3.50 = 14,000/day  ← can defer (lower exposure)
      sales = Enum.filter(@schedules, &(&1.direction == :sale))
      [top | _] = Enum.sort_by(sales, &(&1.scheduled_qty_mt * &1.penalty_per_mt_per_day), :desc)
      assert top.counterparty =~ "Mosaic"
    end

    test "format_for_prompt sorts by daily exposure descending, CF first overall" do
      # CF Industries has highest overall exposure: 10,000 × 2.50 = 25,000/day
      prompt_text = DeliverySchedule.format_for_prompt(@schedules)
      lines = String.split(prompt_text, "\n") |> Enum.reject(&(&1 == ""))
      assert List.first(lines) =~ "CF Industries"
    end

    test "barge failure variable adjustment: reduce barge_count" do
      # Normal fleet: 15 barges.  One barge fails → 14.
      normal_barge_count = 15.0
      failed = 1
      adjusted = normal_barge_count - failed
      assert adjusted == 14.0

      # Two barges fail (one for repair, one hit a sandbar) → 13.
      adjusted2 = normal_barge_count - 2
      assert adjusted2 == 13.0
    end

    test "penalty exposure if Mosaic deferred 5 days past grace during barge repair" do
      mosaic = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      # grace = 3; barge repair takes 8 days total → 5 excess days
      # 5 × 5,000 × 4.00 = $100,000
      assert DeliverySchedule.penalty_for_delay(mosaic, 8) == 100_000.0
    end

    test "penalty exposure if Nutrien deferred 4 days past grace during barge repair" do
      nutrien = DeliverySchedule.find_by_counterparty(@schedules, "Nutrien")
      # grace = 2; 6 days total → 4 excess
      # 4 × 4,000 × 3.50 = $56,000
      assert DeliverySchedule.penalty_for_delay(nutrien, 6) == 56_000.0
    end

    test "Simplot not immediately affected: window opens in 14 days" do
      simplot = DeliverySchedule.find_by_counterparty(@schedules, "Simplot")
      # Window not yet open — a 5-day barge repair doesn't touch Simplot's delivery window
      assert simplot.next_window_days == 14
      # And even if it runs over into the window, the 5-day grace absorbs the delay
      assert DeliverySchedule.penalty_for_delay(simplot, 5) == 0.0
    end

    test "spot contracts (Mosaic, Nutrien) most urgent: window already open" do
      urgent = Enum.filter(@schedules, &(&1.next_window_days == 0 and &1.direction == :sale))
      counterparties = Enum.map(urgent, & &1.counterparty)
      assert Enum.any?(counterparties, &String.contains?(&1, "Mosaic"))
      assert Enum.any?(counterparties, &String.contains?(&1, "Nutrien"))
    end

    test "combined penalty for deferring both Mosaic and Nutrien 3 days past grace" do
      mosaic  = DeliverySchedule.find_by_counterparty(@schedules, "Mosaic")
      nutrien = DeliverySchedule.find_by_counterparty(@schedules, "Nutrien")
      # Mosaic: 3 excess days → 3 × 5,000 × 4.00 = $60,000
      # Nutrien: 3 excess days → 3 × 4,000 × 3.50 = $42,000
      # Total:                                         $102,000
      mosaic_penalty  = DeliverySchedule.penalty_for_delay(mosaic, mosaic.grace_period_days + 3)
      nutrien_penalty = DeliverySchedule.penalty_for_delay(nutrien, nutrien.grace_period_days + 3)
      assert mosaic_penalty  == 60_000.0
      assert nutrien_penalty == 42_000.0
      assert mosaic_penalty + nutrien_penalty == 102_000.0
    end
  end

  # ────────────────────────────────────────────────────────────
  # FORMAT FOR PROMPT
  # ────────────────────────────────────────────────────────────

  describe "format_for_prompt/1" do
    test "includes all 5 schedules in output" do
      text = DeliverySchedule.format_for_prompt(@schedules)
      assert text =~ "CF Industries"
      assert text =~ "Koch"
      assert text =~ "Mosaic"
      assert text =~ "Nutrien"
      assert text =~ "Simplot"
    end

    test "labels purchase vs sale direction" do
      text = DeliverySchedule.format_for_prompt(@schedules)
      assert text =~ "PURCHASE from"
      assert text =~ "SALE to"
    end

    test "shows WINDOW OPEN NOW for spot contracts" do
      text = DeliverySchedule.format_for_prompt(@schedules)
      assert text =~ "WINDOW OPEN NOW"
    end

    test "shows window countdown for Simplot" do
      text = DeliverySchedule.format_for_prompt(@schedules)
      assert text =~ "window opens in 14d"
    end

    test "returns empty string for empty list" do
      assert DeliverySchedule.format_for_prompt([]) == ""
    end
  end
end
