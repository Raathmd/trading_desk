defmodule TradingDesk.LLM.Pool do
  @moduledoc """
  Supervised GenServer that manages LLM model workers.

  Routes requests to the correct backend:
    - `:local` models → `TradingDesk.LLM.Serving` (Bumblebee / Nx.Serving)
    - `:huggingface` models → `TradingDesk.LLM.HFClient` (HTTP API)

  Callers invoke `generate/3` for a single model or `generate_all/2` to
  fan out to every registered model in parallel.

  The pool tracks per-model health (last success/failure, loading state)
  so callers can degrade gracefully.

  ## Supervision

  Added as a child in `Application`. Individual requests run in
  `Task.Supervisor` so crashes don't take down the pool GenServer.
  """

  use GenServer
  require Logger

  alias TradingDesk.LLM.{ModelRegistry, HFClient, Serving}

  @task_supervisor TradingDesk.LLM.TaskSupervisor

  # ── Public API ────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Generate text from a single model.

  Routes to local Nx.Serving or remote HF API based on the model's provider.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec generate(atom(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate(model_id, prompt, opts \\ []) do
    case ModelRegistry.get(model_id) do
      nil ->
        {:error, :unknown_model}

      model ->
        result = dispatch(model, prompt, opts)
        GenServer.cast(__MODULE__, {:record_result, model_id, result})
        result
    end
  end

  @doc """
  Generate text from ALL registered models in parallel.

  Returns a list of `{model_id, model_name, {:ok, text} | {:error, reason}}`.
  Times out individual models after `timeout` (default 120s).
  """
  @spec generate_all(String.t(), keyword()) :: [{atom(), String.t(), {:ok, String.t()} | {:error, term()}}]
  def generate_all(prompt, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)

    tasks =
      ModelRegistry.list()
      |> Enum.map(fn model ->
        task = Task.Supervisor.async_nolink(@task_supervisor, fn ->
          dispatch(model, prompt, opts)
        end)

        {model, task}
      end)

    Enum.map(tasks, fn {model, task} ->
      result =
        case Task.yield(task, timeout) || Task.shutdown(task) do
          {:ok, res} -> res
          nil -> {:error, :timeout}
          {:exit, reason} -> {:error, {:crash, reason}}
        end

      GenServer.cast(__MODULE__, {:record_result, model.id, result})
      {model.id, model.name, result}
    end)
  end

  @doc "Return health status for all models."
  @spec health() :: map()
  def health do
    GenServer.call(__MODULE__, :health)
  end

  @doc "Return IDs of models that are currently available."
  @spec available_models() :: [atom()]
  def available_models do
    GenServer.call(__MODULE__, :available_models)
  end

  # ── Dispatch ──────────────────────────────────────────────

  defp dispatch(%{provider: :local}, prompt, opts) do
    Serving.run(prompt, opts)
  end

  defp dispatch(%{provider: :huggingface} = model, prompt, opts) do
    HFClient.generate(model, prompt, opts)
  end

  defp dispatch(model, _prompt, _opts) do
    Logger.error("LLM.Pool: unknown provider #{inspect(model.provider)} for #{model.id}")
    {:error, :unknown_provider}
  end

  # ── GenServer callbacks ───────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      models: Map.new(ModelRegistry.list(), fn m ->
        {m.id, %{
          model: m,
          status: :unknown,
          last_success: nil,
          last_error: nil,
          error_count: 0
        }}
      end)
    }

    Logger.info("LLM.Pool started with models: #{inspect(ModelRegistry.ids())}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:record_result, model_id, result}, state) do
    state = update_in(state, [:models, model_id], fn
      nil -> nil
      info ->
        case result do
          {:ok, _} ->
            %{info | status: :ready, last_success: DateTime.utc_now(), error_count: 0}

          {:error, {:model_loading, _}} ->
            %{info | status: :loading, last_error: DateTime.utc_now()}

          {:error, _} ->
            %{info | status: :error, last_error: DateTime.utc_now(), error_count: info.error_count + 1}
        end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = Map.new(state.models, fn {id, info} ->
      {id, %{
        name: info.model.name,
        status: info.status,
        last_success: info.last_success,
        last_error: info.last_error,
        error_count: info.error_count
      }}
    end)

    {:reply, health, state}
  end

  @impl true
  def handle_call(:available_models, _from, state) do
    available =
      state.models
      |> Enum.filter(fn {_id, info} -> info.status in [:unknown, :ready] end)
      |> Enum.map(fn {id, _} -> id end)

    {:reply, available, state}
  end
end
