defmodule TradingDesk.EventEmitter do
  @moduledoc """
  Non-blocking event emission for the cross-process vectorization pipeline.
  Checks event_registry_config to determine if event should be vectorized.
  Inserts into event_stream table and queues Oban job if vectorization enabled.
  """

  alias TradingDesk.Repo
  alias TradingDesk.Vectorization.{EventStream, EventRegistryConfig, VectorizationWorker}

  def emit_event(event_type, context, source_process \\ "trading_desk") do
    {:ok, event} =
      %EventStream{}
      |> EventStream.changeset(%{
        event_type: event_type,
        source_process: source_process,
        context: context
      })
      |> Repo.insert()

    # Check registry: should this event be vectorized?
    config = EventRegistryConfig.get_config(event_type, source_process)

    if config && config.should_vectorize do
      %{event_id: event.id, event_type: event_type, source_process: source_process}
      |> VectorizationWorker.new(queue: :vectorization)
      |> Oban.insert()
    end

    {:ok, event}
  end
end
