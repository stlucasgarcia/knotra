defmodule KnotraBots.Conversation do
  @moduledoc """
  Host-owned conversation between two bots.

  `status` is one of `running`, `stopping`, `stopped`, `interrupted` or `completed`.
  """
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "conversations" do
    field(:bot_a_id, :string)
    field(:bot_b_id, :string)
    field(:topic, :string)
    field(:rounds, :integer, default: 4)
    field(:status, :string, default: "running")
    timestamps()
  end
end
