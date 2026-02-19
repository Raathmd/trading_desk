defmodule TradingDesk.DB.TraderRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "traders" do
    field :name,   :string
    field :email,  :string
    field :active, :boolean, default: true

    has_many :product_groups, TradingDesk.DB.TraderProductGroupRecord,
      foreign_key: :trader_id

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:name, :email, :active])
    |> validate_required([:name])
  end
end

defmodule TradingDesk.DB.TraderProductGroupRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trader_product_groups" do
    field :product_group, :string
    field :is_primary,    :boolean, default: false

    belongs_to :trader, TradingDesk.DB.TraderRecord

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:trader_id, :product_group, :is_primary])
    |> validate_required([:trader_id, :product_group])
  end
end
