defmodule KnotraBots.Channel do
  @moduledoc """
  A shared chat channel. Humans and member agents post into one timeline.

  `default_agent_id` answers a message that mentions no agent; the other members
  answer when mentioned.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "channels" do
    field(:name, :string)
    field(:topic, :string, default: "")
    field(:default_agent_id, :string)
    timestamps()
  end

  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :topic, :default_agent_id])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 40)
    |> validate_length(:topic, max: 160)
    |> unique_constraint(:name)
  end
end
