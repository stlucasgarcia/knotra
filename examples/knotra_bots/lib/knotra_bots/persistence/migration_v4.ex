defmodule KnotraBots.Persistence.MigrationV4 do
  @moduledoc """
  Brings an older demo database up to the current Knotra execution schema.

  Early revisions of `Knotra.Persistence.Migration` created `knotra_executions`
  without `inserted_at` or the status/tenant indexes. Fresh databases already have
  them; this idempotent step repairs databases created by the previous demo
  revision, which is exactly the manual upgrade the library documentation calls
  out.
  """
  use Ecto.Migration

  def up do
    columns =
      repo().query!("PRAGMA table_info(knotra_executions)").rows
      |> Enum.map(&Enum.at(&1, 1))

    unless "inserted_at" in columns do
      execute("ALTER TABLE knotra_executions ADD COLUMN inserted_at TEXT")

      execute(
        "UPDATE knotra_executions SET inserted_at = strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE inserted_at IS NULL"
      )
    end

    execute(
      "CREATE INDEX IF NOT EXISTS knotra_executions_status_index ON knotra_executions (status)"
    )

    execute(
      "CREATE INDEX IF NOT EXISTS knotra_executions_tenant_inserted_at_index ON knotra_executions (tenant, inserted_at)"
    )
  end

  def down do
    raise "KnotraBots migration 4 is a one-way repair; delete the demo database instead"
  end
end
