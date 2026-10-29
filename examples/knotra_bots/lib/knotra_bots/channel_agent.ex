defmodule KnotraBots.ChannelAgent do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "channel_agents" do
    field(:channel_id, :string)
    field(:agent_id, :string)
  end
end
