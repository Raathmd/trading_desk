defmodule TradingDesk.ContractManagement.CmContractNegotiation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @valid_statuses ~w(draft step_1_product_selection step_2_counterparty step_3_commercial_terms
    step_4_clause_selection step_5_optimizer_validation step_6_review step_7_approval
    approved executed active expired terminated disputed withdrawn failed cancelled)

  schema "cm_contract_negotiations" do
    field :product_group, :string
    field :reference_number, :string
    field :counterparty, :string
    field :commodity, :string
    field :status, :string, default: "draft"
    field :current_step, :integer, default: 1
    field :total_steps, :integer, default: 7
    field :step_data, :map, default: %{}
    field :step_history, {:array, :map}, default: []
    field :scenario_id, :binary_id
    field :solver_recommendation_snapshot, :map
    field :solver_margin_forecast, :decimal
    field :solver_confidence, :decimal
    field :quantity, :decimal
    field :quantity_unit, :string, default: "MT"
    field :delivery_window_start, :date
    field :delivery_window_end, :date
    field :proposed_price, :decimal
    field :proposed_freight, :decimal
    field :proposed_terms, :map
    field :trader_id, :string

    has_many :events, TradingDesk.ContractManagement.CmContractNegotiationEvent,
      foreign_key: :contract_negotiation_id

    timestamps(type: :utc_datetime)
  end

  def changeset(negotiation, attrs) do
    negotiation
    |> cast(attrs, [
      :product_group, :reference_number, :counterparty, :commodity, :status,
      :current_step, :total_steps, :step_data, :step_history, :scenario_id,
      :solver_recommendation_snapshot, :solver_margin_forecast, :solver_confidence,
      :quantity, :quantity_unit, :delivery_window_start, :delivery_window_end,
      :proposed_price, :proposed_freight, :proposed_terms, :trader_id
    ])
    |> validate_required([:product_group, :reference_number, :counterparty, :commodity, :trader_id])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:current_step, greater_than_or_equal_to: 1, less_than_or_equal_to: 7)
    |> unique_constraint([:product_group, :reference_number])
  end
end
