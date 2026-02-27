defmodule TradingDesk.Repo.Migrations.CreateCmContractNegotiationEvents do
  use Ecto.Migration

  def change do
    create table(:cm_contract_negotiation_events, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :contract_negotiation_id, references(:cm_contract_negotiations, type: :binary_id, on_delete: :delete_all), null: false
      add :event_type, :text, null: false
      add :step_number, :integer
      add :actor, :text, null: false
      add :summary, :text
      add :details, :map
      add :clause_id, :binary_id

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cm_contract_negotiation_events, [:contract_negotiation_id])
    create index(:cm_contract_negotiation_events, [:event_type])
  end
end
