defmodule TradingDesk.Vectorization.EventStream do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "event_stream" do
    field :event_type, :string
    field :source_process, :string
    field :context, :map
    field :vectorized, :boolean, default: false
    field :vector_id, :binary_id
    field :vectorized_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:event_type, :source_process, :context, :vectorized, :vector_id, :vectorized_at])
    |> validate_required([:event_type, :source_process, :context])
  end
end
