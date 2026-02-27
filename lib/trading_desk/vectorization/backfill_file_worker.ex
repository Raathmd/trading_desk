defmodule TradingDesk.Vectorization.BackfillFileWorker do
  @moduledoc """
  Oban worker that processes a single uploaded SAP history file.
  Parses contracts, calls Claude API for semantic framing, generates embeddings,
  and stores vectors. Broadcasts real-time progress via PubSub.
  """

  use Oban.Worker, queue: :backfill, max_attempts: 2

  require Logger

  alias TradingDesk.Repo
  alias TradingDesk.Vectorization.{BackfillFileLog, BackfillContractLog, ContractExecutionVector, BackfillJob}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"job_id" => job_id, "file_path" => file_path, "filename" => filename, "file_size" => file_size}}) do
    # Create file log entry
    {:ok, file_log} =
      %BackfillFileLog{}
      |> BackfillFileLog.changeset(%{
        backfill_job_id: job_id,
        filename: filename,
        file_size_bytes: file_size,
        file_type: Path.extname(filename) |> String.trim_leading("."),
        status: "parsing",
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    broadcast(job_id, :file_status, %{filename: filename, status: "parsing"})

    # Parse file
    contracts = parse_file(file_path, Path.extname(filename))

    file_log
    |> BackfillFileLog.changeset(%{row_count: length(contracts), contracts_parsed: length(contracts), status: "framing"})
    |> Repo.update()

    # Process each contract
    {framed, vectorized, errors} =
      contracts
      |> Enum.with_index(1)
      |> Enum.reduce({0, 0, 0}, fn {contract_data, row_num}, {f, v, e} ->
        {:ok, contract_log} =
          %BackfillContractLog{}
          |> BackfillContractLog.changeset(%{
            backfill_file_log_id: file_log.id,
            row_number: row_num,
            sap_contract_reference: contract_data["contract_reference"] || "Row #{row_num}",
            sap_contract_data: contract_data,
            status: "framing"
          })
          |> Repo.insert()

        case TradingDesk.Claude.frame_historical_contract(contract_data) do
          {:ok, llm_output} ->
            contract_log
            |> BackfillContractLog.changeset(%{llm_framing_output: llm_output, status: "framed"})
            |> Repo.update()

            broadcast(job_id, :contract_framed, %{
              filename: filename, row: row_num,
              sap_reference: contract_data["contract_reference"] || "Row #{row_num}",
              llm_output: llm_output, status: "framed"
            })

            case TradingDesk.Embeddings.embed(llm_output) do
              {:ok, embedding} ->
                job = Repo.get!(BackfillJob, job_id)

                {:ok, vector} =
                  %ContractExecutionVector{}
                  |> ContractExecutionVector.changeset(%{
                    product_group: job.product_group,
                    source_process: "sap_backfill",
                    source_event_type: "historical_contract_ingestion",
                    source_event_id: job_id,
                    commodity: contract_data["commodity"],
                    counterparty: contract_data["counterparty"],
                    decision_narrative: llm_output,
                    embedding: embedding,
                    market_snapshot: infer_market_state(contract_data),
                    actual_outcome: extract_outcome(contract_data),
                    vectorized_at: DateTime.utc_now()
                  })
                  |> Repo.insert()

                contract_log
                |> BackfillContractLog.changeset(%{vector_id: vector.id, status: "vectorized", processed_at: DateTime.utc_now()})
                |> Repo.update()

                broadcast(job_id, :contract_vectorized, %{filename: filename, row: row_num, status: "vectorized"})
                {f + 1, v + 1, e}

              {:error, reason} ->
                Logger.warning("Embedding failed for #{filename} row #{row_num}: #{inspect(reason)}")
                contract_log
                |> BackfillContractLog.changeset(%{error_message: "Embedding failed: #{inspect(reason)}", status: "error"})
                |> Repo.update()
                {f + 1, v, e + 1}
            end

          {:error, reason} ->
            contract_log
            |> BackfillContractLog.changeset(%{error_message: inspect(reason), status: "error"})
            |> Repo.update()

            broadcast(job_id, :error, %{filename: filename, row: row_num, error: inspect(reason)})
            {f, v, e + 1}
        end
      end)

    # Update file log
    file_log
    |> BackfillFileLog.changeset(%{
      llm_calls_made: framed,
      vectors_created: vectorized,
      errors: if(errors > 0, do: "#{errors} errors", else: nil),
      status: "complete",
      completed_at: DateTime.utc_now()
    })
    |> Repo.update()

    # Check if all files in job are complete
    check_job_completion(job_id)

    :ok
  end

  defp parse_file(file_path, ext) when ext in [".csv", ".CSV"] do
    file_path
    |> File.stream!()
    |> Stream.drop(1)
    |> Enum.map(fn line ->
      # Basic CSV parsing — split by comma, map to expected keys
      parts = String.split(String.trim(line), ",")
      %{
        "contract_reference" => Enum.at(parts, 0, ""),
        "counterparty" => Enum.at(parts, 1, ""),
        "commodity" => Enum.at(parts, 2, ""),
        "quantity" => Enum.at(parts, 3, ""),
        "price" => Enum.at(parts, 4, ""),
        "delivery_start" => Enum.at(parts, 5, ""),
        "delivery_end" => Enum.at(parts, 6, ""),
        "incoterm" => Enum.at(parts, 7, ""),
        "port" => Enum.at(parts, 8, ""),
        "status" => Enum.at(parts, 9, "")
      }
    end)
  end

  defp parse_file(file_path, ext) when ext in [".json", ".JSON"] do
    case File.read(file_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_list(data) -> data
          {:ok, %{"contracts" => contracts}} when is_list(contracts) -> contracts
          {:ok, data} when is_map(data) -> [data]
          _ -> []
        end
      _ -> []
    end
  end

  defp parse_file(_file_path, _ext) do
    # Unsupported format — return empty
    Logger.warning("Unsupported file format")
    []
  end

  defp infer_market_state(contract_data) do
    %{
      "inferred_from" => "historical_backfill",
      "contract_date" => contract_data["contract_date"] || contract_data["delivery_start"],
      "price_at_time" => contract_data["price"]
    }
  end

  defp extract_outcome(contract_data) do
    %{
      "status" => contract_data["status"],
      "actual_quantity" => contract_data["actual_quantity"],
      "actual_price" => contract_data["actual_price"]
    }
  end

  defp check_job_completion(job_id) do
    import Ecto.Query

    total = Repo.aggregate(from(f in BackfillFileLog, where: f.backfill_job_id == ^job_id), :count)
    complete = Repo.aggregate(from(f in BackfillFileLog, where: f.backfill_job_id == ^job_id and f.status == "complete"), :count)

    if total > 0 and total == complete do
      vectors_created = Repo.aggregate(from(f in BackfillFileLog, where: f.backfill_job_id == ^job_id), :sum, :vectors_created) || 0
      contracts_parsed = Repo.aggregate(from(f in BackfillFileLog, where: f.backfill_job_id == ^job_id), :sum, :contracts_parsed) || 0

      job = Repo.get!(BackfillJob, job_id)
      job
      |> BackfillJob.changeset(%{
        status: "completed",
        total_contracts_parsed: contracts_parsed,
        total_vectors_created: vectors_created,
        completed_at: DateTime.utc_now()
      })
      |> Repo.update()

      Phoenix.PubSub.broadcast(TradingDesk.PubSub, "backfill:#{job_id}", {:backfill_complete, %{
        job_id: job_id,
        total_contracts: contracts_parsed,
        total_vectors: vectors_created
      }})
    end
  end

  defp broadcast(job_id, type, data) do
    Phoenix.PubSub.broadcast(TradingDesk.PubSub, "backfill:#{job_id}", {:backfill_update, %{type: type, data: data}})
  end
end
