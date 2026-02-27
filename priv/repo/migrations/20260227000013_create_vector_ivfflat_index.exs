defmodule TradingDesk.Repo.Migrations.CreateVectorIvfflatIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # IVFFlat index requires data to train on. For an empty table, start with
    # a small lists value. Rebuild after initial data load if needed.
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_vectors_embedding
    ON contract_execution_vectors
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_vectors_embedding"
  end
end
