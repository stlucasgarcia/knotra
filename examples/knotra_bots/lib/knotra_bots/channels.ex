defmodule KnotraBots.Channels do
  @moduledoc """
  Host-owned chat channels and their agent membership.

  A channel has zero or more agents and one default responder. Creating a channel
  validates that every selected agent exists and inserts the membership rows in
  the same transaction.
  """

  import Ecto.Query
  require Logger

  alias KnotraBots.{Agent, Agents, Channel, ChannelAgent, Message, Repo}

  def list, do: Repo.all(from(c in Channel, order_by: [asc: c.inserted_at, asc: c.name]))
  def get(id), do: Repo.get(Channel, id)

  def get!(id), do: Repo.get!(Channel, id)

  @doc "The channel's agents, alphabetically."
  def agents(channel_id) do
    Repo.all(
      from(a in Agent,
        join: ca in ChannelAgent,
        on: ca.agent_id == a.id,
        where: ca.channel_id == ^channel_id,
        order_by: [asc: a.name]
      )
    )
  end

  def agent_ids(channel_id) do
    Repo.all(from(ca in ChannelAgent, where: ca.channel_id == ^channel_id, select: ca.agent_id))
  end

  @doc """
  Creates a channel and its memberships.

  `attrs` is a string-keyed map from the form: `name`, `topic`, `agent_ids` and
  an optional `default_agent_id`. The default falls back to the first selected
  agent when it is missing or not a member.
  """
  def create(attrs) do
    name = attrs |> Map.get("name", "") |> to_string() |> String.trim()
    topic = attrs |> Map.get("topic", "") |> to_string() |> String.trim()

    requested =
      attrs
      |> Map.get("agent_ids", [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    case Repo.all(from(a in Agent, where: a.id in ^requested, order_by: [asc: a.name])) do
      [] ->
        {:error, :no_agents}

      agents ->
        ids = Enum.map(agents, & &1.id)
        default = attrs["default_agent_id"]
        default = if default in ids, do: default, else: hd(ids)

        changeset =
          Channel.changeset(%Channel{id: new_id()}, %{
            "name" => name,
            "topic" => topic,
            "default_agent_id" => default
          })

        Repo.transaction(fn ->
          case Repo.insert(changeset) do
            {:ok, channel} ->
              rows = Enum.map(ids, &%{channel_id: channel.id, agent_id: &1})
              {_, _} = Repo.insert_all(ChannelAgent, rows)
              channel

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, channel} -> {:ok, channel}
          {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Seeds two starter channels when the table is empty.

  `Ops` pairs the concierge (default) with the researcher so the offline demo
  shows a handoff; `General` gives the assistant a room of its own.
  """
  def seed! do
    if Repo.aggregate(Channel, :count) == 0 do
      with %Agent{} = concierge <- Agents.get("concierge"),
           %Agent{} = researcher <- Agents.get("researcher") do
        {:ok, ops} =
          create(%{
            "name" => "Ops",
            "topic" => "Order questions and notices. Try: can you check order ord-1?",
            "agent_ids" => [concierge.id, researcher.id],
            "default_agent_id" => concierge.id
          })

        system(
          ops,
          "Mention @researcher or @concierge to assign work. Without a mention, @concierge answers."
        )
      end

      with %Agent{} = assistant <- Agents.get("assistant") do
        {:ok, general} =
          create(%{
            "name" => "General",
            "topic" => "Ask anything.",
            "agent_ids" => [assistant.id],
            "default_agent_id" => assistant.id
          })

        system(general, "Mention @assistant to assign work.")
      end
    end

    :ok
  rescue
    # The host migrates out-of-band; a boot before migration has nothing to seed.
    error ->
      Logger.warning("channel seed skipped: #{Exception.message(error)}")
      :ok
  end

  defp system(channel, body) do
    now = NaiveDateTime.utc_now()

    %Message{
      id: "msg-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      channel_id: channel.id,
      author_type: "system",
      body: body,
      status: "sent",
      hop: 0,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp new_id, do: "chan-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
