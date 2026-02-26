defmodule TradingDesk.LLM.Serving do
  @moduledoc """
  Supervised Nx.Serving for local HuggingFace model inference.

  Downloads and compiles Mistral 7B Instruct on first startup
  (cached in `~/.cache/bumblebee/` thereafter). The compiled computation
  graph is also cached by EXLA, so subsequent starts are fast.

  ## How it works

  1. On `mix deps.get && mix compile`, Bumblebee + EXLA are compiled.
  2. On first application start, `build_serving/0` downloads the model
     weights from HuggingFace Hub (~14 GB fp32, ~7 GB bf16).
  3. EXLA compiles the computation graph for the configured batch size
     and sequence length (one-time, cached).
  4. `Nx.Serving` handles batching and concurrent requests automatically.

  ## Adding models

  To swap or add models, update `@model_repo` and `@model_opts` below,
  or add another child spec to the supervision tree pointing at a
  different repo.

  ## Requirements

  - ~8 GB RAM for bf16 Mistral 7B (more for fp32)
  - EXLA C++ build toolchain (cmake, python3) on first compile
  - Optional: CUDA/ROCm for GPU acceleration (falls back to CPU)

  ## Usage

      TradingDesk.LLM.Serving.run("Explain this trading scenario...")
      #=> {:ok, "The solver allocated..."}
  """

  require Logger

  # ── Model Configuration ───────────────────────────────────
  # Change these to swap the model at compile time.

  @model_repo {:hf, "mistralai/Mistral-7B-Instruct-v0.3"}
  @model_name "Mistral 7B Instruct (Q4)"
  @model_type :bf16
  @max_new_tokens 1024
  @batch_size 1
  @sequence_length 2048
  @serving_name __MODULE__

  # ── Public API ────────────────────────────────────────────

  @doc """
  Run text generation on the local model.

  Wraps the prompt in Mistral instruct format, sends it through the
  compiled Nx.Serving, and returns the generated text.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(prompt, _opts \\ []) do
    instruct_prompt = "<s>[INST] #{prompt} [/INST]"

    try do
      %{results: [%{text: text} | _]} =
        Nx.Serving.batched_run(@serving_name, instruct_prompt)

      {:ok, String.trim(text)}
    rescue
      e ->
        Logger.error("LLM.Serving inference failed: #{Exception.message(e)}")
        {:error, {:inference_error, Exception.message(e)}}
    catch
      :exit, reason ->
        Logger.error("LLM.Serving not available: #{inspect(reason)}")
        {:error, :serving_unavailable}
    end
  end

  @doc "Return the human-readable model name."
  @spec model_name() :: String.t()
  def model_name, do: @model_name

  @doc "Return the HuggingFace repo tuple."
  @spec model_repo() :: {:hf, String.t()}
  def model_repo, do: @model_repo

  # ── Supervision ───────────────────────────────────────────

  @doc """
  Child spec for the supervision tree.

  Starts the Nx.Serving process under the given name. The model is
  downloaded and compiled during `start_link` (blocking — first start
  may take several minutes).
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(_opts) do
    Logger.info("LLM.Serving: loading #{@model_name} from #{inspect(@model_repo)}...")
    Logger.info("LLM.Serving: type=#{@model_type}, batch=#{@batch_size}, seq_len=#{@sequence_length}")

    serving = build_serving()

    Logger.info("LLM.Serving: model compiled and ready for inference")
    Nx.Serving.start_link(serving: serving, name: @serving_name, batch_timeout: 100)
  end

  # ── Private ───────────────────────────────────────────────

  defp build_serving do
    {:ok, model_info} = Bumblebee.load_model(@model_repo, type: @model_type)
    {:ok, tokenizer} = Bumblebee.load_tokenizer(@model_repo)
    {:ok, generation_config} = Bumblebee.load_generation_config(@model_repo)

    generation_config =
      Bumblebee.configure(generation_config, %{
        max_new_tokens: @max_new_tokens
      })

    Bumblebee.Text.generation(model_info, tokenizer, generation_config,
      compile: [batch_size: @batch_size, sequence_length: @sequence_length],
      defn_options: [compiler: EXLA]
    )
  end
end
