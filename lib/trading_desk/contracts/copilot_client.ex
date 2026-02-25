defmodule TradingDesk.Contracts.CopilotClient do
  @moduledoc """
  LLM client for on-demand clause extraction from SharePoint files.

  Called by ScanCoordinator when a contract file needs to be extracted.
  Two modes:

    1. `extract_file/3` — given a Graph API file reference (drive_id + item_id),
       fetches the file content via Graph API, extracts text, sends to LLM.
       Copilot handles all file access — Zig scanner never downloads content.

    2. `extract_text/1` — given pre-extracted text, sends directly to LLM.
       Used when text is already available (e.g. from a local file test).

  ## Architecture

  ```
  ScanCoordinator: "this file changed, extract it"
       │
       ▼
  CopilotClient.extract_file(drive_id, item_id, token)
       │
       ├── Graph API: download file content
       ├── DocumentReader: convert binary → text
       └── LLM: extract clauses from text
       │
       ▼
  Returns: {:ok, %{"clauses" => [...], "counterparty" => "Koch", ...}}
  ```

  ## Configuration

    COPILOT_ENDPOINT  — LLM API endpoint (OpenAI-compatible, required)
    COPILOT_API_KEY   — API key (required)
    COPILOT_MODEL     — model identifier (default: gpt-4o)
    COPILOT_TIMEOUT   — request timeout in ms (default: 120000)
  """

  alias TradingDesk.Contracts.DocumentReader
  alias TradingDesk.ProductGroup

  require Logger

  @default_timeout 120_000
  @default_model "gpt-4o"
  @graph_base "https://graph.microsoft.com/v1.0"
  @max_concurrent_extractions 4

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Extract clauses from a SharePoint file by reference.

  Downloads the file via Graph API, extracts text, sends to LLM.
  Copilot handles all file access — Zig scanner never downloads content.

  Returns:
    {:ok, %{"clauses" => [...], "counterparty" => "Koch", ...}}
  """
  @spec extract_file(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def extract_file(drive_id, item_id, graph_token, opts \\ []) do
    filename = Keyword.get(opts, :filename, "document")
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    with {:ok, config} <- get_config(),
         {:ok, content} <- download_from_graph(drive_id, item_id, graph_token),
         {:ok, text} <- extract_text_from_binary(content, filename),
         {:ok, extraction} <- call_llm(text, config, product_group) do
      {:ok, Map.merge(extraction, %{
        "graph_drive_id" => drive_id,
        "graph_item_id" => item_id,
        "file_size" => byte_size(content),
        "file_hash" => sha256(content)
      })}
    end
  end

  @doc """
  Extract clauses from multiple SharePoint files concurrently.

  Each file is a map: %{drive_id, item_id, name, ...}
  Runs up to #{@max_concurrent_extractions} extractions in parallel.

  Returns a list of {file, result} tuples:
    [{%{name: "Koch.pdf", ...}, {:ok, extraction}}, ...]
  """
  @spec extract_files([map()], String.t(), keyword()) :: [{map(), {:ok, map()} | {:error, term()}}]
  def extract_files(files, graph_token, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    files
    |> Task.async_stream(
      fn file ->
        drive_id = file["drive_id"] || file[:drive_id]
        item_id = file["item_id"] || file[:item_id]
        name = file["name"] || file[:name] || "document"

        result = extract_file(drive_id, item_id, graph_token, filename: name, product_group: product_group)
        {file, result}
      end,
      max_concurrency: @max_concurrent_extractions,
      timeout: @default_timeout + 30_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {file, result}} -> {file, result}
      {:exit, :timeout} -> {%{}, {:error, :extraction_timeout}}
    end)
  end

  @doc """
  Extract structured clause data from pre-extracted contract text.

  Used when text is already available (e.g. local file test).
  """
  @spec extract_text(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def extract_text(contract_text, opts \\ []) do
    product_group = Keyword.get(opts, :product_group, :ammonia_domestic)

    with {:ok, config} <- get_config() do
      call_llm(contract_text, config, product_group)
    end
  end

  @doc "Check if the LLM API is configured and reachable."
  @spec available?() :: boolean()
  def available? do
    case get_config() do
      {:ok, config} ->
        case Req.get(config.endpoint <> "/models",
               headers: auth_headers(config),
               receive_timeout: 5_000) do
          {:ok, %{status: s}} when s in 200..299 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  # ──────────────────────────────────────────────────────────
  # LLM CALL
  # ──────────────────────────────────────────────────────────

  defp call_llm(contract_text, config, product_group) do
    body = %{
      model: config.model,
      messages: [
        %{role: "system", content: system_prompt(product_group)},
        %{role: "user", content: extraction_prompt(contract_text)}
      ],
      temperature: 0.1,
      response_format: %{type: "json_object"}
    }

    case Req.post(config.endpoint <> "/chat/completions",
           json: body,
           headers: auth_headers(config),
           receive_timeout: timeout()
         ) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => json_str}} | _]}}} ->
        parse_response(json_str)

      {:ok, %{status: status, body: body}} ->
        Logger.error("LLM API error (#{status}): #{inspect(body)}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("LLM API unreachable: #{inspect(reason)}")
        {:error, {:api_unreachable, reason}}
    end
  end

  defp parse_response(json_str) do
    case Jason.decode(json_str) do
      {:ok, %{"clauses" => clauses} = extraction} when is_list(clauses) ->
        {:ok, extraction}
      {:ok, _} ->
        {:error, :missing_clauses_key}
      {:error, reason} ->
        {:error, {:json_parse_failed, reason}}
    end
  end

  # ──────────────────────────────────────────────────────────
  # PROMPTS
  # ──────────────────────────────────────────────────────────

  defp system_prompt(product_group) do
    solver_variables = solver_variables_text(product_group)
    routes = solver_routes_text(product_group)
    constraints = solver_constraints_text(product_group)

    """
    You are a contract extraction specialist for Trammo's commodity trading desk.
    Extract ALL clauses from commodity trading contracts and return them in
    solver-ready format.

    Your job is to identify every clause that could affect trading optimization
    and map each to the appropriate solver variable with the correct operator
    and numeric value.

    Return a JSON object with the exact structure specified in the user prompt.
    Be precise with numerical values. Preserve original units and currencies.

    ## Solver Variables
    These are the variables in the LP solver. Map extracted clause values to
    the matching variable key when the clause constrains that variable.

    #{solver_variables}

    ## Solver Routes
    #{routes}

    ## Solver Constraints
    #{constraints}

    ## Operator Rules
    - "==" : clause fixes the variable to an exact value (e.g. contract price)
    - ">=" : clause sets a minimum floor (e.g. minimum volume commitment)
    - "<=" : clause sets a maximum ceiling (e.g. capacity limit)
    - "between" : clause sets both a floor and ceiling (use value + value_upper)
    - null : clause is informational, does not constrain a solver variable

    ## Penalty Clauses
    For penalty clauses (demurrage, volume shortfall, late delivery, take-or-pay),
    set penalty_per_unit to the $/ton or $/day rate. These are used to adjust
    effective margins but are not directly applied as variable bounds.
    """
  end

  defp extraction_prompt(contract_text) do
    """
    Extract ALL clauses from this contract. Do not limit yourself to known clause
    types — extract every provision, term, or obligation that could affect trading
    decisions or solver optimization.

    Return JSON:

    {
      "contract_number": "string or null",
      "counterparty": "name",
      "counterparty_type": "supplier" or "customer",
      "direction": "purchase" or "sale",
      "incoterm": "FOB" etc.,
      "term_type": "spot" or "long_term",
      "company": "trammo_inc" or "trammo_sas" or "trammo_dmcc",
      "effective_date": "YYYY-MM-DD or null",
      "expiry_date": "YYYY-MM-DD or null",
      "family_id": "descriptive family like VESSEL_SPOT_PURCHASE or null",
      "clauses": [
        {
          "clause_id": "SHORT_UPPERCASE_ID",
          "category": "commercial|core_terms|logistics|logistics_cost|risk_events|credit_legal|legal|compliance|operational|metadata",
          "extracted_fields": {"price_value": 340.00, "price_uom": "$/ton"},
          "source_text": "exact contract text for this clause",
          "section_ref": "Section 5",
          "confidence": "high|medium|low",
          "parameter": "solver_variable_key or null",
          "operator": "== or >= or <= or between or null",
          "value": 340.00,
          "value_upper": null,
          "unit": "$/ton",
          "penalty_per_unit": null,
          "penalty_cap": null,
          "period": "monthly|quarterly|annual|spot|null"
        }
      ]
    }

    Rules:
    - Extract EVERY identifiable clause — pricing, quantities, tolerances,
      penalties, delivery terms, payment terms, force majeure, insurance,
      vessel requirements, compliance, and any other provisions
    - Include exact source_text from the contract
    - Precise numerical values (prices, quantities, percentages, rates)
    - Map each clause to a solver variable (parameter) when applicable
    - Set operator and value for solver-constraining clauses
    - For penalty clauses, set penalty_per_unit to the rate
    - Set parameter to null for informational/legal clauses that do not
      directly constrain a solver variable
    - confidence: "low" if uncertain about extraction or mapping
    - Use descriptive UPPERCASE_SNAKE_CASE for clause_id

    CONTRACT:
    ---
    #{contract_text}
    ---
    """
  end

  defp solver_variables_text(product_group) do
    case ProductGroup.variables(product_group) do
      [] -> "No solver frame configured for this product group."
      vars ->
        vars
        |> Enum.map(fn v ->
          "- #{v[:key]} (#{v[:label]}): unit=#{v[:unit]}, range=[#{v[:min]}..#{v[:max]}], " <>
          "source=#{v[:source]}, group=#{v[:group]}"
        end)
        |> Enum.join("\n")
    end
  end

  defp solver_routes_text(product_group) do
    case ProductGroup.routes(product_group) do
      [] -> "No routes configured."
      routes ->
        routes
        |> Enum.map(fn r ->
          "- #{r[:key]} (#{r[:name]}): buy=#{r[:buy_variable]}, sell=#{r[:sell_variable]}, " <>
          "freight=#{r[:freight_variable]}, transit=#{r[:typical_transit_days]}d"
        end)
        |> Enum.join("\n")
    end
  end

  defp solver_constraints_text(product_group) do
    case ProductGroup.constraints(product_group) do
      [] -> "No constraints configured."
      constraints ->
        constraints
        |> Enum.map(fn c ->
          "- #{c[:key]} (#{c[:name]}): type=#{c[:type]}, bound=#{c[:bound_variable]}, " <>
          "routes=#{inspect(c[:routes])}"
        end)
        |> Enum.join("\n")
    end
  end

  # ──────────────────────────────────────────────────────────
  # GRAPH API FILE ACCESS
  # ──────────────────────────────────────────────────────────

  defp download_from_graph(drive_id, item_id, graph_token) do
    url = "#{@graph_base}/drives/#{drive_id}/items/#{item_id}/content"

    case Req.get(url,
           headers: [{"authorization", graph_token}],
           receive_timeout: 60_000,
           max_redirects: 3) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Graph file download failed (#{status}): #{inspect(body)}")
        {:error, {:graph_download_failed, status}}

      {:error, reason} ->
        Logger.error("Graph file download error: #{inspect(reason)}")
        {:error, {:graph_download_error, reason}}
    end
  end

  defp extract_text_from_binary(content, filename) do
    ext = Path.extname(filename)
    tmp_path = Path.join(System.tmp_dir!(), "copilot_#{:erlang.unique_integer([:positive])}#{ext}")

    try do
      File.write!(tmp_path, content)
      DocumentReader.read(tmp_path)
    after
      File.rm(tmp_path)
    end
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  # ──────────────────────────────────────────────────────────
  # CONFIG
  # ──────────────────────────────────────────────────────────

  defp get_config do
    endpoint = System.get_env("COPILOT_ENDPOINT")
    api_key = System.get_env("COPILOT_API_KEY")

    cond do
      is_nil(endpoint) or endpoint == "" -> {:error, :endpoint_not_configured}
      is_nil(api_key) or api_key == "" -> {:error, :api_key_not_configured}
      true ->
        {:ok, %{
          endpoint: String.trim_trailing(endpoint, "/"),
          api_key: api_key,
          model: System.get_env("COPILOT_MODEL") || @default_model
        }}
    end
  end

  defp auth_headers(%{api_key: key}), do: [{"authorization", "Bearer #{key}"}]

  defp timeout do
    case System.get_env("COPILOT_TIMEOUT") do
      nil -> @default_timeout
      val ->
        case Integer.parse(val) do
          {n, _} -> n
          :error -> @default_timeout
        end
    end
  end
end
