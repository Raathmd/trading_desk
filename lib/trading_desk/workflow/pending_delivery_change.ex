defmodule TradingDesk.Workflow.PendingDeliveryChange do
  @moduledoc """
  Represents a proposed change to a delivery that needs to be captured in SAP.

  When a trader saves a solved scenario, the DeliveryScheduler produces a list
  of proposed changes (quantity adjustments, date shifts). Each change is stored
  here. The Workflow tab displays open changes so the trader can review and
  simulate pushing each one to SAP.

  Clicking "Apply to SAP" marks the change as :applied and updates the in-memory
  delivery schedule to reflect the new SAP state.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias TradingDesk.Repo

  @valid_statuses ~w(pending applied rejected cancelled)
  @valid_directions ~w(sale purchase)
  @valid_change_types ~w(quantity date both cancel)

  schema "pending_delivery_changes" do
    field :scenario_name,       :string
    field :scenario_id,         :integer

    field :contract_number,     :string
    field :sap_contract_id,     :string
    field :counterparty,        :string
    field :direction,           :string
    field :product_group,       :string

    field :original_quantity_mt, :float
    field :revised_quantity_mt,  :float
    field :original_date,        :date
    field :revised_date,         :date
    field :change_type,          :string, default: "quantity"

    field :change_reason,       :string

    field :status,              :string, default: "pending"

    field :applied_at,          :utc_datetime
    field :sap_document,        :string
    field :applied_by,          :integer

    field :trader_id,           :integer

    field :notes,               :string

    field :sap_created_at,      :utc_datetime
    field :sap_updated_at,      :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(change, attrs) do
    change
    |> cast(attrs, [
      :scenario_name, :scenario_id, :contract_number, :sap_contract_id,
      :counterparty, :direction, :product_group,
      :original_quantity_mt, :revised_quantity_mt,
      :original_date, :revised_date, :change_type,
      :change_reason, :status, :applied_at, :sap_document,
      :applied_by, :trader_id, :notes, :sap_created_at, :sap_updated_at
    ])
    |> validate_required([:scenario_name, :counterparty, :direction, :product_group])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:change_type, @valid_change_types)
  end

  @doc "List pending changes for a product group, newest first."
  def list_for_product_group(pg, status_filter \\ "all") do
    query =
      from c in __MODULE__,
        where: c.product_group == ^pg,
        order_by: [desc: c.inserted_at]

    query =
      if status_filter in ["pending", "applied", "rejected", "cancelled"] do
        from c in query, where: c.status == ^status_filter
      else
        query
      end

    Repo.all(query)
  rescue
    _ -> []
  end

  @doc "List open (pending) changes only."
  def list_open(pg) do
    from(c in __MODULE__,
      where: c.product_group == ^pg and c.status == "pending",
      order_by: [asc: c.original_date, desc: c.inserted_at]
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  @doc "Create a new pending change."
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc "Mark a change as applied — simulates the SAP update."
  def apply_change(%__MODULE__{} = change, trader_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    sap_doc = "SAP-#{:rand.uniform(999999) |> Integer.to_string() |> String.pad_leading(6, "0")}"

    change
    |> changeset(%{
      status: "applied",
      applied_at: now,
      sap_document: sap_doc,
      applied_by: trader_id,
      sap_updated_at: now
    })
    |> Repo.update()
  end

  @doc "Mark a change as rejected."
  def reject_change(%__MODULE__{} = change) do
    change
    |> changeset(%{status: "rejected"})
    |> Repo.update()
  end

  @doc "Create pending changes from solver output for saved scenario."
  def create_from_scenario(scenario_name, scenario_id, solver_result, schedule_lines, product_group, trader_id) do
    # Build a list of delivery changes based on the solved route allocation
    # vs the existing schedule lines.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changes =
      Enum.flat_map(schedule_lines, fn line ->
        # Determine if this line was affected by the solve
        original_qty = line[:quantity_mt] || 0
        route_factor = Map.get(solver_result, :tons, 0) / max(original_qty, 1)
        revised_qty = Float.round(original_qty * min(route_factor, 1.0), 2)

        delay_days = line[:delay_days] || 0
        original_date = line[:required_date]
        revised_date = if delay_days > 0 && original_date, do: Date.add(original_date, delay_days), else: original_date

        has_qty_change = abs(revised_qty - original_qty) > 1.0
        has_date_change = delay_days > 0

        if has_qty_change or has_date_change do
          change_type = cond do
            has_qty_change and has_date_change -> "both"
            has_qty_change -> "quantity"
            true -> "date"
          end

          [%{
            scenario_name: scenario_name,
            scenario_id: scenario_id,
            contract_number: line[:contract_number],
            sap_contract_id: line[:sap_contract_id],
            counterparty: line[:counterparty] || "Unknown",
            direction: to_string(line[:direction] || "sale"),
            product_group: product_group,
            original_quantity_mt: original_qty,
            revised_quantity_mt: revised_qty,
            original_date: original_date,
            revised_date: revised_date,
            change_type: change_type,
            change_reason: "Solver optimization — #{scenario_name}",
            status: "pending",
            trader_id: trader_id,
            sap_created_at: now
          }]
        else
          []
        end
      end)

    Enum.map(changes, &create/1)
  rescue
    _ -> []
  end
end
