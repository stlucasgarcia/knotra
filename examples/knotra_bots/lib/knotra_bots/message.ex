defmodule KnotraBots.Message do
  @moduledoc """
  One entry in a channel timeline.

  Human and system messages are terminal. An agent message tracks one durable
  Knotra execution: `queued` before submission, `running`, `waiting` at a
  clarification or approval, then a terminal status. `root_id` is the human
  message that started the exchange; `hop` bounds agent-to-agent handoffs.
  """
  use Ecto.Schema

  @timestamps_opts [type: :naive_datetime_usec]

  @primary_key {:id, :string, autogenerate: false}
  schema "messages" do
    field(:channel_id, :string)
    field(:author_type, :string)
    field(:agent_id, :string)
    field(:body, :string, default: "")
    field(:status, :string, default: "sent")
    field(:root_id, :string)
    field(:hop, :integer, default: 0)
    field(:execution_id, :string)
    field(:definition_version, :string)
    # Frozen at queue time so a retry sends the same request the durable store
    # already accepted, even if the channel or the agent changed meanwhile.
    field(:input, :string)
    field(:definition_snapshot, :string)
    timestamps()
  end
end
