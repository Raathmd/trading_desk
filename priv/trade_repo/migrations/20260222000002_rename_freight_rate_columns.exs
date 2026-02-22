defmodule TradingDesk.TradeRepo.Migrations.RenameFreightRateColumns do
  use Ecto.Migration

  @moduledoc """
  Rename solve_variables freight rate columns to reflect Trammo's own
  Illinois River terminal names (Meredosia / Niota) rather than the old
  CF Industries / Cornerstone Louisiana plant codes (Donaldsonville / Geismar).

  Old → New:
    fr_don_stl  → fr_mer_stl   (Meredosia → St. Louis)
    fr_don_mem  → fr_mer_mem   (Meredosia → Memphis)
    fr_geis_stl → fr_nio_stl   (Niota → St. Louis)
    fr_geis_mem → fr_nio_mem   (Niota → Memphis)
  """

  def change do
    rename table(:solve_variables), :fr_don_stl,  to: :fr_mer_stl
    rename table(:solve_variables), :fr_don_mem,  to: :fr_mer_mem
    rename table(:solve_variables), :fr_geis_stl, to: :fr_nio_stl
    rename table(:solve_variables), :fr_geis_mem, to: :fr_nio_mem
  end
end
