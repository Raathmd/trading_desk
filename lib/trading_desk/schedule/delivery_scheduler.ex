defmodule TradingDesk.Schedule.DeliveryScheduler do
  @moduledoc """
  Builds and maintains the forward delivery schedule from SAP contract positions.

  For each open contract, produces a spread of individual delivery lines covering
  the remaining open quantity. Annual contracts spread deliveries monthly;
  spot contracts generate 1–3 deliveries within upcoming weeks.

  The `required_date` on each line is the contractually obligated delivery date.
  The `estimated_date` starts equal to `required_date` and is updated whenever
  a solver run detects conditions that would affect delivery timing (low river
  stage, terminal outages, high lock wait hours, etc.).

  ## Counterparty → destination mapping

  Used to translate SAP counterparty names into route-destination atoms so that
  solver constraints can be applied to the correct subset of lines.
  """

  require Logger

  alias TradingDesk.Contracts.SapPositions
  alias TradingDesk.DB.ScheduledDelivery
  alias TradingDesk.Repo

  import Ecto.Query

  # Maps counterparty name → destination atom for solver constraint routing
  @counterparty_destinations %{
    # ── Sale customers (ammonia domestic) ──
    "Nutrien StL"              => :stl,
    "Koch Fertilizer"          => :stl,
    "Mosaic Company"           => :mem,
    "J.R. Simplot Company"     => :stl,
    "BASF SE"                  => :stl,
    # ── Sale customers (international) ──
    "IFFCO"                    => :intl,
    "OCP Group"                => :intl,
    # ── Purchase suppliers (domestic loading) ──
    "CF Industries Holdings"   => :don,
    "Koch Nitrogen Company"    => :don,
    "LSB Industries"           => :don,
    "Ameropa AG"               => :don,
    # ── Purchase suppliers (international) ──
    "NGC Trinidad"             => :intl,
    "SABIC Agri-Nutrients"     => :intl
  }

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Build the full delivery schedule from SAP positions.

  Returns a list of delivery-line maps sorted by `required_date`. Each map has:
    %{
      id, counterparty, contract_number, sap_contract_id,
      direction (:purchase | :sale), incoterm, product_group,
      quantity_mt, required_date, estimated_date,
      delay_days, status (:on_track | :at_risk | :delayed),
      delivery_index, total_deliveries, destination, notes
    }
  """
  @spec build_schedule() :: [map()]
  def build_schedule do
    {:ok, positions} = SapPositions.fetch_positions()
    today = Date.utc_today()

    positions
    |> Enum.filter(fn {_k, v} -> (v.open_qty_mt || 0) > 0 end)
    |> Enum.flat_map(fn {counterparty, position} ->
      generate_delivery_lines(counterparty, position, today)
    end)
    |> Enum.sort_by(& &1.required_date)
  rescue
    e ->
      Logger.error("DeliveryScheduler.build_schedule failed: #{Exception.message(e)}")
      []
  end

  @doc """
  Apply solver result to the delivery schedule, adjusting `estimated_date` and
  `status` based on detected constraints and current variable values.

  Returns an updated list of delivery lines.
  """
  @spec apply_solver_result([map()], map(), [String.t()], map()) :: [map()]
  def apply_solver_result(lines, result, _route_names \\ [], vars \\ %{}) do
    Enum.map(lines, &apply_constraints_to_line(&1, result, vars))
  end

  @doc """
  Generate a Claude AI summary of the delivery schedule.

  Runs asynchronously—call from a spawned process and send the result back to
  the LiveView PID. Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec ai_summary([map()]) :: {:ok, String.t()} | {:error, any()}
  def ai_summary(lines) do
    prompt = build_summary_prompt(lines)
    TradingDesk.Analyst.prompt(prompt, max_tokens: 700)
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Contract-based schedule generation (persisted to DB) ─────────────────

  @doc """
  Generate and persist scheduled deliveries for an ingested contract.

  Creates delivery lines based on the contract's open position and term type,
  links them to the contract via `contract_id` and `contract_hash` (file SHA-256).

  If deliveries already exist for this contract_hash, they are skipped (idempotent).
  """
  @spec generate_from_contract(map()) :: {:ok, [map()]} | {:error, term()}
  def generate_from_contract(%{} = contract) do
    contract_hash = contract.file_hash

    unless contract_hash do
      {:error, :no_file_hash}
    else
      # Skip if deliveries already exist for this hash
      existing = Repo.aggregate(
        from(sd in ScheduledDelivery, where: sd.contract_hash == ^contract_hash),
        :count
      )

      if existing > 0 do
        {:ok, []}
      else
        open_qty = contract.open_position || 0.0

        if open_qty <= 0 do
          {:ok, []}
        else
          today = Date.utc_today()
          term_type = to_string(contract.term_type || :spot)
          direction = to_string(contract.template_type || contract.counterparty_type)

          # Determine direction string
          dir = cond do
            direction in ["purchase", "spot_purchase", "supplier"] -> "purchase"
            true -> "sale"
          end

          lines = case term_type do
            "long_term" -> spread_annual(open_qty, today, contract)
            _ -> spread_spot(open_qty, today, contract)
          end

          now = DateTime.utc_now() |> DateTime.truncate(:second)
          dest = Map.get(@counterparty_destinations, contract.counterparty, :unknown)

          records =
            lines
            |> Enum.with_index(1)
            |> Enum.map(fn {{date, qty}, idx} ->
              %{
                contract_id: contract.id,
                contract_hash: contract_hash,
                counterparty: contract.counterparty,
                contract_number: contract.contract_number,
                sap_contract_id: contract.sap_contract_id,
                direction: dir,
                product_group: to_string(contract.product_group),
                incoterm: if(contract.incoterm, do: to_string(contract.incoterm)),
                quantity_mt: Float.round(qty * 1.0, 0),
                required_date: date,
                estimated_date: date,
                delay_days: 0,
                status: "on_track",
                delivery_index: idx,
                total_deliveries: length(lines),
                destination: to_string(dest),
                notes: nil,
                inserted_at: now,
                updated_at: now
              }
            end)

          {count, _} = Repo.insert_all(ScheduledDelivery, records)

          Logger.info(
            "DeliveryScheduler: generated #{count} delivery lines for " <>
            "#{contract.counterparty} (hash=#{String.slice(contract_hash, 0, 12)}...)"
          )

          {:ok, records}
        end
      end
    end
  rescue
    e ->
      Logger.error("DeliveryScheduler.generate_from_contract failed: #{Exception.message(e)}")
      {:error, e}
  end

  @doc """
  List all persisted scheduled deliveries for a product group.
  """
  @spec list_deliveries(atom()) :: [map()]
  def list_deliveries(product_group) do
    pg = to_string(product_group)

    from(sd in ScheduledDelivery,
      where: sd.product_group == ^pg,
      order_by: [asc: sd.required_date]
    )
    |> Repo.all()
  end

  defp spread_annual(open_qty, today, contract) do
    months = remaining_months(today)
    n = max(length(months), 1)
    qtys = spread_quantities(open_qty / n, n, contract.contract_number || "unknown")
    Enum.zip(months, qtys)
  end

  defp spread_spot(open_qty, today, contract) do
    n = cond do
      open_qty > 15_000 -> 3
      open_qty > 5_000  -> 2
      true              -> 1
    end
    dates = spot_dates(today, n, contract.contract_number || "unknown")
    qtys = spread_quantities(open_qty / n, n, contract.contract_number || "unknown")
    Enum.zip(dates, qtys)
  end

  # ── Private — line generation ─────────────────────────────────────────────

  defp generate_delivery_lines(counterparty, position, today) do
    case position.period do
      :annual -> generate_annual_deliveries(counterparty, position, today)
      :spot   -> generate_spot_deliveries(counterparty, position, today)
      _       -> generate_spot_deliveries(counterparty, position, today)
    end
  end

  defp generate_annual_deliveries(counterparty, position, today) do
    open_qty = position.open_qty_mt || 0.0
    months   = remaining_months(today)

    if months == [] or open_qty <= 0 do
      []
    else
      qtys = spread_quantities(open_qty / length(months), length(months), position.contract_number)

      months
      |> Enum.zip(qtys)
      |> Enum.with_index(1)
      |> Enum.map(fn {{date, qty}, idx} ->
        build_line(counterparty, position, qty, date, idx, length(months))
      end)
    end
  end

  defp generate_spot_deliveries(counterparty, position, today) do
    open_qty = position.open_qty_mt || 0.0

    if open_qty <= 0 do
      []
    else
      n = cond do
        open_qty > 15_000 -> 3
        open_qty > 5_000  -> 2
        true              -> 1
      end

      dates = spot_dates(today, n, position.contract_number)
      qtys  = spread_quantities(open_qty / n, n, position.contract_number)

      dates
      |> Enum.zip(qtys)
      |> Enum.with_index(1)
      |> Enum.map(fn {{date, qty}, idx} ->
        build_line(counterparty, position, qty, date, idx, n)
      end)
    end
  end

  defp build_line(counterparty, position, qty_mt, required_date, idx, total) do
    dest = Map.get(@counterparty_destinations, counterparty, :unknown)
    # Simulate SAP record dates: created when contract was set up (a few weeks back),
    # updated recently. In a real integration these come from the SAP API.
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    sap_created = DateTime.add(now, -(:rand.uniform(30) * 86400), :second)
    sap_updated = DateTime.add(now, -(:rand.uniform(7) * 86400), :second)

    %{
      id:               "#{position.contract_number}-#{String.pad_leading("#{idx}", 2, "0")}",
      counterparty:     counterparty,
      contract_number:  position.contract_number,
      sap_contract_id:  position.sap_contract_id,
      direction:        position.direction,
      incoterm:         position.incoterm,
      product_group:    position.product_group,
      quantity_mt:      Float.round(qty_mt * 1.0, 0),
      required_date:    required_date,
      estimated_date:   required_date,
      delay_days:       0,
      status:           :on_track,
      delivery_status:  :open,
      delivery_index:   idx,
      total_deliveries: total,
      destination:      dest,
      notes:            nil,
      sap_created_at:   sap_created,
      sap_updated_at:   sap_updated
    }
  end

  # ── Private — date helpers ────────────────────────────────────────────────

  # Returns the 28th of each month from next month through December of today's year.
  defp remaining_months(today) do
    start_month = today.month + 1

    if start_month > 12 do
      []
    else
      Enum.map(start_month..12, fn month ->
        Date.new!(today.year, month, 28)
      end)
    end
  end

  # Returns n dates for spot deliveries, starting ~14-21 days from today.
  # Offset is deterministic per contract so it doesn't shift on each render.
  defp spot_dates(today, n, contract_number) do
    base_offset = 14 + rem(:erlang.phash2(contract_number, 100), 8)

    Enum.map(0..(n - 1), fn i ->
      Date.add(today, base_offset + i * 14)
    end)
  end

  # ── Private — quantity spread ─────────────────────────────────────────────

  # Distribute base_qty × n with ±15% variance per slot.
  # Uses a deterministic hash so quantities are stable across renders.
  defp spread_quantities(base_qty, n, contract_number) do
    raw =
      Enum.map(0..(n - 1), fn i ->
        h = :erlang.phash2("#{contract_number}-#{i}", 1000)
        # rem(h, 301) ∈ [0, 300] → subtract 150 → [-150, +150]
        variance_pct = (rem(h, 301) - 150) / 1000.0
        max(100.0, base_qty * (1.0 + variance_pct))
      end)

    total_raw  = Enum.sum(raw)
    target     = base_qty * n

    if total_raw > 0 do
      Enum.map(raw, fn v -> Float.round(v / total_raw * target, 0) end)
    else
      List.duplicate(Float.round(base_qty, 0), n)
    end
  end

  # ── Private — solver constraint application ───────────────────────────────

  defp apply_constraints_to_line(line, result, vars) do
    if result.status != :optimal do
      # Solver could not find a feasible solution — flag all lines at risk
      %{line |
        status:         :at_risk,
        estimated_date: Date.add(line.required_date, 7),
        delay_days:     7,
        notes:          "Solver infeasible — delivery timing uncertain"
      }
    else
      delay  = calculate_delay(line, vars)
      status = cond do
        delay == 0 -> :on_track
        delay <= 7 -> :at_risk
        true       -> :delayed
      end

      %{line |
        estimated_date: Date.add(line.required_date, delay),
        delay_days:     delay,
        status:         status,
        notes:          if(delay > 0, do: build_delay_note(line.destination, vars), else: nil)
      }
    end
  end

  defp calculate_delay(line, vars) do
    dest        = line.destination
    river_stage = to_float(Map.get(vars, :river_stage, 12.0))
    lock_hrs    = to_float(Map.get(vars, :lock_hrs, 24.0))
    mer_outage  = truthy?(Map.get(vars, :mer_outage, false))
    nio_outage  = truthy?(Map.get(vars, :nio_outage, false))

    river_delay = if dest in [:stl, :mem, :don] and river_stage < 9.0, do: 7, else: 0
    lock_delay  = if dest in [:stl, :mem] and lock_hrs > 48.0, do: trunc((lock_hrs - 24) / 24), else: 0
    stl_delay   = if dest == :stl and mer_outage, do: 14, else: 0
    mem_delay   = if dest == :mem and nio_outage, do: 14, else: 0

    river_delay + lock_delay + stl_delay + mem_delay
  end

  defp build_delay_note(dest, vars) do
    river_stage = to_float(Map.get(vars, :river_stage, 12.0))
    lock_hrs    = to_float(Map.get(vars, :lock_hrs, 24.0))
    mer_outage  = truthy?(Map.get(vars, :mer_outage, false))
    nio_outage  = truthy?(Map.get(vars, :nio_outage, false))

    reasons =
      [
        if(dest in [:stl, :mem, :don] and river_stage < 9.0,
          do: "low river (#{:erlang.float_to_binary(river_stage, decimals: 1)}ft)"),
        if(dest == :stl and mer_outage, do: "Meredosia terminal outage"),
        if(dest == :mem and nio_outage,  do: "Niota terminal outage"),
        if(dest in [:stl, :mem] and lock_hrs > 48.0,
          do: "high lock wait (#{trunc(lock_hrs)}hrs)")
      ]
      |> Enum.reject(&is_nil/1)

    if reasons == [], do: nil, else: "Delayed: " <> Enum.join(reasons, ", ")
  end

  # ── Private — Claude prompt ───────────────────────────────────────────────

  defp build_summary_prompt(lines) do
    today = Date.utc_today()

    sales     = Enum.filter(lines, &(&1.direction == :sale))
    purchases = Enum.filter(lines, &(&1.direction == :purchase))
    at_risk   = Enum.filter(lines, &(&1.status in [:at_risk, :delayed]))

    total_sale_mt     = sales     |> Enum.map(& &1.quantity_mt) |> Enum.sum() |> round()
    total_purchase_mt = purchases |> Enum.map(& &1.quantity_mt) |> Enum.sum() |> round()

    line_details =
      lines
      |> Enum.map(fn l ->
        dir       = if l.direction == :purchase, do: "PURCHASE from", else: "SALE to"
        delay_str = if l.delay_days > 0, do: " (+#{l.delay_days}d delay)", else: ""
        note_str  = if l.notes, do: " — #{l.notes}", else: ""

        "• #{dir} #{l.counterparty}: #{round(l.quantity_mt)} MT, " <>
        "required #{l.required_date}, estimated #{l.estimated_date}" <>
        "#{delay_str}, #{l.status}#{note_str}"
      end)
      |> Enum.join("\n")

    """
    You are a senior commodities trade analyst at Trammo, a global fertilizer \
    and ammonia trading firm. Today is #{today}.

    Summarize the ammonia forward delivery schedule below in exactly 5 concise \
    bullet points using • as the bullet character. Cover:
      1. Overall schedule health — how many deliveries are on-track vs at-risk
      2. Most urgent risk item requiring trader attention (counterparty and date)
      3. Purchase-side volume summary (suppliers, total MT remaining)
      4. Sale-side volume summary (customers, total MT remaining)
      5. One specific recommended action the trader should take today

    SCHEDULE OVERVIEW:
    - #{length(lines)} total delivery lines
    - Sale deliveries: #{total_sale_mt} MT across #{length(sales)} shipments
    - Purchase deliveries: #{total_purchase_mt} MT across #{length(purchases)} shipments
    - At-risk or delayed: #{length(at_risk)} of #{length(lines)}

    INDIVIDUAL DELIVERIES:
    #{line_details}

    Be specific: name counterparties, dates, and quantities. Each bullet must be \
    1–2 sentences. Do not add headers or extra formatting beyond the bullet points.
    """
  end

  # ── Private — type helpers ────────────────────────────────────────────────

  defp to_float(v) when is_float(v),   do: v
  defp to_float(v) when is_integer(v), do: v * 1.0
  defp to_float(_),                    do: 0.0

  defp truthy?(true),  do: true
  defp truthy?(1),     do: true
  defp truthy?(1.0),   do: true
  defp truthy?("true"), do: true
  defp truthy?(_),     do: false
end
