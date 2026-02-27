defmodule TradingDesk.Embeddings do
  @moduledoc """
  Generates vector embeddings for text content.
  Uses the Anthropic/Voyage API or falls back to a local model.
  Returns {:ok, [float()]} or {:error, reason}.
  """

  require Logger

  @embedding_dim 1536

  @doc "Generate an embedding vector for the given text."
  def embed(text) when is_binary(text) and byte_size(text) > 0 do
    case voyage_embed(text) do
      {:ok, _} = result -> result
      {:error, reason} ->
        Logger.warning("Voyage embedding failed (#{inspect(reason)}), using deterministic fallback")
        {:ok, deterministic_fallback(text)}
    end
  end

  def embed(_), do: {:error, :empty_text}

  @doc "Return the configured embedding dimension."
  def dimension, do: @embedding_dim

  # Voyage AI embeddings (recommended by Anthropic for use with Claude)
  defp voyage_embed(text) do
    api_key = System.get_env("VOYAGE_API_KEY")

    if api_key do
      case Req.post("https://api.voyageai.com/v1/embeddings",
        json: %{input: [text], model: "voyage-3"},
        headers: [
          {"Authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: 30_000
      ) do
        {:ok, %{status: 200, body: %{"data" => [%{"embedding" => embedding}]}}} ->
          {:ok, embedding}

        {:ok, %{status: status, body: body}} ->
          {:error, "Voyage API returned #{status}: #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_voyage_api_key}
    end
  end

  # Deterministic fallback: hash-based pseudo-embedding for development/testing.
  # NOT suitable for real similarity search — use only when no API key is configured.
  defp deterministic_fallback(text) do
    # Use :crypto.hash to produce deterministic bytes from text
    hash = :crypto.hash(:sha512, text)
    # Extend to fill the embedding dimension
    bytes = Stream.cycle(:binary.bin_to_list(hash)) |> Enum.take(@embedding_dim * 4)
    # Convert to floats in [-1, 1] range
    bytes
    |> Enum.chunk_every(4)
    |> Enum.map(fn chunk ->
      <<val::float-32>> = :binary.list_to_bin(chunk)
      # Normalize to [-1, 1]
      :math.tanh(val)
    end)
    |> Enum.take(@embedding_dim)
  end
end
