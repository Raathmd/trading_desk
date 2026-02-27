defmodule TradingDesk.DB.SolveLlmOutput do
  @moduledoc """
  Ecto schema for LLM outputs associated with a solve run.

  Composite primary key: {solve_audit_id, model_id}.
  Each row captures the output from one LLM model during one phase
  of a solve pipeline run (presolve framing, presolve explanation,
  or postsolve explanation).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @primary_key false
  schema "solve_llm_outputs" do
    field :solve_audit_id, :string, primary_key: true
    field :model_id, :string, primary_key: true
    field :phase, :string
    field :model_name, :string
    field :output_text, :string
    field :output_json, :map
    field :status, :string, default: "ok"
    field :error_reason, :string
    field :duration_ms, :integer

    timestamps(type: :utc_datetime)
  end

  @required ~w(solve_audit_id model_id phase status)a
  @optional ~w(model_name output_text output_json error_reason duration_ms)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:phase, ~w(presolve_framing presolve_explanation postsolve_explanation))
    |> validate_inclusion(:status, ~w(ok error))
  end

  @doc "Returns the set of solve_audit_ids that have at least one LLM output row."
  def audit_ids_with_outputs(audit_ids) when is_list(audit_ids) do
    from(o in __MODULE__,
      where: o.solve_audit_id in ^audit_ids,
      select: o.solve_audit_id,
      distinct: true
    )
    |> TradingDesk.Repo.all()
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  @doc "Returns all LLM outputs for a given solve_audit_id."
  def list_by_audit(solve_audit_id) do
    from(o in __MODULE__,
      where: o.solve_audit_id == ^solve_audit_id,
      order_by: [asc: o.phase, asc: o.model_id]
    )
    |> TradingDesk.Repo.all()
  rescue
    _ -> []
  end
end
