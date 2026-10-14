defmodule KnotraBots.ConversationTurn do
  @moduledoc """
  One turn in a conversation, backed by a durable Knotra execution.

  `index` is 0-based and unique per conversation; `execution_id` is the durable id
  returned by `Knotra.submit/6`.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "conversation_turns" do
    field(:conversation_id, :string)
    field(:index, :integer)
    field(:bot_id, :string)
    field(:execution_id, :string)
    field(:input, :string)
    field(:output, :string)
    field(:status, :string, default: "running")
    timestamps()
  end
end
