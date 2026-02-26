defmodule TradingDesk.LLM.ModelRegistry do
  @moduledoc """
  Registry of available LLM models for the trading desk.

  Each model entry describes how to reach the model:
    - `provider: :local` — runs through Bumblebee / Nx.Serving on this node
    - `provider: :huggingface` — calls the HuggingFace Inference API over HTTP

  The local serving (Mistral 7B) is downloaded and compiled on first startup.
  To add a new model at compile time, append to `@models` below — the
  supervised pool picks it up automatically.
  """

  @type model :: %{
    id: atom(),
    name: String.t(),
    provider: :local | :huggingface,
    model_id: String.t(),
    max_tokens: pos_integer(),
    description: String.t(),
    endpoint: String.t() | nil,
    temperature: float() | nil,
    prompt_format: atom()
  }

  @hf_base "https://api-inference.huggingface.co/models/"

  @models [
    %{
      id: :mistral_7b,
      name: "Mistral 7B Instruct (local)",
      provider: :local,
      model_id: "mistralai/Mistral-7B-Instruct-v0.3",
      max_tokens: 1024,
      description: "Local Mistral 7B via Bumblebee — downloaded and compiled at startup",
      endpoint: nil,
      temperature: 0.7,
      prompt_format: :mistral
    },
    %{
      id: :mixtral_8x7b,
      name: "Mixtral 8x7B Instruct",
      provider: :huggingface,
      model_id: "mistralai/Mixtral-8x7B-Instruct-v0.1",
      endpoint: @hf_base <> "mistralai/Mixtral-8x7B-Instruct-v0.1",
      max_tokens: 1024,
      temperature: 0.7,
      prompt_format: :mistral,
      description: "Mixtral MoE via HF API — strong reasoning, same instruct format as Mistral"
    },
    %{
      id: :zephyr_7b,
      name: "Zephyr 7B Beta",
      provider: :huggingface,
      model_id: "HuggingFaceH4/zephyr-7b-beta",
      endpoint: @hf_base <> "HuggingFaceH4/zephyr-7b-beta",
      max_tokens: 1024,
      temperature: 0.7,
      prompt_format: :zephyr,
      description: "Zephyr 7B via HF API — fine-tuned for instruction following and analysis"
    },
    %{
      id: :phi3_medium,
      name: "Phi-3 Medium 14B",
      provider: :huggingface,
      model_id: "microsoft/Phi-3-medium-4k-instruct",
      endpoint: @hf_base <> "microsoft/Phi-3-medium-4k-instruct",
      max_tokens: 1024,
      temperature: 0.7,
      prompt_format: :phi3,
      description: "Phi-3 Medium via HF API — efficient model with strong numerical reasoning"
    }
  ]

  @doc "Return all registered models."
  @spec list() :: [model()]
  def list, do: @models

  @doc "Return model IDs only."
  @spec ids() :: [atom()]
  def ids, do: Enum.map(@models, & &1.id)

  @doc "Return only local models."
  @spec local_models() :: [model()]
  def local_models, do: Enum.filter(@models, &(&1.provider == :local))

  @doc "Return only remote (HuggingFace API) models."
  @spec remote_models() :: [model()]
  def remote_models, do: Enum.filter(@models, &(&1.provider == :huggingface))

  @doc "Look up a model by its atom ID."
  @spec get(atom()) :: model() | nil
  def get(id) do
    Enum.find(@models, &(&1.id == id))
  end

  @doc "Return the first (default) model."
  @spec default() :: model()
  def default, do: List.first(@models)
end
