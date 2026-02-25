defmodule TradingDesk.LLM.ModelRegistry do
  @moduledoc """
  Registry of available LLM models for the trading desk.

  Each model entry describes how to reach the model (HuggingFace Inference API
  or local endpoint), what it's good at, and the request/response format it
  expects.

  To add a new model, append to `@models` below and the supervised pool will
  pick it up at next compile.
  """

  @type model :: %{
    id: atom(),
    name: String.t(),
    provider: :huggingface | :local,
    endpoint: String.t(),
    model_id: String.t(),
    max_tokens: pos_integer(),
    temperature: float(),
    description: String.t()
  }

  @models [
    %{
      id: :mistral_7b,
      name: "Mistral 7B Instruct (Q4)",
      provider: :huggingface,
      endpoint: "https://api-inference.huggingface.co/models/mistralai/Mistral-7B-Instruct-v0.3",
      model_id: "mistralai/Mistral-7B-Instruct-v0.3",
      max_tokens: 1024,
      temperature: 0.3,
      description: "Fast quantized Mistral 7B — good for concise trading explanations"
    }
  ]

  @doc "Return all registered models."
  @spec list() :: [model()]
  def list, do: @models

  @doc "Return model IDs only."
  @spec ids() :: [atom()]
  def ids, do: Enum.map(@models, & &1.id)

  @doc "Look up a model by its atom ID."
  @spec get(atom()) :: model() | nil
  def get(id) do
    Enum.find(@models, &(&1.id == id))
  end

  @doc "Return the first (default) model."
  @spec default() :: model()
  def default, do: List.first(@models)
end
