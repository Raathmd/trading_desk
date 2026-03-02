defmodule TradingDesk.DB.ProductGroupConfig do
  @moduledoc """
  Ecto schema for product group configuration.

  Stores all top-level metadata for a product group that was previously
  hardcoded in the Frame modules: name, product, transport mode, signal
  thresholds, contract term mappings, NLP anchors, poll intervals, etc.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "product_group_configs" do
    field :key,                     :string
    field :name,                    :string
    field :product,                 :string
    field :transport_mode,          :string
    field :geography,               :string

    field :product_patterns,        {:array, :string}, default: []
    field :chain_magic,             :string
    field :chain_product_code,      :integer
    field :solver_binary,           :string, default: "solver"

    field :signal_thresholds,       :map, default: %{}
    field :contract_term_map,       :map, default: %{}
    field :location_anchors,        :map, default: %{}
    field :price_anchors,           :map, default: %{}
    field :default_poll_intervals,  :map, default: %{}

    field :aliases,                 {:array, :string}, default: []
    field :active,                  :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required ~w(key name product transport_mode)a
  @optional ~w(geography product_patterns chain_magic chain_product_code solver_binary
               signal_thresholds contract_term_map location_anchors price_anchors
               default_poll_intervals aliases active)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:key, min: 1, max: 80)
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]*$/, message: "must be snake_case")
    |> validate_inclusion(:transport_mode, ~w(barge ocean_vessel rail truck pipeline),
         message: "must be barge, ocean_vessel, rail, truck, or pipeline")
    |> unique_constraint(:key)
  end
end
