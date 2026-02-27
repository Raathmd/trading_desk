defmodule TradingDesk.Vectorization.VectorQuery do
  @moduledoc """
  Direct pgvector similarity search against contract_execution_vectors.
  Called during pre-solve to find historically similar deals.
  """

  import Ecto.Query
  alias TradingDesk.Repo
  alias TradingDesk.Vectorization.ContractExecutionVector

  @doc """
  Find similar deals using pgvector cosine similarity.
  Returns up to `limit` results ordered by similarity.
  """
  def find_similar_deals(market_snapshot, trader_inputs, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    product_group = trader_inputs["product_group"] || trader_inputs[:product_group]

    query_text = """
    Commodity: #{trader_inputs["commodity"] || trader_inputs[:commodity]}
    Market: #{Jason.encode!(market_snapshot || %{})}
    Trader intent: #{Jason.encode!(trader_inputs || %{})}
    """

    case TradingDesk.Embeddings.embed(query_text) do
      {:ok, query_embedding} ->
        results =
          from(v in ContractExecutionVector,
            where: v.product_group == ^product_group,
            order_by: fragment("embedding <=> ?", ^query_embedding),
            limit: ^limit,
            select: %{
              id: v.id,
              narrative: v.decision_narrative,
              source_process: v.source_process,
              source_event_type: v.source_event_type,
              commodity: v.commodity,
              counterparty: v.counterparty,
              market_snapshot: v.market_snapshot,
              optimizer_recommendation: v.optimizer_recommendation,
              actual_outcome: v.actual_outcome,
              inserted_at: v.inserted_at
            }
          )
          |> Repo.all()

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
