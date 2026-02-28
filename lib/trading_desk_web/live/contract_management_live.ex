defmodule TradingDesk.ContractManagementLive do
  @moduledoc """
  Contract Management wizard — a 7-step guided workflow for creating
  and approving commodity trading contracts.

  Steps:
    1. PRODUCT GROUP  — select the product group for this contract
    2. COUNTERPARTY   — counterparty name, commodity, delivery window
    3. COMMERCIAL     — quantity, price, freight, payment terms
    4. CLAUSES        — select applicable contract clauses
    5. OPTIMIZER      — HiGHS solver validation + Claude explanation
    6. REVIEW         — full summary of all entered data
    7. APPROVAL       — submit for approval, creates contract record
  """
  use Phoenix.LiveView
  require Logger

  import Ecto.Query

  alias TradingDesk.Repo
  alias TradingDesk.ProductGroup
  alias TradingDesk.EventEmitter
  alias TradingDesk.Solver.Port, as: Solver
  alias TradingDesk.ContractManagement.{
    CmContractNegotiation,
    CmContractNegotiationEvent,
    CmContract,
    CmContractVersion,
    CmContractApproval
  }

  @step_labels %{
    1 => "Product Group Selection",
    2 => "Counterparty & Commodity",
    3 => "Commercial Terms",
    4 => "Clause Selection",
    5 => "Optimizer Validation",
    6 => "Review Summary",
    7 => "Approval Submission",
    8 => "Contract Ingestion"
  }

  @total_steps 8

  @seed_dir "priv/contracts/seed"

  @product_groups [
    {"ammonia_domestic", "NH3 Domestic Barge"},
    {"sulphur_international", "Sulphur International"},
    {"petcoke", "Petcoke"},
    {"ammonia_international", "NH3 International"}
  ]

  @commodity_options %{
    "ammonia_domestic" => ["Anhydrous Ammonia", "Aqua Ammonia"],
    "sulphur_international" => ["Sulphur (Granular)", "Sulphur (Liquid)", "Sulphur (Formed)"],
    "petcoke" => ["Fuel-Grade Petcoke", "Anode-Grade Petcoke", "Calcined Petcoke"],
    "ammonia_international" => ["Anhydrous Ammonia", "Ammonia Solution"]
  }

  @default_clauses [
    %{id: "force_majeure", label: "Force Majeure", description: "Standard force majeure clause covering acts of God, war, and government actions"},
    %{id: "demurrage", label: "Demurrage & Dispatch", description: "Vessel/barge demurrage rates and dispatch rebate terms"},
    %{id: "quality_spec", label: "Quality Specification", description: "Product quality requirements, testing methods, and rejection criteria"},
    %{id: "quantity_tolerance", label: "Quantity Tolerance", description: "+/- 5% quantity tolerance at seller's option"},
    %{id: "price_escalation", label: "Price Escalation", description: "Index-linked price adjustment mechanism"},
    %{id: "payment_terms", label: "Payment Terms", description: "Net 30 days from bill of lading date"},
    %{id: "insurance", label: "Insurance & Liability", description: "Marine cargo insurance requirements and liability limits"},
    %{id: "dispute_resolution", label: "Dispute Resolution", description: "Arbitration clause — LCIA London or ICC Paris"},
    %{id: "termination", label: "Termination Rights", description: "Early termination triggers and notice requirements"},
    %{id: "confidentiality", label: "Confidentiality", description: "Non-disclosure of contract terms and pricing"}
  ]

  @payment_term_options ["Net 30", "Net 45", "Net 60", "Prepayment", "LC at Sight", "LC 30 Days", "LC 60 Days"]

  @incoterm_options ["FOB", "CFR", "CIF", "DAP", "DDP", "FCA", "EXW"]

  # ── Mount ────────────────────────────────────────────────

  @impl true
  def mount(_params, session, socket) do
    current_user_email = Map.get(session, "authenticated_email")

    socket =
      socket
      |> assign(:current_user_email, current_user_email)
      |> assign(:current_step, 1)
      |> assign(:total_steps, @total_steps)
      |> assign(:step_labels, @step_labels)
      |> assign(:product_groups, @product_groups)
      |> assign(:commodity_options, @commodity_options)
      |> assign(:clauses, @default_clauses)
      |> assign(:payment_term_options, @payment_term_options)
      |> assign(:incoterm_options, @incoterm_options)
      # Step 1
      |> assign(:selected_product_group, nil)
      # Step 2
      |> assign(:counterparty, "")
      |> assign(:commodity, "")
      |> assign(:delivery_window_start, "")
      |> assign(:delivery_window_end, "")
      # Step 3
      |> assign(:quantity, "")
      |> assign(:quantity_unit, "MT")
      |> assign(:proposed_price, "")
      |> assign(:proposed_freight, "")
      |> assign(:payment_term, "Net 30")
      |> assign(:incoterm, "FOB")
      # Step 4
      |> assign(:selected_clauses, MapSet.new(["force_majeure", "payment_terms"]))
      # Step 5
      |> assign(:optimizer_result, nil)
      |> assign(:optimizer_running, false)
      |> assign(:optimizer_explanation, nil)
      # Step 7
      |> assign(:negotiation_id, nil)
      |> assign(:contract_id, nil)
      |> assign(:submission_status, nil)
      |> assign(:submission_error, nil)
      |> assign(:flash_msg, nil)
      # Step 8 — Contract Ingestion
      |> assign(:saved_contract_path, nil)
      |> assign(:ingestion_status, nil)
      |> assign(:ingestion_result, nil)
      |> assign(:ingestion_error, nil)

    {:ok, socket}
  end

  # ── Render ───────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div style="min-height:100vh;background:#080c14;color:#c8d6e5;font-family:'JetBrains Mono',monospace;padding:24px">
      <%!-- Header --%>
      <div style="display:flex;align-items:center;justify-content:space-between;margin-bottom:24px">
        <h1 style="font-size:22px;font-weight:700;color:#e2e8f0;margin:0">
          CONTRACT MANAGEMENT
        </h1>
        <span style="font-size:12px;color:#64748b">
          Step {@current_step} of {@total_steps} — {@step_labels[@current_step]}
        </span>
      </div>

      <%!-- Progress Bar --%>
      <div style="margin-bottom:32px">
        <div style="display:flex;gap:4px;margin-bottom:8px">
          <%= for step <- 1..@total_steps do %>
            <div style={"flex:1;height:6px;border-radius:3px;background:#{progress_color(step, @current_step)}"}></div>
          <% end %>
        </div>
        <div style="display:flex;justify-content:space-between;font-size:10px;color:#64748b">
          <span>Product</span>
          <span>Party</span>
          <span>Terms</span>
          <span>Clauses</span>
          <span>Optimize</span>
          <span>Review</span>
          <span>Approve</span>
          <span>Ingest</span>
        </div>
      </div>

      <%!-- Flash message --%>
      <%= if @flash_msg do %>
        <div style="background:#10b98122;border:1px solid #10b981;border-radius:6px;padding:12px 16px;margin-bottom:16px;color:#10b981;font-size:13px">
          {@flash_msg}
        </div>
      <% end %>

      <%!-- Step Content --%>
      <div style="background:#0d1117;border:1px solid #1e293b;border-radius:8px;padding:32px;min-height:400px">
        <%= case @current_step do %>
          <% 1 -> %> <%= render_step_1(assigns) %>
          <% 2 -> %> <%= render_step_2(assigns) %>
          <% 3 -> %> <%= render_step_3(assigns) %>
          <% 4 -> %> <%= render_step_4(assigns) %>
          <% 5 -> %> <%= render_step_5(assigns) %>
          <% 6 -> %> <%= render_step_6(assigns) %>
          <% 7 -> %> <%= render_step_7(assigns) %>
          <% 8 -> %> <%= render_step_8(assigns) %>
          <% _ -> %> <div>Unknown step</div>
        <% end %>
      </div>

      <%!-- Navigation Buttons --%>
      <div style="display:flex;justify-content:space-between;margin-top:24px">
        <div>
          <%= if @current_step > 1 and @current_step < 8 do %>
            <button
              phx-click="back"
              style="background:#1e293b;color:#c8d6e5;border:1px solid #334155;border-radius:6px;padding:10px 24px;cursor:pointer;font-family:inherit;font-size:13px"
            >
              &larr; Back
            </button>
          <% end %>
        </div>
        <div>
          <%= if @current_step < 7 do %>
            <button
              phx-click="next"
              style="background:#2563eb;color:#ffffff;border:none;border-radius:6px;padding:10px 24px;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600"
            >
              Next &rarr;
            </button>
          <% end %>
          <%= if @current_step == 7 && @submission_status != :submitted do %>
            <button
              phx-click="submit_for_approval"
              style="background:#10b981;color:#ffffff;border:none;border-radius:6px;padding:10px 24px;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600"
            >
              Submit for Approval
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Step Renderers ───────────────────────────────────────

  defp render_step_1(assigns) do
    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Select Product Group
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Choose the product group for this contract negotiation.
      </p>

      <div style="display:grid;grid-template-columns:repeat(2,1fr);gap:16px">
        <%= for {id, label} <- @product_groups do %>
          <div
            phx-click="select_product_group"
            phx-value-group={id}
            style={"background:#{if @selected_product_group == id, do: "#2563eb22", else: "#080c14"};border:2px solid #{if @selected_product_group == id, do: "#2563eb", else: "#1e293b"};border-radius:8px;padding:24px;cursor:pointer;transition:all 0.15s"}
          >
            <div style="font-size:15px;font-weight:600;color:#e2e8f0;margin-bottom:4px">
              {label}
            </div>
            <div style="font-size:12px;color:#64748b">
              {id}
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_step_2(assigns) do
    commodities = Map.get(assigns.commodity_options, assigns.selected_product_group, [])
    assigns = assign(assigns, :available_commodities, commodities)

    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Counterparty & Commodity
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Identify the counterparty and commodity for this contract.
      </p>

      <form phx-change="update_step2">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Counterparty Name
            </label>
            <input
              type="text"
              name="counterparty"
              value={@counterparty}
              placeholder="e.g. ACME Trading Corp"
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            />
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Commodity
            </label>
            <select
              name="commodity"
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            >
              <option value="">Select commodity...</option>
              <%= for c <- @available_commodities do %>
                <option value={c} selected={@commodity == c}>{c}</option>
              <% end %>
            </select>
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Delivery Window Start
            </label>
            <input
              type="date"
              name="delivery_window_start"
              value={@delivery_window_start}
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            />
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Delivery Window End
            </label>
            <input
              type="date"
              name="delivery_window_end"
              value={@delivery_window_end}
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            />
          </div>
        </div>
      </form>
    </div>
    """
  end

  defp render_step_3(assigns) do
    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Commercial Terms
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Define quantity, pricing, and trade terms.
      </p>

      <form phx-change="update_step3">
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Quantity
            </label>
            <div style="display:flex;gap:8px">
              <input
                type="number"
                name="quantity"
                value={@quantity}
                placeholder="e.g. 5000"
                step="0.01"
                style="flex:1;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px"
              />
              <select
                name="quantity_unit"
                style="width:80px;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 8px;color:#c8d6e5;font-family:inherit;font-size:13px"
              >
                <option value="MT" selected={@quantity_unit == "MT"}>MT</option>
                <option value="KT" selected={@quantity_unit == "KT"}>KT</option>
                <option value="BBL" selected={@quantity_unit == "BBL"}>BBL</option>
              </select>
            </div>
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Proposed Price (USD)
            </label>
            <input
              type="number"
              name="proposed_price"
              value={@proposed_price}
              placeholder="e.g. 450.00"
              step="0.01"
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            />
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Proposed Freight (USD/MT)
            </label>
            <input
              type="number"
              name="proposed_freight"
              value={@proposed_freight}
              placeholder="e.g. 35.00"
              step="0.01"
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            />
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Payment Terms
            </label>
            <select
              name="payment_term"
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            >
              <%= for opt <- @payment_term_options do %>
                <option value={opt} selected={@payment_term == opt}>{opt}</option>
              <% end %>
            </select>
          </div>

          <div>
            <label style="display:block;font-size:12px;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px">
              Incoterm
            </label>
            <select
              name="incoterm"
              style="width:100%;background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:10px 12px;color:#c8d6e5;font-family:inherit;font-size:13px;box-sizing:border-box"
            >
              <%= for opt <- @incoterm_options do %>
                <option value={opt} selected={@incoterm == opt}>{opt}</option>
              <% end %>
            </select>
          </div>
        </div>
      </form>
    </div>
    """
  end

  defp render_step_4(assigns) do
    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Clause Selection
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Select the clauses to include in this contract.
      </p>

      <div style="display:flex;flex-direction:column;gap:12px">
        <%= for clause <- @clauses do %>
          <div
            phx-click="toggle_clause"
            phx-value-id={clause.id}
            style={"display:flex;align-items:flex-start;gap:12px;background:#{if MapSet.member?(@selected_clauses, clause.id), do: "#2563eb11", else: "#080c14"};border:1px solid #{if MapSet.member?(@selected_clauses, clause.id), do: "#2563eb55", else: "#1e293b"};border-radius:8px;padding:16px;cursor:pointer"}
          >
            <div style={"width:20px;height:20px;border-radius:4px;border:2px solid #{if MapSet.member?(@selected_clauses, clause.id), do: "#2563eb", else: "#334155"};background:#{if MapSet.member?(@selected_clauses, clause.id), do: "#2563eb", else: "transparent"};display:flex;align-items:center;justify-content:center;flex-shrink:0;margin-top:2px"}>
              <%= if MapSet.member?(@selected_clauses, clause.id) do %>
                <span style="color:#fff;font-size:12px;font-weight:bold">&#10003;</span>
              <% end %>
            </div>
            <div>
              <div style="font-size:14px;font-weight:600;color:#e2e8f0;margin-bottom:4px">
                {clause.label}
              </div>
              <div style="font-size:12px;color:#64748b">
                {clause.description}
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_step_5(assigns) do
    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Optimizer Validation
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Run HiGHS solver to validate contract economics and get AI-powered analysis.
      </p>

      <%= if @optimizer_running do %>
        <div style="text-align:center;padding:48px">
          <div style="font-size:14px;color:#2563eb;margin-bottom:12px">
            Running optimizer...
          </div>
          <div style="width:200px;height:4px;background:#1e293b;border-radius:2px;margin:0 auto">
            <div style="width:60%;height:100%;background:#2563eb;border-radius:2px;animation:pulse 1.5s infinite"></div>
          </div>
        </div>
      <% else %>
        <%= if @optimizer_result == nil do %>
          <div style="text-align:center;padding:48px">
            <button
              phx-click="run_optimizer"
              style="background:#2563eb;color:#ffffff;border:none;border-radius:8px;padding:14px 32px;cursor:pointer;font-family:inherit;font-size:14px;font-weight:600"
            >
              Run Optimizer Validation
            </button>
            <p style="color:#64748b;font-size:12px;margin-top:12px">
              Validates proposed terms against the HiGHS LP solver for the selected product group.
            </p>
          </div>
        <% else %>
          <%!-- Solver Results --%>
          <div style="display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:24px">
            <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:16px;text-align:center">
              <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">Status</div>
              <div style={"font-size:16px;font-weight:700;color:#{if @optimizer_result.status == :optimal, do: "#10b981", else: "#ef4444"}"}>
                {format_status(@optimizer_result.status)}
              </div>
            </div>
            <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:16px;text-align:center">
              <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">Profit</div>
              <div style="font-size:16px;font-weight:700;color:#10b981">
                ${format_number(@optimizer_result.profit)}
              </div>
            </div>
            <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:16px;text-align:center">
              <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">Tons</div>
              <div style="font-size:16px;font-weight:700;color:#c8d6e5">
                {format_number(@optimizer_result.tons)}
              </div>
            </div>
            <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:16px;text-align:center">
              <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">ROI</div>
              <div style="font-size:16px;font-weight:700;color:#2563eb">
                {format_number(@optimizer_result.roi)}%
              </div>
            </div>
          </div>

          <%!-- Route allocations --%>
          <%= if length(@optimizer_result.route_tons) > 0 do %>
            <div style="margin-bottom:24px">
              <h3 style="font-size:14px;font-weight:600;color:#e2e8f0;margin:0 0 12px 0">Route Allocations</h3>
              <div style="display:flex;flex-direction:column;gap:6px">
                <%= for {tons, idx} <- Enum.with_index(@optimizer_result.route_tons) do %>
                  <div style="display:flex;justify-content:space-between;background:#080c14;border:1px solid #1e293b;border-radius:4px;padding:8px 12px;font-size:12px">
                    <span style="color:#94a3b8">Route {idx + 1}</span>
                    <span style="color:#c8d6e5">{format_number(tons)} MT</span>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Claude Explanation --%>
          <%= if @optimizer_explanation do %>
            <div style="background:#080c14;border:1px solid #1e293b;border-radius:8px;padding:20px;margin-top:16px">
              <h3 style="font-size:14px;font-weight:600;color:#e2e8f0;margin:0 0 12px 0">AI Analysis</h3>
              <div style="font-size:13px;color:#94a3b8;line-height:1.6;white-space:pre-wrap">
                {@optimizer_explanation}
              </div>
            </div>
          <% end %>

          <div style="margin-top:16px">
            <button
              phx-click="run_optimizer"
              style="background:#1e293b;color:#c8d6e5;border:1px solid #334155;border-radius:6px;padding:8px 16px;cursor:pointer;font-family:inherit;font-size:12px"
            >
              Re-run Optimizer
            </button>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_step_6(assigns) do
    selected_clause_labels =
      Enum.filter(assigns.clauses, fn c -> MapSet.member?(assigns.selected_clauses, c.id) end)
      |> Enum.map(& &1.label)

    assigns = assign(assigns, :selected_clause_labels, selected_clause_labels)

    pg_label =
      Enum.find_value(assigns.product_groups, "N/A", fn {id, label} ->
        if id == assigns.selected_product_group, do: label
      end)

    assigns = assign(assigns, :pg_label, pg_label)

    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Review Summary
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Review all contract details before submission.
      </p>

      <%!-- Section: Product Group --%>
      <div style="margin-bottom:24px">
        <h3 style="font-size:13px;color:#2563eb;text-transform:uppercase;letter-spacing:1px;margin:0 0 12px 0;padding-bottom:8px;border-bottom:1px solid #1e293b">
          Product Group
        </h3>
        <div style="font-size:14px;color:#e2e8f0">{@pg_label}</div>
      </div>

      <%!-- Section: Counterparty --%>
      <div style="margin-bottom:24px">
        <h3 style="font-size:13px;color:#2563eb;text-transform:uppercase;letter-spacing:1px;margin:0 0 12px 0;padding-bottom:8px;border-bottom:1px solid #1e293b">
          Counterparty & Commodity
        </h3>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
          <%= render_review_field("Counterparty", @counterparty) %>
          <%= render_review_field("Commodity", @commodity) %>
          <%= render_review_field("Delivery Start", @delivery_window_start) %>
          <%= render_review_field("Delivery End", @delivery_window_end) %>
        </div>
      </div>

      <%!-- Section: Commercial Terms --%>
      <div style="margin-bottom:24px">
        <h3 style="font-size:13px;color:#2563eb;text-transform:uppercase;letter-spacing:1px;margin:0 0 12px 0;padding-bottom:8px;border-bottom:1px solid #1e293b">
          Commercial Terms
        </h3>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
          <%= render_review_field("Quantity", "#{@quantity} #{@quantity_unit}") %>
          <%= render_review_field("Price", "$#{@proposed_price}") %>
          <%= render_review_field("Freight", "$#{@proposed_freight}/MT") %>
          <%= render_review_field("Payment", @payment_term) %>
          <%= render_review_field("Incoterm", @incoterm) %>
        </div>
      </div>

      <%!-- Section: Clauses --%>
      <div style="margin-bottom:24px">
        <h3 style="font-size:13px;color:#2563eb;text-transform:uppercase;letter-spacing:1px;margin:0 0 12px 0;padding-bottom:8px;border-bottom:1px solid #1e293b">
          Selected Clauses
        </h3>
        <div style="display:flex;flex-wrap:wrap;gap:8px">
          <%= for label <- @selected_clause_labels do %>
            <span style="background:#2563eb22;color:#2563eb;border:1px solid #2563eb55;border-radius:4px;padding:4px 10px;font-size:12px">
              {label}
            </span>
          <% end %>
        </div>
      </div>

      <%!-- Section: Optimizer --%>
      <%= if @optimizer_result do %>
        <div style="margin-bottom:24px">
          <h3 style="font-size:13px;color:#2563eb;text-transform:uppercase;letter-spacing:1px;margin:0 0 12px 0;padding-bottom:8px;border-bottom:1px solid #1e293b">
            Optimizer Validation
          </h3>
          <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px">
            <%= render_review_field("Status", format_status(@optimizer_result.status)) %>
            <%= render_review_field("Profit", "$#{format_number(@optimizer_result.profit)}") %>
            <%= render_review_field("ROI", "#{format_number(@optimizer_result.roi)}%") %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_step_7(assigns) do
    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Approval Submission
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Submit this contract for approval. A contract record will be created and routed for sign-off.
      </p>

      <%= case @submission_status do %>
        <% :submitted -> %>
          <div style="text-align:center;padding:48px">
            <div style="font-size:48px;margin-bottom:16px;color:#10b981">&#10003;</div>
            <h3 style="font-size:18px;font-weight:600;color:#10b981;margin:0 0 8px 0">
              Contract Submitted Successfully
            </h3>
            <p style="color:#94a3b8;font-size:13px;margin:0 0 24px 0">
              The contract has been created and submitted for approval.
            </p>
            <%= if @negotiation_id do %>
              <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:12px 16px;display:inline-block;margin-bottom:8px">
                <span style="color:#64748b;font-size:12px">Negotiation ID: </span>
                <span style="color:#c8d6e5;font-size:13px;font-weight:600">{@negotiation_id}</span>
              </div>
            <% end %>
            <%= if @contract_id do %>
              <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:12px 16px;display:inline-block">
                <span style="color:#64748b;font-size:12px">Contract ID: </span>
                <span style="color:#c8d6e5;font-size:13px;font-weight:600">{@contract_id}</span>
              </div>
            <% end %>
          </div>

        <% :error -> %>
          <div style="text-align:center;padding:48px">
            <div style="font-size:48px;margin-bottom:16px;color:#ef4444">&#10007;</div>
            <h3 style="font-size:18px;font-weight:600;color:#ef4444;margin:0 0 8px 0">
              Submission Failed
            </h3>
            <p style="color:#94a3b8;font-size:13px;margin:0 0 16px 0">
              {@submission_error}
            </p>
            <button
              phx-click="submit_for_approval"
              style="background:#2563eb;color:#ffffff;border:none;border-radius:6px;padding:10px 24px;cursor:pointer;font-family:inherit;font-size:13px"
            >
              Retry Submission
            </button>
          </div>

        <% _ -> %>
          <div style="text-align:center;padding:48px">
            <div style="background:#080c14;border:1px solid #1e293b;border-radius:8px;padding:24px;max-width:480px;margin:0 auto">
              <p style="color:#c8d6e5;font-size:14px;margin:0 0 16px 0">
                Ready to submit this contract for approval?
              </p>
              <p style="color:#64748b;font-size:12px;margin:0 0 24px 0">
                This will create a negotiation record, a contract record, and route it for approval.
                Please review all details in the previous step before submitting.
              </p>
              <button
                phx-click="submit_for_approval"
                style="background:#10b981;color:#ffffff;border:none;border-radius:8px;padding:14px 32px;cursor:pointer;font-family:inherit;font-size:14px;font-weight:600"
              >
                Submit for Approval
              </button>
            </div>
          </div>
      <% end %>
    </div>
    """
  end

  defp render_step_8(assigns) do
    ~H"""
    <div>
      <h2 style="font-size:18px;font-weight:600;color:#e2e8f0;margin:0 0 8px 0">
        Contract Ingestion
      </h2>
      <p style="color:#64748b;font-size:13px;margin:0 0 24px 0">
        Ingest the saved contract file into the active contracts store for solver integration.
      </p>

      <%= if @saved_contract_path do %>
        <%!-- Show saved file info --%>
        <div style="background:#080c14;border:1px solid #1e293b;border-radius:8px;padding:20px;margin-bottom:24px">
          <div style="font-size:12px;color:#94a3b8;text-transform:uppercase;margin-bottom:8px">Saved Contract File</div>
          <div style="display:flex;align-items:center;gap:12px">
            <div style="background:#2563eb22;border:1px solid #2563eb55;border-radius:6px;padding:8px 12px">
              <span style="font-size:13px;color:#2563eb;font-weight:600;font-family:'JetBrains Mono',monospace">
                {Path.basename(@saved_contract_path)}
              </span>
            </div>
            <span style="font-size:12px;color:#64748b">
              priv/contracts/seed/
            </span>
          </div>
        </div>

        <%= case @ingestion_status do %>
          <% :ingested -> %>
            <%!-- Success --%>
            <div style="text-align:center;padding:32px">
              <div style="font-size:48px;margin-bottom:16px;color:#10b981">&#10003;</div>
              <h3 style="font-size:18px;font-weight:600;color:#10b981;margin:0 0 8px 0">
                Contract Ingested Successfully
              </h3>
              <p style="color:#94a3b8;font-size:13px;margin:0 0 24px 0">
                The contract has been loaded into the active contracts store and is available for solver integration.
              </p>

              <%= if @ingestion_result do %>
                <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;max-width:480px;margin:0 auto 24px">
                  <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:12px;text-align:center">
                    <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">Status</div>
                    <div style="font-size:14px;font-weight:700;color:#10b981">
                      {String.upcase(to_string(@ingestion_result.status))}
                    </div>
                  </div>
                  <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:12px;text-align:center">
                    <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">Clauses</div>
                    <div style="font-size:14px;font-weight:700;color:#2563eb">
                      {length(@ingestion_result.clauses || [])}
                    </div>
                  </div>
                  <div style="background:#080c14;border:1px solid #1e293b;border-radius:6px;padding:12px;text-align:center">
                    <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:4px">Contract ID</div>
                    <div style="font-size:11px;font-weight:600;color:#c8d6e5;word-break:break-all">
                      {String.slice(@ingestion_result.id || "N/A", 0..11)}
                    </div>
                  </div>
                </div>
              <% end %>

              <button
                phx-click="start_new_contract"
                style="background:#2563eb;color:#ffffff;border:none;border-radius:6px;padding:10px 24px;cursor:pointer;font-family:inherit;font-size:13px;font-weight:600"
              >
                Start New Contract
              </button>
            </div>

          <% :ingesting -> %>
            <%!-- Loading --%>
            <div style="text-align:center;padding:48px">
              <div style="font-size:14px;color:#2563eb;margin-bottom:12px">
                Ingesting contract into store...
              </div>
              <div style="width:200px;height:4px;background:#1e293b;border-radius:2px;margin:0 auto">
                <div style="width:60%;height:100%;background:#2563eb;border-radius:2px;animation:pulse 1.5s infinite"></div>
              </div>
              <p style="color:#64748b;font-size:12px;margin-top:12px">
                Running LLM clause extraction (Stage 1: data extraction, Stage 2: LP formulation)...
              </p>
            </div>

          <% :error -> %>
            <%!-- Error --%>
            <div style="text-align:center;padding:32px">
              <div style="font-size:48px;margin-bottom:16px;color:#ef4444">&#10007;</div>
              <h3 style="font-size:18px;font-weight:600;color:#ef4444;margin:0 0 8px 0">
                Ingestion Failed
              </h3>
              <p style="color:#94a3b8;font-size:13px;margin:0 0 16px 0">
                {@ingestion_error}
              </p>
              <button
                phx-click="ingest_contract"
                style="background:#2563eb;color:#ffffff;border:none;border-radius:6px;padding:10px 24px;cursor:pointer;font-family:inherit;font-size:13px"
              >
                Retry Ingestion
              </button>
            </div>

          <% _ -> %>
            <%!-- Ready to ingest --%>
            <div style="text-align:center;padding:32px">
              <div style="background:#080c14;border:1px solid #1e293b;border-radius:8px;padding:24px;max-width:520px;margin:0 auto">
                <p style="color:#c8d6e5;font-size:14px;margin:0 0 8px 0">
                  The contract has been saved to disk. Click below to ingest it into the active contracts store.
                </p>
                <p style="color:#64748b;font-size:12px;margin:0 0 24px 0">
                  This will send the contract text through the LLM clause extraction pipeline
                  (two-stage: structured data extraction, then LP constraint formulation),
                  and ingest the resulting clauses into the contracts store for solver integration.
                </p>
                <button
                  phx-click="ingest_contract"
                  style="background:#10b981;color:#ffffff;border:none;border-radius:8px;padding:14px 32px;cursor:pointer;font-family:inherit;font-size:14px;font-weight:600"
                >
                  Ingest into Contracts Store
                </button>
              </div>
            </div>
        <% end %>
      <% else %>
        <%!-- No saved file yet — shouldn't normally reach here --%>
        <div style="text-align:center;padding:48px">
          <p style="color:#64748b;font-size:13px">
            No contract file found. Please go back and complete the approval step first.
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp render_review_field(label, value) do
    assigns = %{label: label, value: value}

    ~H"""
    <div>
      <div style="font-size:11px;color:#64748b;text-transform:uppercase;margin-bottom:2px">{@label}</div>
      <div style="font-size:14px;color:#e2e8f0">{@value}</div>
    </div>
    """
  end

  # ── Handle Events ────────────────────────────────────────

  # Step 1: Product group selection
  @impl true
  def handle_event("select_product_group", %{"group" => group}, socket) do
    {:noreply, assign(socket, :selected_product_group, group)}
  end

  # Step 2: Counterparty form changes
  @impl true
  def handle_event("update_step2", params, socket) do
    socket =
      socket
      |> assign(:counterparty, Map.get(params, "counterparty", socket.assigns.counterparty))
      |> assign(:commodity, Map.get(params, "commodity", socket.assigns.commodity))
      |> assign(:delivery_window_start, Map.get(params, "delivery_window_start", socket.assigns.delivery_window_start))
      |> assign(:delivery_window_end, Map.get(params, "delivery_window_end", socket.assigns.delivery_window_end))

    {:noreply, socket}
  end

  # Step 3: Commercial terms form changes
  @impl true
  def handle_event("update_step3", params, socket) do
    socket =
      socket
      |> assign(:quantity, Map.get(params, "quantity", socket.assigns.quantity))
      |> assign(:quantity_unit, Map.get(params, "quantity_unit", socket.assigns.quantity_unit))
      |> assign(:proposed_price, Map.get(params, "proposed_price", socket.assigns.proposed_price))
      |> assign(:proposed_freight, Map.get(params, "proposed_freight", socket.assigns.proposed_freight))
      |> assign(:payment_term, Map.get(params, "payment_term", socket.assigns.payment_term))
      |> assign(:incoterm, Map.get(params, "incoterm", socket.assigns.incoterm))

    {:noreply, socket}
  end

  # Step 4: Toggle clause selection
  @impl true
  def handle_event("toggle_clause", %{"id" => clause_id}, socket) do
    selected = socket.assigns.selected_clauses

    updated =
      if MapSet.member?(selected, clause_id) do
        MapSet.delete(selected, clause_id)
      else
        MapSet.put(selected, clause_id)
      end

    {:noreply, assign(socket, :selected_clauses, updated)}
  end

  # Step 5: Run optimizer
  @impl true
  def handle_event("run_optimizer", _params, socket) do
    socket = assign(socket, :optimizer_running, true)
    send(self(), :run_optimizer_async)
    {:noreply, socket}
  end

  # Navigation: Next
  @impl true
  def handle_event("next", _params, socket) do
    current = socket.assigns.current_step

    case validate_step(current, socket.assigns) do
      :ok ->
        new_step = min(current + 1, @total_steps)

        # Emit events at significant transitions
        socket = emit_step_event(current, new_step, socket)

        {:noreply, assign(socket, current_step: new_step, flash_msg: nil)}

      {:error, msg} ->
        {:noreply, assign(socket, :flash_msg, msg)}
    end
  end

  # Navigation: Back
  @impl true
  def handle_event("back", _params, socket) do
    new_step = max(socket.assigns.current_step - 1, 1)
    {:noreply, assign(socket, current_step: new_step, flash_msg: nil)}
  end

  # Step 7: Submit for approval
  @impl true
  def handle_event("submit_for_approval", _params, socket) do
    case create_contract_records(socket.assigns) do
      {:ok, %{negotiation: negotiation, contract: contract}} ->
        # Emit approval event
        try do
          EventEmitter.emit_event(
            "contract_submitted_for_approval",
            %{
              negotiation_id: negotiation.id,
              contract_id: contract.id,
              product_group: socket.assigns.selected_product_group,
              counterparty: socket.assigns.counterparty,
              commodity: socket.assigns.commodity,
              quantity: socket.assigns.quantity,
              proposed_price: socket.assigns.proposed_price,
              submitted_by: socket.assigns.current_user_email
            },
            "contract_management"
          )
        rescue
          e -> Logger.warning("EventEmitter failed: #{inspect(e)}")
        end

        # Save contract to disk in priv/contracts/seed/
        saved_path = save_contract_to_disk(socket.assigns, contract.contract_reference)

        socket =
          socket
          |> assign(:submission_status, :submitted)
          |> assign(:negotiation_id, negotiation.id)
          |> assign(:contract_id, contract.id)
          |> assign(:saved_contract_path, saved_path)
          |> assign(:current_step, 8)
          |> assign(:flash_msg, nil)

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(:submission_status, :error)
          |> assign(:submission_error, inspect(reason))

        {:noreply, socket}
    end
  end

  # Step 8: Ingest contract into store
  @impl true
  def handle_event("ingest_contract", _params, socket) do
    socket = assign(socket, :ingestion_status, :ingesting)
    send(self(), :ingest_contract_async)
    {:noreply, socket}
  end

  # Step 8: Start new contract (reset wizard)
  @impl true
  def handle_event("start_new_contract", _params, socket) do
    socket =
      socket
      |> assign(:current_step, 1)
      |> assign(:selected_product_group, nil)
      |> assign(:counterparty, "")
      |> assign(:commodity, "")
      |> assign(:delivery_window_start, "")
      |> assign(:delivery_window_end, "")
      |> assign(:quantity, "")
      |> assign(:quantity_unit, "MT")
      |> assign(:proposed_price, "")
      |> assign(:proposed_freight, "")
      |> assign(:payment_term, "Net 30")
      |> assign(:incoterm, "FOB")
      |> assign(:selected_clauses, MapSet.new(["force_majeure", "payment_terms"]))
      |> assign(:optimizer_result, nil)
      |> assign(:optimizer_running, false)
      |> assign(:optimizer_explanation, nil)
      |> assign(:negotiation_id, nil)
      |> assign(:contract_id, nil)
      |> assign(:submission_status, nil)
      |> assign(:submission_error, nil)
      |> assign(:saved_contract_path, nil)
      |> assign(:ingestion_status, nil)
      |> assign(:ingestion_result, nil)
      |> assign(:ingestion_error, nil)
      |> assign(:flash_msg, nil)

    {:noreply, socket}
  end

  # ── Handle Info (async optimizer) ────────────────────────

  @impl true
  def handle_info(:run_optimizer_async, socket) do
    pg = socket.assigns.selected_product_group
    product_group_atom = String.to_existing_atom(pg)

    # Get default variables for the product group and run the solver
    vars = ProductGroup.default_values(product_group_atom)

    # Override with proposed contract values where applicable
    vars = apply_contract_overrides(vars, socket.assigns)

    result =
      try do
        Solver.solve(product_group_atom, vars)
      rescue
        e ->
          Logger.warning("Solver failed: #{inspect(e)}")
          {:error, :solver_unavailable}
      catch
        :exit, reason ->
          Logger.warning("Solver exit: #{inspect(reason)}")
          {:error, :solver_timeout}
      end

    {optimizer_result, explanation} =
      case result do
        {:ok, %{status: _} = res} ->
          explanation = generate_optimizer_explanation(res, socket.assigns)
          {res, explanation}

        %{status: _} = res ->
          explanation = generate_optimizer_explanation(res, socket.assigns)
          {res, explanation}

        {:error, reason} ->
          fallback = %{
            status: :unavailable,
            profit: 0.0,
            tons: 0.0,
            roi: 0.0,
            route_tons: [],
            route_profits: [],
            margins: [],
            shadow_prices: []
          }

          {fallback,
           "Optimizer unavailable (#{inspect(reason)}). Proceeding with manual validation."}
      end

    # Emit optimizer validation event
    try do
      EventEmitter.emit_event(
        "contract_optimizer_validated",
        %{
          product_group: pg,
          counterparty: socket.assigns.counterparty,
          optimizer_status: optimizer_result.status,
          profit: optimizer_result.profit,
          roi: optimizer_result.roi
        },
        "contract_management"
      )
    rescue
      e -> Logger.warning("EventEmitter failed: #{inspect(e)}")
    end

    socket =
      socket
      |> assign(:optimizer_result, optimizer_result)
      |> assign(:optimizer_explanation, explanation)
      |> assign(:optimizer_running, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:ingest_contract_async, socket) do
    path = socket.assigns.saved_contract_path

    result =
      try do
        ingest_contract_file(path, socket.assigns)
      rescue
        e ->
          Logger.warning("Contract ingestion failed: #{inspect(e)}")
          {:error, Exception.message(e)}
      catch
        :exit, reason ->
          Logger.warning("Contract ingestion exit: #{inspect(reason)}")
          {:error, "Ingestion process timed out"}
      end

    socket =
      case result do
        {:ok, contract} ->
          socket
          |> assign(:ingestion_status, :ingested)
          |> assign(:ingestion_result, contract)

        {:error, reason} ->
          socket
          |> assign(:ingestion_status, :error)
          |> assign(:ingestion_error, inspect(reason))
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Step Validation ──────────────────────────────────────

  defp validate_step(1, assigns) do
    if assigns.selected_product_group && assigns.selected_product_group != "" do
      :ok
    else
      {:error, "Please select a product group before proceeding."}
    end
  end

  defp validate_step(2, assigns) do
    cond do
      assigns.counterparty == "" or assigns.counterparty == nil ->
        {:error, "Counterparty name is required."}

      assigns.commodity == "" or assigns.commodity == nil ->
        {:error, "Please select a commodity."}

      assigns.delivery_window_start == "" or assigns.delivery_window_start == nil ->
        {:error, "Delivery window start date is required."}

      assigns.delivery_window_end == "" or assigns.delivery_window_end == nil ->
        {:error, "Delivery window end date is required."}

      true ->
        :ok
    end
  end

  defp validate_step(3, assigns) do
    cond do
      assigns.quantity == "" or assigns.quantity == nil ->
        {:error, "Quantity is required."}

      assigns.proposed_price == "" or assigns.proposed_price == nil ->
        {:error, "Proposed price is required."}

      true ->
        :ok
    end
  end

  defp validate_step(4, assigns) do
    if MapSet.size(assigns.selected_clauses) > 0 do
      :ok
    else
      {:error, "Please select at least one contract clause."}
    end
  end

  defp validate_step(5, _assigns) do
    # Optimizer step — allow proceeding even without running optimizer
    :ok
  end

  defp validate_step(6, _assigns) do
    # Review step — always valid
    :ok
  end

  defp validate_step(_step, _assigns), do: :ok

  # ── Event Emission on Step Transitions ───────────────────

  defp emit_step_event(from_step, to_step, socket) do
    context = %{
      from_step: from_step,
      to_step: to_step,
      product_group: socket.assigns.selected_product_group,
      counterparty: socket.assigns.counterparty,
      user: socket.assigns.current_user_email
    }

    event_type =
      case to_step do
        2 -> "contract_product_group_selected"
        3 -> "contract_counterparty_set"
        4 -> "contract_commercial_terms_set"
        5 -> "contract_clauses_selected"
        6 -> "contract_optimizer_complete"
        7 -> "contract_review_complete"
        _ -> nil
      end

    if event_type do
      try do
        EventEmitter.emit_event(event_type, context, "contract_management")
      rescue
        e -> Logger.warning("EventEmitter failed on step transition: #{inspect(e)}")
      end
    end

    socket
  end

  # ── Contract Record Creation (Step 7) ────────────────────

  defp create_contract_records(assigns) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    ref_number = generate_reference_number(assigns.selected_product_group)
    contract_ref = "CTR-#{ref_number}"

    # Build terms map
    terms = %{
      "quantity" => assigns.quantity,
      "quantity_unit" => assigns.quantity_unit,
      "proposed_price" => assigns.proposed_price,
      "proposed_freight" => assigns.proposed_freight,
      "payment_term" => assigns.payment_term,
      "incoterm" => assigns.incoterm,
      "delivery_window_start" => assigns.delivery_window_start,
      "delivery_window_end" => assigns.delivery_window_end
    }

    # Build step_data snapshot
    step_data = %{
      "step_1" => %{"product_group" => assigns.selected_product_group},
      "step_2" => %{
        "counterparty" => assigns.counterparty,
        "commodity" => assigns.commodity,
        "delivery_window_start" => assigns.delivery_window_start,
        "delivery_window_end" => assigns.delivery_window_end
      },
      "step_3" => terms,
      "step_4" => %{"selected_clauses" => MapSet.to_list(assigns.selected_clauses)},
      "step_5" => %{
        "optimizer_ran" => assigns.optimizer_result != nil,
        "optimizer_status" => if(assigns.optimizer_result, do: assigns.optimizer_result.status, else: nil)
      },
      "step_6" => %{"reviewed" => true}
    }

    # Parse delivery dates
    delivery_start = parse_date(assigns.delivery_window_start)
    delivery_end = parse_date(assigns.delivery_window_end)

    # Parse decimals
    quantity_dec = parse_decimal(assigns.quantity)
    price_dec = parse_decimal(assigns.proposed_price)
    freight_dec = parse_decimal(assigns.proposed_freight)

    # Solver snapshot
    solver_snapshot =
      if assigns.optimizer_result do
        %{
          "status" => to_string(assigns.optimizer_result.status),
          "profit" => assigns.optimizer_result.profit,
          "tons" => assigns.optimizer_result.tons,
          "roi" => assigns.optimizer_result.roi
        }
      end

    solver_margin =
      if assigns.optimizer_result && assigns.optimizer_result.profit && assigns.optimizer_result.tons &&
           assigns.optimizer_result.tons > 0 do
        Decimal.new("#{Float.round(assigns.optimizer_result.profit / assigns.optimizer_result.tons, 2)}")
      end

    solver_confidence =
      if assigns.optimizer_result && assigns.optimizer_result.status == :optimal,
        do: Decimal.new("0.95"),
        else: Decimal.new("0.50")

    trader_id = assigns.current_user_email || "system"

    Repo.transaction(fn ->
      # 1. Create negotiation record
      negotiation_attrs = %{
        product_group: assigns.selected_product_group,
        reference_number: ref_number,
        counterparty: assigns.counterparty,
        commodity: assigns.commodity,
        status: "step_7_approval",
        current_step: 7,
        total_steps: 7,
        step_data: step_data,
        step_history: [],
        quantity: quantity_dec,
        quantity_unit: assigns.quantity_unit,
        delivery_window_start: delivery_start,
        delivery_window_end: delivery_end,
        proposed_price: price_dec,
        proposed_freight: freight_dec,
        proposed_terms: terms,
        solver_recommendation_snapshot: solver_snapshot,
        solver_margin_forecast: solver_margin,
        solver_confidence: solver_confidence,
        trader_id: trader_id
      }

      negotiation =
        %CmContractNegotiation{}
        |> CmContractNegotiation.changeset(negotiation_attrs)
        |> Repo.insert!()

      # 2. Create negotiation event
      %CmContractNegotiationEvent{}
      |> CmContractNegotiationEvent.changeset(%{
        contract_negotiation_id: negotiation.id,
        event_type: "submitted_for_approval",
        step_number: 7,
        actor: trader_id,
        summary: "Contract submitted for approval via wizard",
        details: %{"terms" => terms, "clauses" => MapSet.to_list(assigns.selected_clauses)}
      })
      |> Repo.insert!()

      # 3. Create contract record
      selected_clause_ids =
        assigns.selected_clauses
        |> MapSet.to_list()
        |> Enum.map(fn clause_id ->
          # Generate deterministic UUIDs from clause string IDs for the binary_id array
          :crypto.hash(:md5, "clause:#{clause_id}")
          |> Base.encode16(case: :lower)
          |> then(fn hex ->
            <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> = hex
            "#{a}-#{b}-#{c}-#{d}-#{e}"
          end)
        end)

      contract_attrs = %{
        product_group: assigns.selected_product_group,
        contract_negotiation_id: negotiation.id,
        contract_reference: contract_ref,
        counterparty: assigns.counterparty,
        commodity: assigns.commodity,
        status: "pending_approval",
        current_version: 1,
        terms: terms,
        selected_clause_ids: selected_clause_ids,
        requires_approval_from: ["trading_manager"],
        approved_by: []
      }

      contract =
        %CmContract{}
        |> CmContract.changeset(contract_attrs)
        |> Repo.insert!()

      # 4. Create initial contract version
      %CmContractVersion{}
      |> CmContractVersion.changeset(%{
        contract_id: contract.id,
        version_number: 1,
        terms_snapshot: terms,
        change_summary: "Initial contract version from wizard submission",
        created_by: trader_id
      })
      |> Repo.insert!()

      # 5. Create approval request
      %CmContractApproval{}
      |> CmContractApproval.changeset(%{
        contract_id: contract.id,
        approver_id: "trading_manager",
        approval_status: "pending"
      })
      |> Repo.insert!()

      %{negotiation: negotiation, contract: contract}
    end)
  end

  # ── Optimizer Helpers ────────────────────────────────────

  # ── Save Contract to Disk ────────────────────────────────

  defp save_contract_to_disk(assigns, contract_ref) do
    seed_path = Application.app_dir(:trading_desk, @seed_dir)
    File.mkdir_p!(seed_path)

    # Build filename from contract reference
    safe_ref = contract_ref |> String.replace(~r/[^a-zA-Z0-9_-]/, "_") |> String.downcase()
    filename = "#{safe_ref}.txt"
    file_path = Path.join(seed_path, filename)

    # Generate contract text in the same format as existing seed contracts
    contract_text = generate_contract_text(assigns, contract_ref)
    File.write!(file_path, contract_text)

    Logger.info("Contract saved to disk: #{file_path}")
    file_path
  end

  defp generate_contract_text(assigns, contract_ref) do
    pg_label =
      Enum.find_value(assigns.product_groups, assigns.selected_product_group, fn {id, label} ->
        if id == assigns.selected_product_group, do: label
      end)

    today = Date.utc_today() |> Date.to_iso8601()

    selected_clause_labels =
      Enum.filter(assigns.clauses, fn c -> MapSet.member?(assigns.selected_clauses, c.id) end)

    incoterm = assigns.incoterm || "FOB"
    payment = assigns.payment_term || "Net 30"

    # Determine direction based on product group naming conventions
    direction = if String.contains?(assigns.selected_product_group, "domestic"), do: "SALE", else: "PURCHASE"
    term_type = "SPOT"

    sections = [
      "#{String.upcase(assigns.commodity || "COMMODITY")} #{incoterm} #{direction} CONTRACT",
      "",
      "Contract No.: #{contract_ref}",
      "Date: #{today}",
      "Effective: #{assigns.delivery_window_start}",
      "Term: #{assigns.delivery_window_start} through #{assigns.delivery_window_end}",
      "",
      "BETWEEN:",
      "Trammo, Inc. (\"#{if direction == "PURCHASE", do: "Buyer", else: "Seller"}\")",
      "AND:",
      "#{assigns.counterparty} (\"#{if direction == "PURCHASE", do: "Seller", else: "Buyer"}\")",
      "",
      "#{term_type} #{incoterm} #{String.upcase(assigns.commodity || "")} #{direction} AGREEMENT",
      "",
      "1. PRODUCT AND SPECIFICATIONS",
      "",
      "Product: #{assigns.commodity}",
      "Product Group: #{pg_label}",
      "Product Specifications:",
      "  As per standard industry specifications for #{assigns.commodity}.",
      "",
      "2. QUANTITY",
      "",
      "Quantity: #{assigns.quantity} #{assigns.quantity_unit} +/- 5% at #{if direction == "PURCHASE", do: "buyer", else: "seller"}'s option.",
      "",
      "3. INCOTERMS",
      "",
      "INCOTERMS 2020: #{incoterm}.",
      "",
      "4. SHIPMENTS AND NOMINATIONS",
      "",
      "Shipments / nominations: As mutually agreed between the parties.",
      "Delivery Window: #{assigns.delivery_window_start} through #{assigns.delivery_window_end}.",
      "",
      "5. PRICE",
      "",
      "#{direction} Price: US $#{assigns.proposed_price} per #{assigns.quantity_unit} #{incoterm}.",
      if(assigns.proposed_freight != "" and assigns.proposed_freight != nil,
        do: "Freight: US $#{assigns.proposed_freight} per MT.",
        else: nil),
      "",
      "6. PAYMENT",
      "",
      "Payment: #{payment} from bill of lading date.",
      ""
    ]

    # Add selected clauses as numbered sections
    clause_sections =
      selected_clause_labels
      |> Enum.with_index(7)
      |> Enum.flat_map(fn {clause, idx} ->
        [
          "#{idx}. #{String.upcase(clause.label)}",
          "",
          clause.description,
          ""
        ]
      end)

    # Final section
    closing = [
      "#{7 + length(selected_clause_labels)}. GOVERNING LAW AND ARBITRATION",
      "",
      "Governing Law: This contract shall be governed by English law.",
      "Arbitration: Any and all disputes shall be referred to arbitration in London",
      "in accordance with LMAA terms.",
      "",
      "#{8 + length(selected_clause_labels)}. MISCELLANEOUS",
      "",
      "Miscellaneous: This contract constitutes the Entire Agreement between the",
      "parties regarding the subject matter hereof.",
      ""
    ]

    (sections ++ clause_sections ++ closing)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ── Contract Ingestion ─────────────────────────────────

  defp ingest_contract_file(file_path, assigns) do
    alias TradingDesk.Contracts.{Contract, Store}
    alias TradingDesk.LLM.{Pool, ModelRegistry}
    alias TradingDesk.Contracts.Clause

    text = File.read!(file_path)

    # Determine counterparty type based on direction in the contract text
    cp_type =
      if String.contains?(String.downcase(text), "purchase"),
        do: :supplier,
        else: :customer

    # Parse open position from quantity
    open_qty =
      case Float.parse(assigns.quantity || "0") do
        {qty, _} -> qty
        :error -> 0.0
      end

    # Extract clauses via LLM — the contract text is the source of truth
    clauses = extract_clauses_from_contract(text)

    # Determine template type
    is_purchase = cp_type == :supplier
    template_type = if is_purchase, do: :spot_purchase, else: :spot_sale

    # Parse incoterm from the actual contract text
    incoterm =
      try do
        assigns.incoterm |> String.downcase() |> String.to_existing_atom()
      rescue
        _ -> :fob
      end

    # Detect company from contract text
    company =
      cond do
        String.contains?(text, "Trammo SAS") -> :trammo_sas
        String.contains?(text, "Trammo DMCC") -> :trammo_dmcc
        true -> :trammo_inc
      end

    # Extract contract number from text
    contract_number =
      case Regex.run(~r/Contract\s+No\.?\s*:?\s*((?:TRAMMO|CTR)-[A-Z0-9_-]+)/i, text) do
        [_, number] -> number
        _ -> nil
      end

    contract = %Contract{
      counterparty: assigns.counterparty,
      counterparty_type: cp_type,
      product_group: :ammonia,
      template_type: template_type,
      incoterm: incoterm,
      term_type: :spot,
      company: company,
      source_file: Path.basename(file_path),
      source_format: :txt,
      clauses: clauses,
      family_id: nil,
      contract_number: contract_number,
      open_position: open_qty
    }

    case Store.ingest(contract) do
      {:ok, ingested} ->
        Store.update_status(ingested.id, :pending_review)
        Store.update_status(ingested.id, :approved,
          reviewed_by: assigns.current_user_email || "contract_wizard",
          notes: "Approved via contract management wizard with #{length(clauses)} LLM-extracted clauses"
        )

        Logger.info(
          "Contract ingested: #{assigns.counterparty} (#{cp_type}) #{incoterm} | " <>
          "open=#{open_qty} MT | clauses=#{length(clauses)} | file=#{Path.basename(file_path)}"
        )

        {:ok, ingested}

      error ->
        Logger.error("Failed to ingest contract #{assigns.counterparty}: #{inspect(error)}")
        error
    end
  end

  # ── LLM Clause Extraction ─────────────────────────────

  defp extract_clauses_from_contract(contract_text) do
    alias TradingDesk.LLM.{Pool, ModelRegistry}
    alias TradingDesk.Contracts.Clause

    extractor = ModelRegistry.extractor()
    reasoner = ModelRegistry.reasoner()

    result =
      cond do
        is_nil(extractor) and is_nil(reasoner) ->
          Logger.warning("No LLM models registered, ingesting without clause extraction")
          {:ok, []}

        is_nil(extractor) ->
          # Single-stage with reasoner only
          prompt = build_extraction_prompt(contract_text)
          case Pool.generate(reasoner.id, prompt, max_tokens: 8192) do
            {:ok, raw} -> parse_extracted_clauses(raw)
            {:error, reason} ->
              Logger.warning("LLM clause extraction failed: #{inspect(reason)}")
              {:ok, []}
          end

        true ->
          # Two-stage pipeline: Stage 1 (extractor) → Stage 2 (reasoner/extractor)
          case extract_structured_data(contract_text, extractor) do
            {:ok, structured_json} ->
              formulate_lp_constraints(structured_json, reasoner || extractor)

            {:error, reason} ->
              Logger.warning("Stage 1 extraction failed: #{inspect(reason)}, trying single-stage")
              prompt = build_extraction_prompt(contract_text)
              model = reasoner || extractor
              case Pool.generate(model.id, prompt, max_tokens: 8192) do
                {:ok, raw} -> parse_extracted_clauses(raw)
                {:error, _} -> {:ok, []}
              end
          end
      end

    case result do
      {:ok, clauses} -> clauses
      {:error, _} -> []
    end
  end

  # Stage 1: Extract structured data from contract text (fast model)
  defp extract_structured_data(contract_text, model) do
    alias TradingDesk.LLM.Pool

    max_chars = 50_000
    truncated = if String.length(contract_text) > max_chars do
      String.slice(contract_text, 0, max_chars) <> "\n[...truncated...]"
    else
      contract_text
    end

    prompt = """
    You are a contract data extraction system. Read this commodity trading contract
    and extract ALL structured data into the JSON format below.

    Do NOT interpret, reason about, or formulate constraints. Simply read and structure
    what is written in the contract.

    Return ONLY valid JSON:
    {"contract_data": {
      "quantities": { "annual_qty_mt": null, "tolerance_pct": null, "min_cargoes": null, "cargo_size_mt": null, "cargo_tolerance_pct": null },
      "pricing": { "base_price_usd_per_mt": null, "price_floor": null, "price_ceiling": null, "escalation": null, "benchmark": null },
      "delivery_schedule": { "start_date": null, "end_date": null, "frequency": null, "nomination_days": null, "laycan_window_days": null, "max_liftings_per_month": null },
      "logistics": { "loading_rate_mt_per_day": null, "discharge_rate": null, "laytime_hours": null, "demurrage_usd_per_day": null, "despatch_usd_per_day": null },
      "payment": { "terms_days": null, "instrument": null, "late_penalty_pct": null },
      "quality": { "purity_min_pct": null, "water_max_pct": null, "oil_max_ppm": null, "temp_max": null },
      "penalties": [{ "type": null, "trigger": null, "rate": null, "rate_unit": null, "cap_usd": null }],
      "take_or_pay": { "minimum_pct": null, "shortfall_penalty_usd_per_mt": null },
      "force_majeure": { "triggers": [], "notice_days": null, "suspension_rights": null },
      "insurance": { "required": null, "type": null },
      "legal": { "governing_law": null, "arbitration_venue": null },
      "optionality": { "extension_option": null, "volume_flex_pct": null, "price_reopener": null },
      "parties": { "seller": null, "buyer": null, "incoterm": null }
    }}

    Omit any section not found in the contract. Use null for unknown values.
    Extract exact numbers and dates as written.

    CONTRACT TEXT:
    #{truncated}
    """

    case Pool.generate(model.id, prompt, max_tokens: 8192) do
      {:ok, raw_text} ->
        json_str = extract_json_block(raw_text)
        case Jason.decode(json_str) do
          {:ok, %{"contract_data" => _} = data} -> {:ok, data}
          {:ok, data} when is_map(data) -> {:ok, %{"contract_data" => data}}
          {:error, reason} -> {:error, {:json_parse_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Stage 2: Formulate LP constraints from structured data (smart model)
  defp formulate_lp_constraints(structured_json, model) do
    alias TradingDesk.LLM.Pool

    json_text = Jason.encode!(structured_json, pretty: true)

    prompt = """
    You are an expert LP (Linear Programming) formulation analyst for commodity trading.

    Below is structured data extracted from a commodity trading contract.
    Formulate LP constraints ONLY for the data present. Do not invent values.

    EXTRACTED CONTRACT DATA:
    #{json_text}

    Return ONLY valid JSON: {"clauses": [...]}

    Each clause must have:
    - "clause_id": SHORT_UPPERCASE_ID describing the constraint
    - "category": one of "quantity", "delivery_schedule", "pricing", "payment", "logistics", "quality_spec", "penalty", "take_or_pay", "demurrage", "force_majeure", "insurance", "legal", "operational"
    - "description": plain-English operational meaning
    - "parameter": solver variable name (e.g. "annual_qty", "cargo_size", "nola_buy")
    - "operator": ">=", "<=", "==", "between"
    - "value": numeric value (lower bound for "between")
    - "value_upper": upper bound (only for "between")
    - "unit": "$/ton", "tons", "days", etc.
    - "penalty_rate": $/ton or $/day penalty for violation (if applicable)
    - "penalty_cap": maximum penalty exposure in $ (if applicable)
    - "period": "monthly"/"quarterly"/"annual"/"per_cargo"
    - "confidence": "high"/"medium"/"low"
    - "source_text": the extracted data point this constraint is derived from

    IMPORTANT:
    - Be concise. One clause per obligation.
    - For a bounded range, use a SINGLE "between" clause.
    - Keep descriptions short (one sentence).
    """

    case Pool.generate(model.id, prompt, max_tokens: 8192) do
      {:ok, raw_text} ->
        parse_extracted_clauses(raw_text)

      {:error, reason} ->
        Logger.warning("Stage 2 LP formulation failed: #{inspect(reason)}")
        {:ok, []}
    end
  end

  # Single-stage extraction prompt (fallback when only one model available)
  defp build_extraction_prompt(contract_text) do
    max_chars = 12_000
    truncated = if String.length(contract_text) > max_chars do
      String.slice(contract_text, 0, max_chars) <> "\n[...truncated...]"
    else
      contract_text
    end

    """
    You are an expert LP (Linear Programming) formulation analyst for commodity trading.

    Extract ALL clauses from this commodity trading contract and formulate
    LP constraints for a solver. For each obligation, produce a formal constraint
    with solver variable names, operators, and bounds.

    Return ONLY valid JSON: {"clauses": [...]}

    Each clause must have:
    - "clause_id": SHORT_UPPERCASE_ID describing the constraint
    - "category": one of "quantity", "delivery_schedule", "pricing", "payment", "logistics", "quality_spec", "penalty", "take_or_pay", "demurrage", "force_majeure", "insurance", "legal", "operational"
    - "source_text": exact quote from the contract
    - "description": plain-English operational meaning
    - "parameter": solver variable name if applicable
    - "operator": ">=", "<=", "==", "between"
    - "value": numeric value (lower bound for "between")
    - "value_upper": upper bound (only for "between")
    - "unit": "$/ton", "tons", "days", etc.
    - "penalty_rate": $/ton or $/day penalty for violation
    - "penalty_cap": maximum penalty exposure in $
    - "period": "monthly"/"quarterly"/"annual"/"per_cargo"
    - "confidence": "high"/"medium"/"low"

    CONTRACT TEXT:
    #{truncated}
    """
  end

  # Parse LLM JSON response into %Clause{} structs
  defp parse_extracted_clauses(raw_text) do
    alias TradingDesk.Contracts.Clause

    json_str = extract_json_block(raw_text)
    now = DateTime.utc_now()

    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses}} when is_list(clauses) ->
        built = Enum.map(clauses, fn c ->
          extracted_fields =
            %{}
            |> maybe_put_field("parameter", c["parameter"])
            |> maybe_put_field("operator", c["operator"])
            |> maybe_put_field("value", c["value"])
            |> maybe_put_field("value_upper", c["value_upper"])
            |> maybe_put_field("unit", c["unit"])
            |> maybe_put_field("penalty_per_unit", c["penalty_rate"])
            |> maybe_put_field("penalty_cap", c["penalty_cap"])
            |> maybe_put_field("period", c["period"])
            |> maybe_put_field("source_text", c["source_text"] || "")

          category_str = c["category"] || "condition"

          %Clause{
            id: Clause.generate_id(),
            clause_id: c["clause_id"],
            type: map_clause_category(category_str),
            category: String.to_atom(String.downcase(category_str)),
            description: c["description"] || c["source_text"] || "",
            confidence: safe_confidence(c["confidence"]),
            extracted_fields: extracted_fields,
            extracted_at: now
          }
        end)

        {:ok, built}

      {:ok, _} -> {:error, :no_clauses_in_response}
      {:error, reason} -> {:error, {:json_parse_failed, reason}}
    end
  end

  defp extract_json_block(text) do
    cond do
      String.contains?(text, "```json") ->
        text |> String.split("```json") |> Enum.at(1, "") |> String.split("```") |> List.first("") |> String.trim()
      String.contains?(text, "```") ->
        text |> String.split("```") |> Enum.at(1, "") |> String.trim()
      true ->
        String.trim(text)
    end
  end

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put_new(map, key, value)

  defp map_clause_category(cat) when is_binary(cat) do
    case String.downcase(cat) do
      "quantity" -> :obligation
      "delivery_schedule" -> :delivery
      "pricing" -> :price_term
      "payment" -> :payment
      "logistics" -> :delivery
      "quality_spec" -> :compliance
      "penalty" -> :penalty
      "take_or_pay" -> :penalty
      "demurrage" -> :penalty
      "force_majeure" -> :legal
      "insurance" -> :legal
      "legal" -> :legal
      "operational" -> :operational
      _ -> :condition
    end
  end
  defp map_clause_category(_), do: :condition

  defp safe_confidence(nil), do: :high
  defp safe_confidence(s) when is_binary(s), do: String.to_atom(String.downcase(s))
  defp safe_confidence(a) when is_atom(a), do: a
  defp safe_confidence(_), do: :high

  defp apply_contract_overrides(vars, assigns) do
    # Map proposed contract values to solver variables where applicable
    overrides = %{}

    overrides =
      if assigns.proposed_price != "" and assigns.proposed_price != nil do
        case Float.parse(assigns.proposed_price) do
          {price, _} -> Map.put(overrides, :nh3_price, price)
          :error -> overrides
        end
      else
        overrides
      end

    overrides =
      if assigns.proposed_freight != "" and assigns.proposed_freight != nil do
        case Float.parse(assigns.proposed_freight) do
          {freight, _} -> Map.put(overrides, :barge_freight, freight)
          :error -> overrides
        end
      else
        overrides
      end

    Map.merge(vars, overrides)
  end

  defp generate_optimizer_explanation(result, assigns) do
    status_text =
      case result.status do
        :optimal -> "OPTIMAL"
        :infeasible -> "INFEASIBLE"
        _ -> "#{result.status}"
      end

    profit = format_number(result.profit || 0)
    tons = format_number(result.tons || 0)
    roi = format_number(result.roi || 0)

    # Try to use PostsolveExplainer for AI analysis; fall back to formatted summary
    explanation =
      try do
        pg_atom = String.to_existing_atom(assigns.selected_product_group)
        vars = ProductGroup.default_values(pg_atom) |> apply_contract_overrides(assigns)
        results = TradingDesk.LLM.PostsolveExplainer.explain_all(vars, result, pg_atom)

        case results do
          [{_model_id, _model_name, {:ok, text}} | _] -> text
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    explanation ||
      """
      Solver Status: #{status_text}
      Projected Profit: $#{profit}
      Total Volume: #{tons} MT
      Return on Capital: #{roi}%

      Contract: #{assigns.counterparty} — #{assigns.commodity}
      Proposed Price: $#{assigns.proposed_price}/MT | Freight: $#{assigns.proposed_freight}/MT
      Quantity: #{assigns.quantity} #{assigns.quantity_unit}

      #{if result.status == :optimal, do: "The optimizer found a feasible solution. The proposed contract terms are within acceptable margins for the #{assigns.selected_product_group} product group.", else: "The optimizer could not find a feasible solution with the proposed terms. Consider adjusting price, quantity, or freight parameters."}
      """
  end

  # ── Helpers ──────────────────────────────────────────────

  defp progress_color(step, current) do
    cond do
      step < current -> "#10b981"
      step == current -> "#2563eb"
      true -> "#1e293b"
    end
  end

  defp format_status(:optimal), do: "OPTIMAL"
  defp format_status(:infeasible), do: "INFEASIBLE"
  defp format_status(:unavailable), do: "UNAVAILABLE"
  defp format_status(status), do: to_string(status) |> String.upcase()

  defp format_number(nil), do: "0"

  defp format_number(n) when is_float(n) do
    :erlang.float_to_binary(n, decimals: 2)
    |> add_commas()
  end

  defp format_number(n) when is_integer(n) do
    Integer.to_string(n) |> add_commas()
  end

  defp format_number(%Decimal{} = d), do: Decimal.to_string(d) |> add_commas()
  defp format_number(n), do: to_string(n)

  defp add_commas(str) do
    case String.split(str, ".") do
      [int_part, dec_part] ->
        add_commas_int(int_part) <> "." <> dec_part

      [int_part] ->
        add_commas_int(int_part)
    end
  end

  defp add_commas_int(str) do
    {sign, digits} =
      if String.starts_with?(str, "-") do
        {"-", String.slice(str, 1..-1//1)}
      else
        {"", str}
      end

    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
    |> then(&(sign <> &1))
  end

  defp generate_reference_number(product_group) do
    prefix =
      case product_group do
        "ammonia_domestic" -> "AD"
        "sulphur_international" -> "SI"
        "petcoke" -> "PC"
        "ammonia_international" -> "AI"
        _ -> "XX"
      end

    timestamp = DateTime.utc_now() |> Calendar.strftime("%y%m%d%H%M")
    random = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{prefix}-#{timestamp}-#{random}"
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_decimal(""), do: nil
  defp parse_decimal(nil), do: nil

  defp parse_decimal(str) when is_binary(str) do
    case Decimal.parse(str) do
      {dec, _} -> dec
      :error -> nil
    end
  end

  defp parse_decimal(n) when is_number(n), do: Decimal.new("#{n}")
end
