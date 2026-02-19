defmodule TradingDesk.Seeds.TraderSeed do
  @moduledoc """
  Seeds initial traders and their product group assignments.

  Run once after migrations:

      TradingDesk.Seeds.TraderSeed.run()
  """

  alias TradingDesk.Repo
  alias TradingDesk.DB.{TraderRecord, TraderProductGroupRecord}
  import Ecto.Query
  require Logger

  @traders [
    %{
      name: "Alex Drummond",
      email: "a.drummond@trammo.com",
      product_groups: [
        %{product_group: "ammonia_domestic",      is_primary: true},
        %{product_group: "ammonia_international", is_primary: false}
      ]
    },
    %{
      name: "Sophia Reyes",
      email: "s.reyes@trammo.com",
      product_groups: [
        %{product_group: "ammonia_international", is_primary: true}
      ]
    },
    %{
      name: "Marcus Webb",
      email: "m.webb@trammo.com",
      product_groups: [
        %{product_group: "sulphur_international", is_primary: true}
      ]
    },
    %{
      name: "Priya Nair",
      email: "p.nair@trammo.com",
      product_groups: [
        %{product_group: "petcoke",               is_primary: true},
        %{product_group: "sulphur_international", is_primary: false}
      ]
    },
    %{
      name: "James Okafor",
      email: "j.okafor@trammo.com",
      product_groups: [
        %{product_group: "ammonia_domestic",      is_primary: true}
      ]
    }
  ]

  def run do
    Enum.each(@traders, fn attrs ->
      groups = attrs.product_groups

      existing =
        Repo.one(from t in TraderRecord, where: t.email == ^attrs.email)

      trader =
        case existing do
          nil ->
            %TraderRecord{}
            |> TraderRecord.changeset(Map.take(attrs, [:name, :email, :active]))
            |> Repo.insert!()

          t ->
            t
        end

      Enum.each(groups, fn g ->
        unless Repo.exists?(
          from tpg in TraderProductGroupRecord,
          where: tpg.trader_id == ^trader.id and tpg.product_group == ^g.product_group
        ) do
          %TraderProductGroupRecord{}
          |> TraderProductGroupRecord.changeset(%{
            trader_id:     trader.id,
            product_group: g.product_group,
            is_primary:    g.is_primary
          })
          |> Repo.insert!()
        end
      end)

      Logger.info("TraderSeed: seeded #{trader.name}")
    end)
  end
end
