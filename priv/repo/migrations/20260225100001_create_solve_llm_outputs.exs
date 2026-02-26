defmodule TradingDesk.Repo.Migrations.CreateSolveLlmOutputs do
  use Ecto.Migration

  def change do
    create table(:solve_llm_outputs, primary_key: false) do
      add :solve_audit_id, references(:solve_audits, type: :string, on_delete: :delete_all),
        null: false, primary_key: true
      add :model_id, :string, null: false, primary_key: true

      # What phase produced this output
      add :phase, :string, null: false  # "presolve_framing" | "presolve_explanation" | "postsolve_explanation"

      # Model metadata
      add :model_name, :string  # human-readable e.g. "Mistral 7B"

      # Output content
      add :output_text, :text     # plain-text explanation (presolve/postsolve explainer)
      add :output_json, :map      # structured JSON (presolve framer adjustments)

      # Status
      add :status, :string, null: false, default: "ok"  # "ok" | "error"
      add :error_reason, :string

      # Timing
      add :duration_ms, :integer  # how long the LLM call took

      timestamps(type: :utc_datetime)
    end

    create index(:solve_llm_outputs, [:solve_audit_id])
    create index(:solve_llm_outputs, [:model_id])
    create index(:solve_llm_outputs, [:phase])
  end
end
