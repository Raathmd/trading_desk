defmodule TradingDesk.Data.API.Internal do
  @moduledoc """
  Internal systems API integration.

  Fetches operational data from Trammo's internal systems. Maps to solver variables:

    - inv_mer:    Inventory at Meredosia terminal, IL (tons) — sourced from Insight
    - inv_nio:    Inventory at Niota terminal, IL (tons) — sourced from Insight
    - mer_outage: Meredosia terminal outage (boolean) — trader-toggled via UI
    - nio_outage: Niota terminal outage (boolean) — trader-toggled via UI
    - barge_count: Selected barges from fleet management system
    - working_cap: Available working capital ($) — SAP FI

  ## Data Sources

  1. **Insight** (Trammo terminal management system) — Actual inventory balances
     - System of record for physical NH3 stock at Meredosia and Niota
     - Configure: `INSIGHT_API_URL`, `INSIGHT_API_KEY`
     - Until configured, seed values are returned so the solver always has data;
       traders can adjust via UI sliders at any time.

  2. **Fleet Management / TMS** — Selected barges
     - Counts barges with status `selected` (committed to Trammo operations)
     - Configure: `TMS_URL`, `TMS_API_KEY`

  3. **Manual / trader-toggled** — Terminal outages
     - mer_outage and nio_outage are set by traders via the UI toggle
     - This module does not fetch outage data; the poller falls back to defaults

  4. **SAP S/4HANA FI** — Working capital
     - Configure: `SAP_API_URL`, `SAP_API_KEY`
  """

  require Logger

  @doc """
  Fetch all internal operational data.

  Returns `{:ok, %{inv_mer: float, inv_nio: float, barge_count: float, working_cap: float}}`
  or `{:error, reason}`.

  Terminal outages (mer_outage, nio_outage) are not fetched here — they are
  trader-toggled via the scenario UI.
  """
  @spec fetch() :: {:ok, map()} | {:error, term()}
  def fetch do
    results = %{}

    results = case fetch_inventory() do
      {:ok, inv} -> Map.merge(results, inv)
      {:error, reason} ->
        Logger.warning("[Internal] Insight inventory fetch failed: #{inspect(reason)}")
        results
    end

    results = case fetch_barge_fleet() do
      {:ok, barges} -> Map.merge(results, barges)
      {:error, reason} ->
        Logger.warning("[Internal] Fleet management fetch failed: #{inspect(reason)}")
        results
    end

    results = case fetch_working_capital() do
      {:ok, cap} -> Map.merge(results, cap)
      {:error, _} -> results
    end

    if map_size(results) > 0 do
      {:ok, Map.put(results, :source, :individual_systems)}
    else
      {:error, :all_systems_unavailable}
    end
  end

  # ──────────────────────────────────────────────────────────
  # INSIGHT — TERMINAL INVENTORY
  # ──────────────────────────────────────────────────────────

  @doc """
  Fetch actual inventory balances from Insight (Trammo terminal management system).

  Insight is the system of record for physical NH3 stock at Meredosia and Niota.
  Until `INSIGHT_API_URL` is configured, seed data is returned so the solver always
  has values. Traders can adjust at any time via the UI sliders.

  Expected Insight response shapes:

  Array of terminal objects:
      {
        "terminals": [
          {"name": "Meredosia", "code": "MER", "balance_tons": 11500.0, "as_of": "..."},
          {"name": "Niota",     "code": "NIO", "balance_tons": 7800.0,  "as_of": "..."}
        ]
      }

  OR flat map:
      {"MER": 11500.0, "NIO": 7800.0}
  """
  @spec fetch_inventory() :: {:ok, map()} | {:error, term()}
  def fetch_inventory do
    insight_url = TradingDesk.ApiConfig.get_url("insight", "INSIGHT_API_URL")
    insight_key = TradingDesk.ApiConfig.get_credential("insight", "INSIGHT_API_KEY")

    if insight_url not in [nil, ""] do
      fetch_inventory_insight(insight_url, insight_key)
    else
      Logger.info("[Internal] INSIGHT_API_URL not configured — using seed inventory data for Meredosia/Niota")
      {:ok, %{inv_mer: 11_500.0, inv_nio: 7_800.0, source: :insight_seed}}
    end
  end

  defp fetch_inventory_insight(url, api_key) do
    full_url = "#{url}/api/terminals/balances?product=NH3"

    headers =
      if api_key not in [nil, ""] do
        [{"Authorization", "Bearer #{api_key}"}, {"Accept", "application/json"}]
      else
        [{"Accept", "application/json"}]
      end

    case http_get(full_url, headers) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"terminals" => terminals}} when is_list(terminals) ->
            inv = Enum.reduce(terminals, %{}, fn t, acc ->
              code = String.upcase(t["code"] || t["name"] || "")
              balance = parse_num(t["balance_tons"] || t["balance"] || t["qty"])

              cond do
                String.contains?(code, "MER") or String.contains?(code, "MEREDOSIA") ->
                  Map.put(acc, :inv_mer, balance)
                String.contains?(code, "NIO") or String.contains?(code, "NIOTA") ->
                  Map.put(acc, :inv_nio, balance)
                true -> acc
              end
            end)
            {:ok, inv}

          {:ok, data} when is_map(data) ->
            {:ok, %{
              inv_mer: parse_num(data["MER"] || data["Meredosia"] || data["meredosia"]),
              inv_nio: parse_num(data["NIO"] || data["Niota"] || data["niota"])
            }}

          _ -> {:error, :insight_parse_failed}
        end

      {:error, _} = err -> err
    end
  end

  # ──────────────────────────────────────────────────────────
  # FLEET MANAGEMENT — SELECTED BARGES
  # ──────────────────────────────────────────────────────────

  @doc """
  Fetch barge count from the fleet management system.

  Counts barges with status `selected` — those pre-assigned to Trammo operations
  for the current trading window. This reflects committed capacity, not the
  broader pool of vessels.

  Expected response shapes:
      {"selected_barges": 12}
  OR fleet array:
      {"fleet": [{"id": "...", "status": "selected"}, ...]}
  """
  @spec fetch_barge_fleet() :: {:ok, map()} | {:error, term()}
  def fetch_barge_fleet do
    tms_url = TradingDesk.ApiConfig.get_url("tms", "TMS_URL")
    tms_key = TradingDesk.ApiConfig.get_credential("tms", "TMS_API_KEY")

    if tms_url not in [nil, ""] do
      url = "#{tms_url}/api/fleet/selected?product=ammonia"

      headers =
        if tms_key not in [nil, ""] do
          [{"Authorization", "Bearer #{tms_key}"}, {"Accept", "application/json"}]
        else
          [{"Accept", "application/json"}]
        end

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"selected_barges" => count}} when is_number(count) ->
              {:ok, %{barge_count: count / 1.0}}

            {:ok, %{"fleet" => fleet}} when is_list(fleet) ->
              selected = Enum.count(fleet, fn b ->
                String.downcase(b["status"] || "") == "selected"
              end)
              {:ok, %{barge_count: selected / 1.0}}

            _ -> {:error, :tms_parse_failed}
          end

        {:error, _} = err -> err
      end
    else
      {:error, :tms_not_configured}
    end
  end

  # ──────────────────────────────────────────────────────────
  # SAP FI — WORKING CAPITAL
  # ──────────────────────────────────────────────────────────

  @doc "Fetch available working capital from SAP FI."
  @spec fetch_working_capital() :: {:ok, map()} | {:error, term()}
  def fetch_working_capital do
    sap_url = TradingDesk.ApiConfig.get_url("sap", "SAP_API_URL")
    sap_key = TradingDesk.ApiConfig.get_credential("sap", "SAP_API_KEY")

    if sap_url not in [nil, ""] do
      url = "#{sap_url}/api/finance/working-capital?business_unit=TRADING"

      headers = [
        {"Authorization", "Bearer #{sap_key}"},
        {"Accept", "application/json"}
      ]

      case http_get(url, headers) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, data} when is_map(data) ->
              cap = parse_num(
                data["available_working_capital"] ||
                data["working_cap"] ||
                data["available_credit"]
              )

              if cap do
                {:ok, %{working_cap: cap}}
              else
                {:error, :no_capital_data}
              end

            _ -> {:error, :parse_failed}
          end

        {:error, _} = err -> err
      end
    else
      {:error, :sap_not_configured}
    end
  end

  # ──────────────────────────────────────────────────────────
  # HELPERS
  # ──────────────────────────────────────────────────────────

  defp parse_num(nil), do: nil
  defp parse_num(v) when is_number(v), do: v / 1.0
  defp parse_num(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp http_get(url, headers \\ []) do
    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, Jason.encode!(body)}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end
end
