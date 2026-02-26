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
    description: String.t()
  }

  @models [
    %{
      id: :mistral_7b,
      name: "Mistral 7B Instruct (local)",
      provider: :local,
      model_id: "mistralai/Mistral-7B-Instruct-v0.3",
      max_tokens: 1024,
      description: "Local Mistral 7B via Bumblebee — downloaded and compiled at startup"
    }
    # To add more models at compile time, append here:
    #
    # %{
    #   id: :phi_3_mini,
    #   name: "Phi-3 Mini (local)",
    #   provider: :local,
    #   model_id: "microsoft/Phi-3-mini-4k-instruct",
    #   max_tokens: 1024,
    #   description: "Local Phi-3 Mini via Bumblebee"
    # }
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
