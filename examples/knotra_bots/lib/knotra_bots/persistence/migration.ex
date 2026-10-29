defmodule KnotraBots.Persistence.Migration do
  @moduledoc """
  Host-owned tables for bots and bot-to-bot conversations.

  Applied at migration version 2, after `Knotra.Persistence.Migration` (version 1)
  creates `knotra_executions`. Conversation turns reference a durable execution by
  its Knotra id; the host still owns the identity/conversation tables, as ADR 0001
  requires.
  """
  use Ecto.Migration

  def change do
    create table(:bots, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:name, :string, null: false)
      add(:system_prompt, :text, null: false, default: "")
      add(:model, :string, null: false)
      add(:tools, :string, null: false, default: "")
      add(:revision, :integer, null: false, default: 1)
      timestamps()
    end

    create(unique_index(:bots, [:name]))

    create table(:conversations, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:bot_a_id, references(:bots, type: :string, on_delete: :restrict), null: false)
      add(:bot_b_id, references(:bots, type: :string, on_delete: :restrict), null: false)
      add(:topic, :text, null: false)
      add(:rounds, :integer, null: false, default: 4)
      add(:status, :string, null: false, default: "running")
      timestamps()
    end

    create table(:conversation_turns, primary_key: false) do
      add(:id, :string, primary_key: true)

      add(:conversation_id, references(:conversations, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:index, :integer, null: false)
      add(:bot_id, :string, null: false)
      add(:execution_id, :string)
      add(:input, :text, null: false)
      add(:output, :text)
      add(:status, :string, null: false, default: "running")
      timestamps()
    end

    # One turn per index: resume updates the same row instead of appending.
    create(unique_index(:conversation_turns, [:conversation_id, :index]))
  end
end
