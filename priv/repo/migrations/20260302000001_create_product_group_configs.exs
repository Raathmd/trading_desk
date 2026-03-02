defmodule TradingDesk.Repo.Migrations.CreateProductGroupConfigs do
  use Ecto.Migration

  def change do
    create table(:product_group_configs) do
      add :key,                   :string,  null: false   # e.g. "ammonia_domestic"
      add :name,                  :string,  null: false   # "NH3 Domestic Barge"
      add :product,               :string,  null: false   # "Anhydrous Ammonia"
      add :transport_mode,        :string,  null: false   # "barge" | "ocean_vessel" | "rail" | ...
      add :geography,             :string                 # free-text description

      # Regex patterns stored as strings (compiled at runtime)
      add :product_patterns,      {:array, :string}, default: []

      # On-chain encoding
      add :chain_magic,           :string                 # e.g. "NH3\x01"
      add :chain_product_code,    :integer                # e.g. 0x01

      add :solver_binary,         :string,  default: "solver"

      # Signal thresholds for go/no-go classification
      add :signal_thresholds,     :map,     default: %{}  # %{"strong_go" => 50000, ...}

      # Contract clause → solver variable mapping
      add :contract_term_map,     :map,     default: %{}

      # NLP anchors for chat/intent resolution
      add :location_anchors,      :map,     default: %{}
      add :price_anchors,         :map,     default: %{}

      # Poll intervals in milliseconds, keyed by source name
      add :default_poll_intervals, :map,    default: %{}

      # Legacy aliases that resolve to this product group (e.g. ["ammonia", "uan"])
      add :aliases,               {:array, :string}, default: []

      add :active,                :boolean, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:product_group_configs, [:key])
    create index(:product_group_configs, [:active])
  end
end
