defmodule TradingDesk.TradeRepo.Migrations.RenameTerminalColumns do
  use Ecto.Migration

  @moduledoc """
  Renames solver variable columns to reflect Trammo's actual terminal names.

  Old names used CF Industries production plant codes (Donaldsonville/Geismar, LA).
  New names use Trammo's own terminal names (Meredosia/Niota, IL).

  Column renames:
    inv_don     → inv_mer      (Meredosia terminal inventory, tons)
    inv_geis    → inv_nio      (Niota terminal inventory, tons)
    stl_outage  → mer_outage   (Meredosia terminal outage flag)
    mem_outage  → nio_outage   (Niota terminal outage flag)
  """

  def change do
    rename table(:solve_variables), :inv_don,    to: :inv_mer
    rename table(:solve_variables), :inv_geis,   to: :inv_nio
    rename table(:solve_variables), :stl_outage, to: :mer_outage
    rename table(:solve_variables), :mem_outage, to: :nio_outage
  end
end
