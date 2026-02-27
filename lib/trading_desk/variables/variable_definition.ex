defmodule TradingDesk.Variables.VariableDefinition do
  @moduledoc """
  Ecto schema for a solver/tracker variable definition.

  Each row represents one variable tracked by a product group.
  The 20 core solver variables (seeded from `variables.ex`) live here
  under `product_group = "global"`.  Any product group may add extra
  variables that are polled, file-loaded, or trader-maintained.

  ## source_type

    - `"api"`    – auto-polled on a schedule
    - `"manual"` – trader sets value via the dashboard; never auto-polled
    - `"file"`   – value is populated by uploading a CSV/Excel file

  ## fetch_mode (relevant when source_type = "api")

    - `"module"`   – call a named Elixir module's `fetch/0`; extract `response_path` key
    - `"json_get"` – generic HTTP GET to the source_id's configured URL; extract
                     `response_path` (dot-separated) from the JSON body
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "variable_definitions" do
    field :product_group,   :string,  default: "global"
    field :key,             :string
    field :label,           :string
    field :unit,            :string,  default: ""
    field :group_name,      :string,  default: "commercial"
    field :type,            :string,  default: "float"

    field :source_type,     :string,  default: "manual"
    field :source_id,       :string
    field :fetch_mode,      :string,  default: "manual"
    field :module_name,     :string
    field :response_path,   :string
    field :file_column,     :string

    field :default_value,   :float,   default: 0.0
    field :min_val,         :float
    field :max_val,         :float
    field :step,            :float

    field :solver_position, :integer
    field :display_order,   :integer, default: 0
    field :active,          :boolean, default: true

    timestamps()
  end

  @required ~w(product_group key label)a
  @optional ~w(unit group_name type source_type source_id fetch_mode module_name
               response_path file_column default_value min_val max_val step
               solver_position display_order active)a

  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:key, min: 1, max: 80)
    |> validate_format(:key, ~r/^[a-z][a-z0-9_]*$/, message: "must be snake_case (a-z, 0-9, _)")
    |> validate_inclusion(:type,        ~w(float boolean),            message: "must be float or boolean")
    |> validate_inclusion(:source_type, ~w(api manual file),          message: "must be api, manual, or file")
    |> validate_inclusion(:fetch_mode,  ~w(module json_get manual file), message: "must be module, json_get, manual, or file")
    |> validate_inclusion(:group_name,  ~w(environment operations commercial), message: "must be environment, operations, or commercial")
    |> unique_constraint([:product_group, :key])
  end
end
