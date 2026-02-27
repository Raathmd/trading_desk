defmodule TradingDesk.DB.ScheduledDelivery do
  @moduledoc """
  Ecto schema for persisted scheduled deliveries.

  Each delivery line is generated from an ingested contract and linked via
  `contract_id` (FK) and `contract_hash` (the SHA-256 that produced this
  record). When a contract is reimported with a different hash, the old
  schedule records are physically deleted and new ones generated.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "scheduled_deliveries" do
    belongs_to :contract, TradingDesk.DB.ContractRecord,
      type: :string,
      foreign_key: :contract_id

    field :contract_hash, :string

    # Denormalized
    field :counterparty, :string
    field :contract_number, :string
    field :sap_contract_id, :string
    field :direction, :string
    field :product_group, :string
    field :incoterm, :string

    # Delivery
    field :quantity_mt, :float
    field :required_date, :date
    field :estimated_date, :date
    field :delay_days, :integer, default: 0
    field :status, :string, default: "on_track"
    field :delivery_index, :integer
    field :total_deliveries, :integer
    field :destination, :string
    field :notes, :string

    timestamps(type: :utc_datetime)
  end

  @required_fields [:contract_hash, :counterparty, :direction, :product_group,
                     :quantity_mt, :required_date]

  @optional_fields [:contract_id, :contract_number, :sap_contract_id, :incoterm,
                     :estimated_date, :delay_days, :status, :delivery_index,
                     :total_deliveries, :destination, :notes]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
