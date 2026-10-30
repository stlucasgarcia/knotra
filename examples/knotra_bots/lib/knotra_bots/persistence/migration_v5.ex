defmodule KnotraBots.Persistence.MigrationV5 do
  @moduledoc """
  Adds the frozen submission payload to `messages`.

  A queued reply stores the exact model input and the agent snapshot it was
  queued with. A retry after a lost acknowledgment therefore sends the same
  request the durable store already accepted, instead of rebuilding a different
  one from the current channel or agent. Fresh databases get these columns from
  migration 3; this idempotent step upgrades databases created before it.
  """
  use Ecto.Migration

  def up do
    columns =
      repo().query!("PRAGMA table_info(messages)").rows
      |> Enum.map(&Enum.at(&1, 1))

    unless "input" in columns do
      execute("ALTER TABLE messages ADD COLUMN input TEXT")
    end

    unless "definition_snapshot" in columns do
      execute("ALTER TABLE messages ADD COLUMN definition_snapshot TEXT")
    end
  end

  def down do
    raise "KnotraBots migration 5 is a one-way repair; delete the demo database instead"
  end
end
