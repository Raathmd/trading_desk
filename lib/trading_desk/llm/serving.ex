defmodule TradingDesk.LLM.Serving do
  @moduledoc """
  Supervised Nx.Serving for local HuggingFace model inference.

  Supports **multiple model instances** — each registered local model gets
  its own named Nx.Serving process. Models are downloaded from HuggingFace
  Hub on first start and cached in `~/.cache/bumblebee/`.

  ## How it works

  1. `Application` starts one `Serving` child per enabled local model.
  2. Each child downloads weights, compiles the EXLA graph, and registers
     under a unique process name: `TradingDesk.LLM.Serving.<model_id>`.
  3. `run/3` routes inference to the correct named process.
  4. Prompt formatting is applied per-model based on `:prompt_format`.

  ## Requirements

  - ~8 GB RAM per 7B model in bf16
  - EXLA C++ build toolchain (cmake, python3) on first compile
  - Optional: CUDA/ROCm for GPU acceleration (falls back to CPU)
  """

  require Logger

  alias TradingDesk.LLM.ModelRegistry

  @batch_size 1
  @batch_timeout 100

  # ── Public API ────────────────────────────────────────────

  @doc """
  Run text generation on a specific local model.

  Looks up the named Serving process for `model_id`, formats the prompt
  using the model's `:prompt_format`, and returns the generated text.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec run(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(model_id, prompt, _opts \\ []) do
    name = serving_name(model_id)
    model = ModelRegistry.get(model_id)
    format = if model, do: Map.get(model, :prompt_format, :mistral), else: :mistral

    formatted = format_prompt(format, prompt)

    try do
      %{results: [%{text: text} | _]} =
        Nx.Serving.batched_run(name, formatted)

      {:ok, String.trim(text)}
    rescue
      e ->
        Logger.error("LLM.Serving(#{model_id}) inference failed: #{Exception.message(e)}")
        {:error, {:inference_error, Exception.message(e)}}
    catch
      :exit, reason ->
        Logger.error("LLM.Serving(#{model_id}) not available: #{inspect(reason)}")
        {:error, :serving_unavailable}
    end
  end

  @doc "Return the process name for a given model ID."
  @spec serving_name(atom()) :: atom()
  def serving_name(model_id) do
    :"#{__MODULE__}.#{model_id}"
  end

  @doc "Return the human-readable model name (default model, for backwards compat)."
  @spec model_name() :: String.t()
  def model_name do
    case ModelRegistry.default() do
      nil -> "No model loaded"
      m -> m.name
    end
  end

  @doc "Return the HuggingFace repo tuple (default model, for backwards compat)."
  @spec model_repo() :: {:hf, String.t()} | nil
  def model_repo do
    case ModelRegistry.default() do
      nil -> nil
      m -> m.model_repo
    end
  end

  # ── Supervision ───────────────────────────────────────────

  @doc """
  Child spec for the supervision tree.

  Accepts a model map from `ModelRegistry`. Each model gets its own
  Nx.Serving process with a unique name.
  """
  def child_spec(model) when is_map(model) do
    %{
      id: {__MODULE__, model.id},
      start: {__MODULE__, :start_link, [model]},
      type: :worker,
      restart: :permanent
    }
  end

  # Backwards-compatible child_spec for bare module reference
  def child_spec(_opts) do
    case ModelRegistry.default() do
      nil ->
        %{id: __MODULE__, start: {__MODULE__, :start_link_noop, []}, type: :worker}

      model ->
        child_spec(model)
    end
  end

  def start_link(model) when is_map(model) do
    name = serving_name(model.id)
    repo = model.model_repo
    model_type = Map.get(model, :model_type, :bf16)
    max_tokens = Map.get(model, :max_tokens, 1024)
    seq_len = Map.get(model, :sequence_length, 2048)

    Logger.info("LLM.Serving: loading #{model.name} from #{inspect(repo)}...")
    Logger.info("LLM.Serving: id=#{model.id}, type=#{model_type}, batch=#{@batch_size}, seq_len=#{seq_len}")

    serving = build_serving(repo, model_type, max_tokens, seq_len)

    Logger.info("LLM.Serving: #{model.name} compiled and ready as #{name}")
    Nx.Serving.start_link(serving: serving, name: name, batch_timeout: @batch_timeout)
  end

  # Backwards-compatible start_link for bare module reference
  def start_link(_opts) do
    case ModelRegistry.default() do
      nil ->
        Logger.warning("LLM.Serving: no models configured, skipping")
        :ignore

      model ->
        start_link(model)
    end
  end

  @doc false
  def start_link_noop, do: :ignore

  # ── Private ───────────────────────────────────────────────

  defp build_serving(repo, model_type, max_tokens, seq_len) do
    {:ok, model_info} = Bumblebee.load_model(repo, type: model_type)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(repo)
    {:ok, generation_config} = Bumblebee.load_generation_config(repo)

    generation_config =
      Bumblebee.configure(generation_config,
        max_new_tokens: max_tokens
      )

    Bumblebee.Text.generation(model_info, tokenizer, generation_config,
      compile: [batch_size: @batch_size, sequence_length: seq_len],
      defn_options: [compiler: EXLA]
    )
  end

  # ── Prompt formatting ────────────────────────────────────

  defp format_prompt(:mistral, prompt) do
    "<s>[INST] #{prompt} [/INST]"
  end

  defp format_prompt(:zephyr, prompt) do
    "<|user|>\n#{prompt}</s>\n<|assistant|>"
  end

  defp format_prompt(:phi3, prompt) do
    "<|user|>\n#{prompt}<|end|>\n<|assistant|>"
  end

  defp format_prompt(_format, prompt), do: prompt
end
