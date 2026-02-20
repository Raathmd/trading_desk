defmodule TradingDesk.Repo.Migrations.CreateMagicLinkTokens do
  use Ecto.Migration

  def change do
    create table(:magic_link_tokens) do
      add :email,      :string,   null: false
      add :token,      :string,   null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at,    :utc_datetime
      timestamps()
    end

    create unique_index(:magic_link_tokens, [:token])
    create index(:magic_link_tokens, [:email])
  end
end
