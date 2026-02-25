defmodule TradingDesk.LLM.HFClient do
  @moduledoc """
  HTTP client for the HuggingFace Inference API.

  Uses `Req` (already a dependency) to call models hosted on HF.
  Handles the HF-specific request/response format and error cases
  (model loading, rate limits, etc.).
  """

  require Logger

  @receive_timeout 120_000

  @doc """
  Send a prompt to a HuggingFace model and return the generated text.

  `model` is a map from `ModelRegistry` containing at least:
    - `:endpoint` — the HF inference URL
    - `:max_tokens` — generation limit
    - `:temperature` — sampling temperature

  Options:
    - `:max_tokens` — override the model default
    - `:system` — optional system prompt (prepended for instruct models)

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec generate(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(model, prompt, opts \\ []) do
    api_key = System.get_env("HUGGINGFACE_API_KEY") || System.get_env("HF_TOKEN")

    if is_nil(api_key) or api_key == "" do
      Logger.warning("HFClient: HUGGINGFACE_API_KEY not set, skipping #{model.id}")
      {:error, :no_api_key}
    else
      max_tokens = Keyword.get(opts, :max_tokens, model.max_tokens)
      system = Keyword.get(opts, :system, nil)

      full_prompt = build_instruct_prompt(prompt, system)

      body = %{
        inputs: full_prompt,
        parameters: %{
          max_new_tokens: max_tokens,
          temperature: model.temperature,
          return_full_text: false
        }
      }

      case Req.post(model.endpoint,
        json: body,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: @receive_timeout
      ) do
        {:ok, %{status: 200, body: [%{"generated_text" => text} | _]}} ->
          {:ok, String.trim(text)}

        {:ok, %{status: 200, body: %{"generated_text" => text}}} ->
          {:ok, String.trim(text)}

        # Some models return a plain list of generated texts
        {:ok, %{status: 200, body: body}} when is_list(body) ->
          case List.first(body) do
            %{"generated_text" => text} -> {:ok, String.trim(text)}
            _ ->
              Logger.error("HFClient: unexpected 200 body from #{model.id}: #{inspect(body)}")
              {:error, :unexpected_response}
          end

        {:ok, %{status: 503, body: body}} ->
          # Model is loading — HF returns estimated_time
          wait = extract_estimated_time(body)
          Logger.info("HFClient: #{model.id} loading, estimated #{wait}s")
          {:error, {:model_loading, wait}}

        {:ok, %{status: 429}} ->
          Logger.warning("HFClient: rate limited on #{model.id}")
          {:error, :rate_limited}

        {:ok, %{status: status, body: body}} ->
          Logger.error("HFClient: #{model.id} returned #{status}: #{inspect(body)}")
          {:error, {:api_error, status}}

        {:error, reason} ->
          Logger.error("HFClient: request to #{model.id} failed: #{inspect(reason)}")
          {:error, :request_failed}
      end
    end
  end

  # Build a prompt in Mistral instruct format: [INST] ... [/INST]
  defp build_instruct_prompt(prompt, nil) do
    "<s>[INST] #{prompt} [/INST]"
  end

  defp build_instruct_prompt(prompt, system) do
    "<s>[INST] <<SYS>>\n#{system}\n<</SYS>>\n\n#{prompt} [/INST]"
  end

  defp extract_estimated_time(%{"estimated_time" => t}) when is_number(t), do: t
  defp extract_estimated_time(_), do: 30
end
