defmodule TradingDesk.Vectorization.EventRegistryConfig do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias TradingDesk.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "event_registry_config" do
    field :event_type, :string
    field :source_process, :string
    field :should_vectorize, :boolean, default: true
    field :content_template, :map
    field :batch_size, :integer, default: 100
    field :batch_window_seconds, :integer, default: 3600
    field :priority, :integer, default: 5
    field :description, :string
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:event_type, :source_process, :should_vectorize, :content_template,
                    :batch_size, :batch_window_seconds, :priority, :description, :is_active])
    |> validate_required([:event_type, :source_process, :content_template])
    |> unique_constraint([:event_type, :source_process])
  end

  @doc "Fetch config for a given event_type + source_process. Returns nil if not found or inactive."
  def get_config(event_type, source_process) do
    Repo.one(
      from c in __MODULE__,
        where: c.event_type == ^event_type and c.source_process == ^source_process and c.is_active == true
    )
  end
end
