defmodule TradingDesk.Repo.Migrations.AddPerturbationToVariableDefinitions do
  use Ecto.Migration

  def change do
    alter table(:variable_definitions) do
      # Monte Carlo perturbation parameters
      add :delta_threshold,       :float                  # change threshold for auto-solve trigger
      add :perturbation_stddev,   :float                  # stddev for normal perturbation
      add :perturbation_min,      :float                  # clamp min for perturbation
      add :perturbation_max,      :float                  # clamp max for perturbation
      add :perturbation_flip_prob, :float                 # flip probability for boolean vars
    end
  end
end
