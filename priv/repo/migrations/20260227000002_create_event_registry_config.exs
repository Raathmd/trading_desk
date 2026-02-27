defmodule TradingDesk.Repo.Migrations.CreateEventRegistryConfig do
  use Ecto.Migration

  def change do
    create table(:event_registry_config, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :event_type, :text, null: false
      add :source_process, :text, null: false
      add :should_vectorize, :boolean, default: true
      add :content_template, :map, null: false
      add :batch_size, :integer, default: 100
      add :batch_window_seconds, :integer, default: 3600
      add :priority, :integer, default: 5
      add :description, :text
      add :is_active, :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:event_registry_config, [:event_type, :source_process])
  end
end
