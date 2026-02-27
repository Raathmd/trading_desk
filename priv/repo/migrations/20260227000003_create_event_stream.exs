defmodule TradingDesk.Repo.Migrations.CreateEventStream do
  use Ecto.Migration

  def change do
    create table(:event_stream, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :event_type, :text, null: false
      add :source_process, :text, null: false
      add :context, :map, null: false
      add :vectorized, :boolean, default: false
      add :vector_id, :binary_id
      add :vectorized_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:event_stream, [:vectorized, :inserted_at],
      where: "vectorized = false",
      name: :idx_event_stream_pending
    )

    create index(:event_stream, [:event_type, :source_process])
  end
end
