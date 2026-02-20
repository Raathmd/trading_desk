defmodule TradingDesk.Auth.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/@/)
    |> update_change(:email, &String.downcase(String.trim(&1)))
    |> unique_constraint(:email)
  end
end
