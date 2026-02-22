defmodule TradingDesk.DB.MobileApiToken do
  @moduledoc """
  Ecto schema for mobile API tokens.

  Tokens are created by admins (or seeded in dev) and presented by
  the mobile app as `Authorization: Bearer <token>`.

  A token is valid while:
    - `revoked` is false
    - `expires_at` is nil (never expires) or in the future
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "mobile_api_tokens" do
    field :token,      :string
    field :trader_id,  :string
    field :label,      :string
    field :revoked,    :boolean, default: false
    field :expires_at, :utc_datetime

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token, :trader_id, :label, :revoked, :expires_at])
    |> validate_required([:token, :trader_id])
    |> unique_constraint(:token)
  end

  @doc "Generate a secure random token string."
  def generate do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
