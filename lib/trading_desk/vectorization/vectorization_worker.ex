defmodule TradingDesk.Vectorization.VectorizationWorker do
  @moduledoc """
  Oban worker that processes events from event_stream into vectorized embeddings.
  1. Fetches the raw event
  2. Gets content template from registry config
  3. Builds a narrative from the event context
  4. Calls Claude API for semantic framing
  5. Generates embedding
  6. Stores in contract_execution_vectors
  7. Marks event as vectorized
  """

  use Oban.Worker, queue: :vectorization, max_attempts: 3

  alias TradingDesk.Repo
  alias TradingDesk.Vectorization.{EventStream, ContractExecutionVector, EventRegistryConfig}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => event_id, "event_type" => event_type, "source_process" => source_process}}) do
    event = Repo.get!(EventStream, event_id)
    config = EventRegistryConfig.get_config(event_type, source_process)

    unless config do
      {:error, "No active registry config for #{event_type}/#{source_process}"}
    else
      narrative = build_narrative(event.context, config.content_template)

      with {:ok, framed_content} <- TradingDesk.Claude.frame_event(narrative, event_type),
           {:ok, embedding} <- TradingDesk.Embeddings.embed(framed_content) do

        {:ok, vector} =
          %ContractExecutionVector{}
          |> ContractExecutionVector.changeset(%{
            product_group: event.context["product_group"] || event.context["product_group_id"],
            source_process: source_process,
            source_event_type: event_type,
            source_event_id: event_id,
            commodity: event.context["commodity"],
            counterparty: event.context["counterparty"],
            decision_narrative: framed_content,
            embedding: embedding,
            market_snapshot: event.context["market_snapshot"],
            trader_id: event.context["trader_id"],
            optimizer_recommendation: extract_optimizer_rec(event.context),
            actual_outcome: event.context["actual_outcome"],
            vectorized_at: DateTime.utc_now()
          })
          |> Repo.insert()

        event
        |> EventStream.changeset(%{vectorized: true, vector_id: vector.id, vectorized_at: DateTime.utc_now()})
        |> Repo.update()

        :ok
      end
    end
  end

  defp build_narrative(context, content_template) when is_map(content_template) do
    sections = content_template["sections"] || []

    Enum.map_join(sections, "\n\n", fn section ->
      label = section["label"] || "SECTION"
      fields = section["fields"] || []

      field_text =
        Enum.map_join(fields, "\n", fn field ->
          value = get_nested(context, String.split(field, "."))
          "  #{field}: #{format_value(value)}"
        end)

      "#{label}:\n#{field_text}"
    end)
  end

  defp build_narrative(context, _template), do: inspect(context, pretty: true)

  defp get_nested(map, [key]) when is_map(map), do: Map.get(map, key)
  defp get_nested(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      sub when is_map(sub) -> get_nested(sub, rest)
      _ -> nil
    end
  end
  defp get_nested(_, _), do: nil

  defp format_value(nil), do: "N/A"
  defp format_value(v) when is_map(v), do: Jason.encode!(v)
  defp format_value(v) when is_list(v), do: Jason.encode!(v)
  defp format_value(v), do: to_string(v)

  defp extract_optimizer_rec(context) do
    cond do
      rec = context["optimizer_pre_recommendation"] -> inspect(rec)
      rec = context["recommendation"] -> inspect(rec)
      rec = context["optimizer_result"] -> inspect(rec)
      true -> nil
    end
  end
end
