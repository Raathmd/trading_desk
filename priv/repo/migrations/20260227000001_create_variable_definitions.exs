defmodule TradingDesk.Repo.Migrations.CreateVariableDefinitions do
  use Ecto.Migration

  def change do
    create table(:variable_definitions) do
      # Which product group owns this variable.
      # "global" = shared across all product groups (the 20 core solver vars).
      # "ammonia_domestic", "uan", etc. = group-specific extras.
      add :product_group,   :string,  null: false, default: "global"
      add :key,             :string,  null: false           # variable identifier, e.g. "river_stage"
      add :label,           :string,  null: false           # display label
      add :unit,            :string,  default: ""           # "ft", "$/t", "°F", etc.
      add :group_name,      :string,  default: "commercial" # "environment" | "operations" | "commercial"
      add :type,            :string,  default: "float"      # "float" | "boolean"

      # ── Source configuration ────────────────────────────────────────────────
      # source_type: how the value is obtained
      #   "api"    – polled from an external or internal API
      #   "manual" – trader sets via dashboard; never auto-polled
      #   "file"   – populated by uploading a CSV/Excel file via the dashboard
      add :source_type,    :string,  default: "manual"

      # source_id: references the api_configs entry (url + key stored there).
      # e.g. "eia", "usgs", "my_custom_feed".
      add :source_id,      :string

      # fetch_mode: how to call the source (only relevant when source_type = "api")
      #   "module"   – delegate to a named Elixir module's fetch/0 function
      #   "json_get" – generic HTTP GET + JSON field extraction (no code change needed)
      #   "manual"   – no polling
      #   "file"     – no polling; value set by file upload
      add :fetch_mode,     :string,  default: "manual"

      # For fetch_mode = "module": fully-qualified Elixir module name as string.
      # e.g. "TradingDesk.Data.API.EIA"
      add :module_name,    :string

      # For fetch_mode = "json_get" or "module": dot-separated path into the JSON
      # response body, or the key in the module's returned map.
      # e.g. "nat_gas"  or  "data.price.value"
      add :response_path,  :string

      # For source_type = "file": the CSV/Excel column header that contains this variable's value.
      add :file_column,    :string

      # ── Value constraints & defaults ────────────────────────────────────────
      add :default_value,  :float,   default: 0.0
      add :min_val,        :float
      add :max_val,        :float
      add :step,           :float

      # Position in the solver binary blob (1-indexed).
      # nil = variable is tracked but NOT sent to the Zig solver.
      add :solver_position, :integer

      add :display_order,  :integer, default: 0
      add :active,         :boolean, default: true

      timestamps()
    end

    # Each (product_group, key) pair is unique
    create unique_index(:variable_definitions, [:product_group, :key])
    create index(:variable_definitions, [:source_id])
    create index(:variable_definitions, [:source_type])
    create index(:variable_definitions, [:active])
  end
end
