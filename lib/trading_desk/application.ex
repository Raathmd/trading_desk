defmodule TradingDesk.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Initialise lightweight ETS tables before any supervised process starts
    TradingDesk.Notifications.init_ets()

    children = [
      {Finch, name: Swoosh.Finch},
      TradingDesk.Repo,
      TradingDesk.DB.SnapshotLog,
      {Phoenix.PubSub, name: TradingDesk.PubSub},
      TradingDesk.Config.DeltaConfig,
      TradingDesk.Data.LiveState,
      TradingDesk.Data.AmmoniaPrices,
      TradingDesk.Data.Poller,
      TradingDesk.Solver.Port,
      TradingDesk.Solver.SolveAuditStore,
      TradingDesk.Scenarios.Store,
      TradingDesk.Scenarios.AutoRunner,
      TradingDesk.Decisions.DecisionLedger,
      TradingDesk.Contracts.Store,
      TradingDesk.Contracts.CurrencyTracker,
      TradingDesk.Contracts.NetworkScanner,
      TradingDesk.Contracts.SapRefreshScheduler,
      {Task.Supervisor, name: TradingDesk.Contracts.TaskSupervisor},
      # Local LLM inference — one Nx.Serving per enabled model
      # Configure :llm_enabled_models in config to control which load
    ] ++
      Enum.map(TradingDesk.LLM.ModelRegistry.local_models(), fn model ->
        {TradingDesk.LLM.Serving, model}
      end) ++
    [
      {Task.Supervisor, name: TradingDesk.LLM.TaskSupervisor},
      TradingDesk.LLM.Pool,
      TradingDesk.Data.AIS.AISStreamConnector,
      TradingDesk.Endpoint
    ]

    opts = [strategy: :one_for_one, name: TradingDesk.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
