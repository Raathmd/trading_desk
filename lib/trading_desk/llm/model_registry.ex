defmodule TradingDesk.LLM.ModelRegistry do
  @moduledoc """
  Registry of available LLM models for the trading desk.

  All models run **locally** via Bumblebee / Nx.Serving — no data leaves the
  machine. Each model downloads its weights from HuggingFace Hub on first
  start and caches them in `~/.cache/bumblebee/`.

  ## Memory requirements (bf16)

  | Model              | Disk cache | RAM at inference |
  |--------------------|-----------|------------------|
  | Mistral 7B         | ~7 GB     | ~8 GB            |
  | Zephyr 7B Beta     | ~7 GB     | ~8 GB            |

  Running both simultaneously requires **~16 GB free RAM**. If your machine
  has 16 GB total, enable only one model via the `:llm_enabled_models` config:

      # config/config.exs — load only Mistral (default)
      config :trading_desk, :llm_enabled_models, [:mistral_7b]

      # Load both models (needs ≥20 GB RAM)
      config :trading_desk, :llm_enabled_models, [:mistral_7b, :zephyr_7b]

  If `:llm_enabled_models` is not set, **all** local models are loaded.

  ## Adding models

  Append to `@models` below. The model must use a Bumblebee-supported
  architecture (Llama, Mistral, GPT-2 families). The supervised pool and
  Serving instances pick up new entries automatically.
  """

  @type model :: %{
    id: atom(),
    name: String.t(),
    provider: :local | :huggingface,
    model_id: String.t(),
    model_repo: {:hf, String.t()},
    model_type: atom(),
    max_tokens: pos_integer(),
    sequence_length: pos_integer(),
    prompt_format: atom(),
    temperature: float(),
    endpoint: String.t() | nil,
    description: String.t()
  }

  @models [
    %{
      id: :mistral_7b,
      name: "Mistral 7B Instruct",
      provider: :local,
      model_id: "mistralai/Mistral-7B-Instruct-v0.3",
      model_repo: {:hf, "mistralai/Mistral-7B-Instruct-v0.3"},
      model_type: :bf16,
      max_tokens: 1024,
      sequence_length: 2048,
      prompt_format: :mistral,
      temperature: 0.7,
      endpoint: nil,
      description: "Strong general-purpose reasoning, Mistral instruct format (~8 GB RAM)"
    },
    %{
      id: :zephyr_7b,
      name: "Zephyr 7B Beta",
      provider: :local,
      model_id: "HuggingFaceH4/zephyr-7b-beta",
      model_repo: {:hf, "HuggingFaceH4/zephyr-7b-beta"},
      model_type: :bf16,
      max_tokens: 1024,
      sequence_length: 2048,
      prompt_format: :zephyr,
      temperature: 0.7,
      endpoint: nil,
      description: "Fine-tuned for clear, structured instruction following (~8 GB RAM)"
    }
  ]

  @doc "Return all registered models."
  @spec list() :: [model()]
  def list do
    case Application.get_env(:trading_desk, :llm_enabled_models) do
      nil -> @models
      ids when is_list(ids) -> Enum.filter(@models, &(&1.id in ids))
    end
  end

  @doc "Return all models regardless of enabled config (for UI display)."
  @spec all() :: [model()]
  def all, do: @models

  @doc "Return model IDs only (enabled models)."
  @spec ids() :: [atom()]
  def ids, do: Enum.map(list(), & &1.id)

  @doc "Return only local models (enabled)."
  @spec local_models() :: [model()]
  def local_models, do: Enum.filter(list(), &(&1.provider == :local))

  @doc "Return only remote (HuggingFace API) models (enabled)."
  @spec remote_models() :: [model()]
  def remote_models, do: Enum.filter(list(), &(&1.provider == :huggingface))

  @doc "Look up a model by its atom ID (from full registry, not just enabled)."
  @spec get(atom()) :: model() | nil
  def get(id) do
    Enum.find(@models, &(&1.id == id))
  end

  @doc "Return the first (default) model."
  @spec default() :: model()
  def default, do: List.first(list())
end
