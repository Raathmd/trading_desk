defmodule TradingDesk.Fleet.TrackedVessel do
  @moduledoc """
  A vessel carrying Trammo product, linked to a product group and optionally to SAP.

  This table is the bridge between SAP shipping data and AIS tracking:
    SAP shipping number → vessel name/MMSI → AIS position feed

  The AISStreamConnector reads active MMSIs from this table to filter
  the WebSocket subscription and ETS cache to only "our" vessels.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias TradingDesk.Repo

  @product_groups ~w(ammonia_domestic ammonia_international sulphur_international petcoke)
  @statuses ~w(active in_transit discharged cancelled)
  @vessel_types ~w(towboat barge gas_carrier bulk_carrier chemical_tanker other)
  @river_segments ~w(upper_mississippi lower_mississippi gulf international)

  schema "tracked_vessels" do
    field :mmsi,                :string
    field :imo,                 :string
    field :vessel_name,         :string
    field :sap_shipping_number, :string
    field :sap_contract_id,     :string
    field :product_group,       :string
    field :cargo,               :string
    field :quantity_mt,         :float
    field :loading_port,        :string
    field :discharge_port,      :string
    field :eta,                 :date
    field :status,              :string, default: "active"
    field :notes,               :string
    # Trader-controlled flag: true = count this vessel as part of Trammo's operational fleet
    field :track_in_fleet,      :boolean, default: true
    field :vessel_type,         :string   # towboat | barge | gas_carrier | bulk_carrier | chemical_tanker
    field :operator,            :string   # e.g. "Kirby", "ARTCO", "Marquette", "Navigator Gas"
    field :flag_state,          :string   # ISO 3166-1 alpha-2 e.g. "US", "LR"
    field :capacity_mt,         :float    # max cargo capacity in metric tons
    field :river_segment,       :string   # upper_mississippi | lower_mississippi | gulf | international

    timestamps(type: :utc_datetime)
  end

  def changeset(vessel, attrs) do
    vessel
    |> cast(attrs, [
      :mmsi, :imo, :vessel_name, :sap_shipping_number, :sap_contract_id,
      :product_group, :cargo, :quantity_mt, :loading_port, :discharge_port,
      :eta, :status, :notes, :track_in_fleet, :vessel_type, :operator,
      :flag_state, :capacity_mt, :river_segment
    ])
    |> validate_required([:vessel_name, :product_group])
    |> validate_inclusion(:product_group, @product_groups)
    |> validate_inclusion(:status, @statuses)
    |> then(fn cs ->
      if Ecto.Changeset.get_field(cs, :vessel_type),
        do: Ecto.Changeset.validate_inclusion(cs, :vessel_type, @vessel_types),
        else: cs
    end)
    |> then(fn cs ->
      if Ecto.Changeset.get_field(cs, :river_segment),
        do: Ecto.Changeset.validate_inclusion(cs, :river_segment, @river_segments),
        else: cs
    end)
    |> unique_constraint(:sap_shipping_number)
  end

  # ──────────────────────────────────────────────
  # Queries
  # ──────────────────────────────────────────────

  @doc "All active vessels (status != discharged/cancelled)."
  def list_active do
    from(v in __MODULE__,
      where: v.status in ["active", "in_transit"],
      order_by: [asc: v.product_group, asc: v.vessel_name]
    )
    |> Repo.all()
  end

  @doc "Active vessels for a specific product group."
  def list_active(product_group) when is_atom(product_group) do
    list_active(to_string(product_group))
  end

  def list_active(product_group) when is_binary(product_group) do
    from(v in __MODULE__,
      where: v.status in ["active", "in_transit"],
      where: v.product_group == ^product_group,
      order_by: [asc: v.vessel_name]
    )
    |> Repo.all()
  end

  @doc "All active MMSIs — used by AISStreamConnector for subscription filtering."
  def active_mmsis do
    from(v in __MODULE__,
      where: v.status in ["active", "in_transit"],
      where: not is_nil(v.mmsi) and v.mmsi != "",
      select: v.mmsi
    )
    |> Repo.all()
  end

  @doc "All active MMSIs for a product group."
  def active_mmsis(product_group) when is_atom(product_group) do
    active_mmsis(to_string(product_group))
  end

  def active_mmsis(product_group) when is_binary(product_group) do
    from(v in __MODULE__,
      where: v.status in ["active", "in_transit"],
      where: v.product_group == ^product_group,
      where: not is_nil(v.mmsi) and v.mmsi != "",
      select: v.mmsi
    )
    |> Repo.all()
  end

  @doc "All vessels (including completed), ordered by most recent first."
  def list_all do
    from(v in __MODULE__, order_by: [desc: v.updated_at])
    |> Repo.all()
  end

  @doc "Vessels the trader has flagged as Trammo operational fleet (track_in_fleet = true)."
  def list_trammo_fleet do
    from(v in __MODULE__,
      where: v.status in ["active", "in_transit"] and v.track_in_fleet == true,
      order_by: [asc: v.product_group, asc: v.vessel_name]
    )
    |> Repo.all()
  end

  @doc "Count of Trammo-tracked vessels by product group."
  def trammo_fleet_count(product_group) when is_atom(product_group),
    do: trammo_fleet_count(to_string(product_group))

  def trammo_fleet_count(product_group) when is_binary(product_group) do
    from(v in __MODULE__,
      where: v.status in ["active", "in_transit"]
        and v.track_in_fleet == true
        and v.product_group == ^product_group,
      select: count()
    )
    |> Repo.one()
  end

  @doc "Find by SAP shipping number."
  def get_by_sap(shipping_number) do
    Repo.get_by(__MODULE__, sap_shipping_number: shipping_number)
  end

  @doc "Find by MMSI."
  def get_by_mmsi(mmsi) do
    Repo.get_by(__MODULE__, mmsi: mmsi)
  end

  # ──────────────────────────────────────────────
  # Mutations
  # ──────────────────────────────────────────────

  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update(%__MODULE__{} = vessel, attrs) do
    vessel
    |> changeset(attrs)
    |> Repo.update()
  end

  def mark_discharged(%__MODULE__{} = vessel) do
    __MODULE__.update(vessel, %{status: "discharged"})
  end

  @doc "Toggle the trader's fleet tracking flag for this vessel."
  def toggle_fleet_tracking(%__MODULE__{} = vessel) do
    __MODULE__.update(vessel, %{track_in_fleet: !vessel.track_in_fleet})
  end

  def delete(%__MODULE__{} = vessel) do
    Repo.delete(vessel)
  end

  @doc "Summary counts by product group and status."
  def fleet_summary do
    from(v in __MODULE__,
      group_by: [v.product_group, v.status],
      select: {v.product_group, v.status, count()}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {pg, status, count}, acc ->
      pg_atom = String.to_existing_atom(pg)
      Map.update(acc, pg_atom, %{status => count}, &Map.put(&1, status, count))
    end)
  end
end
