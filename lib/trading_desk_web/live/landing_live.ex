defmodule TradingDesk.LandingLive do
  @moduledoc """
  Landing page — choose between the full Trading Desk (ScenarioLive)
  or the simplified What-If Analysis workflow (WhatifLive).
  """
  use Phoenix.LiveView

  @impl true
  def mount(_params, session, socket) do
    current_user_email = Map.get(session, "authenticated_email")
    {:ok, assign(socket, :current_user_email, current_user_email)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div style="background:#080c14;color:#c8d6e5;min-height:100vh;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',monospace;display:flex;flex-direction:column;align-items:center;justify-content:center">
      <%!-- Header --%>
      <div style="text-align:center;margin-bottom:48px">
        <div style="font-size:11px;letter-spacing:3px;color:#475569;font-weight:600;margin-bottom:8px">TRAMMO</div>
        <h1 style="font-size:28px;font-weight:700;color:#e2e8f0;letter-spacing:1px;margin:0">TRADING DESK</h1>
        <div style="font-size:12px;color:#475569;margin-top:8px">Choose your workflow</div>
      </div>

      <%!-- Cards --%>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:24px;max-width:720px;width:100%;padding:0 20px">
        <%!-- Full Trading Desk --%>
        <a href="/desk" style="text-decoration:none">
          <div style="background:#0d1117;border:1px solid #1e293b;border-radius:12px;padding:32px 24px;cursor:pointer;transition:border-color 0.2s;min-height:240px;display:flex;flex-direction:column;justify-content:space-between"
               onmouseover="this.style.borderColor='#2563eb'" onmouseout="this.style.borderColor='#1e293b'">
            <div>
              <div style="font-size:10px;letter-spacing:2px;color:#2563eb;font-weight:700;margin-bottom:12px">FULL DESK</div>
              <div style="font-size:18px;font-weight:700;color:#e2e8f0;margin-bottom:8px">Trading Desk</div>
              <div style="font-size:12px;color:#7b8fa4;line-height:1.6">
                Full scenario exploration with solve, Monte Carlo, agent monitoring, fleet tracking, contracts, and decisions.
              </div>
            </div>
            <div style="margin-top:20px;display:flex;gap:6px;flex-wrap:wrap">
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#60a5fa;font-weight:600">SOLVER</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#34d399;font-weight:600">MONTE CARLO</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#f59e0b;font-weight:600">AGENT</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#c4b5fd;font-weight:600">FLEET</span>
            </div>
          </div>
        </a>

        <%!-- What-If Analysis --%>
        <a href="/whatif" style="text-decoration:none">
          <div style="background:#0d1117;border:1px solid #1e293b;border-radius:12px;padding:32px 24px;cursor:pointer;transition:border-color 0.2s;min-height:240px;display:flex;flex-direction:column;justify-content:space-between"
               onmouseover="this.style.borderColor='#10b981'" onmouseout="this.style.borderColor='#1e293b'">
            <div>
              <div style="font-size:10px;letter-spacing:2px;color:#10b981;font-weight:700;margin-bottom:12px">SIMPLIFIED</div>
              <div style="font-size:18px;font-weight:700;color:#e2e8f0;margin-bottom:8px">What-If Analysis</div>
              <div style="font-size:12px;color:#7b8fa4;line-height:1.6">
                Guided step-by-step workflow: review variables, inspect contracts, frame with LLM, solve, and get AI explanations.
              </div>
            </div>
            <div style="margin-top:20px;display:flex;gap:6px;flex-wrap:wrap">
              <span style="background:#071a12;border:1px solid #10b98144;border-radius:4px;padding:3px 8px;font-size:9px;color:#34d399;font-weight:600">VARIABLES</span>
              <span style="background:#071a12;border:1px solid #10b98144;border-radius:4px;padding:3px 8px;font-size:9px;color:#34d399;font-weight:600">CONTRACTS</span>
              <span style="background:#071a12;border:1px solid #10b98144;border-radius:4px;padding:3px 8px;font-size:9px;color:#34d399;font-weight:600">LLM FRAME</span>
              <span style="background:#071a12;border:1px solid #10b98144;border-radius:4px;padding:3px 8px;font-size:9px;color:#34d399;font-weight:600">SOLVE</span>
            </div>
          </div>
        </a>

        <%!-- Contract Management --%>
        <a href="/contracts/manage" style="text-decoration:none">
          <div style="background:#0d1117;border:1px solid #1e293b;border-radius:12px;padding:32px 24px;cursor:pointer;transition:border-color 0.2s;min-height:240px;display:flex;flex-direction:column;justify-content:space-between"
               onmouseover="this.style.borderColor='#f59e0b'" onmouseout="this.style.borderColor='#1e293b'">
            <div>
              <div style="font-size:10px;letter-spacing:2px;color:#f59e0b;font-weight:700;margin-bottom:12px">CONTRACT MGMT</div>
              <div style="font-size:18px;font-weight:700;color:#e2e8f0;margin-bottom:8px">Contract Management</div>
              <div style="font-size:12px;color:#7b8fa4;line-height:1.6">
                Multi-step contract formulation wizard: product selection, terms, clause selection, optimizer validation, approval workflow.
              </div>
            </div>
            <div style="margin-top:20px;display:flex;gap:6px;flex-wrap:wrap">
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#f59e0b;font-weight:600">WIZARD</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#f59e0b;font-weight:600">CLAUSES</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#60a5fa;font-weight:600">OPTIMIZER</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#c4b5fd;font-weight:600">APPROVAL</span>
            </div>
          </div>
        </a>

        <%!-- Initialize Vector DB --%>
        <a href="/backfill" style="text-decoration:none">
          <div style="background:#0d1117;border:1px solid #1e293b;border-radius:12px;padding:32px 24px;cursor:pointer;transition:border-color 0.2s;min-height:240px;display:flex;flex-direction:column;justify-content:space-between"
               onmouseover="this.style.borderColor='#8b5cf6'" onmouseout="this.style.borderColor='#1e293b'">
            <div>
              <div style="font-size:10px;letter-spacing:2px;color:#8b5cf6;font-weight:700;margin-bottom:12px">INTELLIGENCE</div>
              <div style="font-size:18px;font-weight:700;color:#e2e8f0;margin-bottom:8px">Initialize Vector DB</div>
              <div style="font-size:12px;color:#7b8fa4;line-height:1.6">
                Upload SAP contract history files, process through AI for semantic framing, and vectorize for historical deal intelligence.
              </div>
            </div>
            <div style="margin-top:20px;display:flex;gap:6px;flex-wrap:wrap">
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#8b5cf6;font-weight:600">UPLOAD</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#8b5cf6;font-weight:600">AI FRAMING</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#34d399;font-weight:600">VECTORS</span>
              <span style="background:#111827;border:1px solid #1e293b;border-radius:4px;padding:3px 8px;font-size:9px;color:#60a5fa;font-weight:600">HISTORY</span>
            </div>
          </div>
        </a>
      </div>

      <%!-- Links --%>
      <div style="margin-top:48px;display:flex;align-items:center;gap:12px;font-size:11px">
        <a href="/process_flows.html" target="_blank" style="color:#2dd4bf;text-decoration:none;border:1px solid #1e293b;padding:4px 10px;border-radius:4px;font-weight:600">PROCESS FLOWS</a>
        <a href="/architecture_overview.html" target="_blank" style="color:#38bdf8;text-decoration:none;border:1px solid #1e293b;padding:4px 10px;border-radius:4px;font-weight:600">OVERVIEW</a>
      </div>

      <%!-- Footer --%>
      <%= if @current_user_email do %>
        <div style="margin-top:16px;display:flex;align-items:center;gap:12px;font-size:11px">
          <span style="color:#475569"><%= @current_user_email %></span>
          <a href="/logout" style="color:#7b8fa4;text-decoration:none;border:1px solid #1e293b;padding:4px 10px;border-radius:4px;font-weight:600">LOGOUT</a>
        </div>
      <% end %>
    </div>
    """
  end
end
