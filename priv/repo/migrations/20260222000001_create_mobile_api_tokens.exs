defmodule TradingDesk.Repo.Migrations.CreateMobileApiTokens do
  use Ecto.Migration

  def change do
    create table(:mobile_api_tokens, primary_key: false) do
      add :id,         :binary_id, primary_key: true
      add :token,      :string,    null: false
      add :trader_id,  :string,    null: false
      add :label,      :string
      add :revoked,    :boolean,   null: false, default: false
      add :expires_at, :utc_datetime

      timestamps()
    end

    create unique_index(:mobile_api_tokens, [:token])
    create index(:mobile_api_tokens, [:trader_id])
  end
end
