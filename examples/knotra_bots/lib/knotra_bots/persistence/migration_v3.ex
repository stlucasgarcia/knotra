defmodule KnotraBots.Persistence.MigrationV3 do
  @moduledoc """
  Replaces the original bot-to-bot demo tables with the chat model.

  The demo database is disposable (`_build/`), so this cutover drops the old
  `bots`, `conversations` and `conversation_turns` tables and creates `agents`,
  `channels`, `channel_agents` and `messages`. Knotra's own `knotra_executions`
  table is untouched.
  """
  use Ecto.Migration

  def up do
    drop(table(:conversation_turns))
    drop(table(:conversations))
    drop(table(:bots))

    create table(:agents, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:name, :string, null: false)
      add(:handle, :string, null: false)
      add(:system_prompt, :text, null: false, default: "")
      add(:model, :string, null: false)
      add(:tools, :string, null: false, default: "")
      add(:revision, :integer, null: false, default: 1)
      timestamps()
    end

    create(unique_index(:agents, [:name]))
    create(unique_index(:agents, [:handle]))

    create table(:channels, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:name, :string, null: false)
      add(:topic, :text, null: false, default: "")
      add(:default_agent_id, references(:agents, type: :string, on_delete: :nilify_all))
      timestamps()
    end

    create(unique_index(:channels, [:name]))

    create table(:channel_agents, primary_key: false) do
      add(:channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false)

      add(:agent_id, references(:agents, type: :string, on_delete: :restrict), null: false)
    end

    create(unique_index(:channel_agents, [:channel_id, :agent_id]))

    create table(:messages, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:channel_id, references(:channels, type: :string, on_delete: :delete_all), null: false)

      add(:author_type, :string, null: false)
      add(:agent_id, references(:agents, type: :string, on_delete: :nilify_all))
      add(:body, :text, null: false, default: "")
      add(:status, :string, null: false, default: "sent")
      add(:root_id, :string)
      add(:hop, :integer, null: false, default: 0)
      add(:execution_id, :string)
      add(:definition_version, :string)
      timestamps(type: :naive_datetime_usec)
    end

    create(index(:messages, [:channel_id, :inserted_at]))
    create(index(:messages, [:status]))
  end

  def down do
    raise "KnotraBots migration 3 is not reversible; delete the demo database instead"
  end
end
