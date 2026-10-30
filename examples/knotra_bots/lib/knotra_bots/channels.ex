defmodule KnotraBots.Channels do
  @moduledoc """
  Host-owned chat channels and their agent membership.

  A channel has zero or more agents and one default responder. Creating a channel
  validates that every selected agent exists and inserts the membership rows in
  the same transaction.
  """

  import Ecto.Query
  require Logger

  alias KnotraBots.{Agent, Channel, ChannelAgent, Message, Repo}

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
  Seeds three starter channels when the table is empty.

  `storefront-ops` carries the guided e-commerce tour and a handoff path;
  `growth-lab` gives the strategy personas a room for debates and fan-out; and
  `fulfillment` pairs the order desk with returns for the shared-board backlog.
  """
  def seed! do
    seed_channel(
      "storefront-ops",
      "Agentic storefront: orders, returns and inventory. Try a guided prompt.",
      ["concierge", "orders", "inventory", "returns"],
      "concierge",
      storefront_tour()
    )

    seed_channel(
      "growth-lab",
      "Three specialists, one goal. Debate a retention offer or fan out a launch audit.",
      ["pricing", "retention", "brand"],
      "pricing",
      growth_tour()
    )

    seed_channel(
      "fulfillment",
      "Backlog triage. Run /swarm board ... or load the Order backlog scenario.",
      ["orders", "returns"],
      "orders",
      fulfillment_tour()
    )

    :ok
  rescue
    # The host migrates out-of-band; a boot before migration has nothing to seed.
    error ->
      Logger.warning("channel seed skipped: #{Exception.message(error)}")
      :ok
  end

  defp seed_channel(name, topic, agent_ids, default_id, note) do
    if Repo.get_by(Channel, name: name) do
      :ok
    else
      agents = Repo.all(from(a in Agent, where: a.id in ^agent_ids, order_by: [asc: a.name]))

      if length(agents) == length(agent_ids) do
        attrs = %{
          "name" => name,
          "topic" => topic,
          "agent_ids" => Enum.map(agents, & &1.id),
          "default_agent_id" => default_id
        }

        case create(attrs) do
          {:ok, channel} ->
            system(channel, note)
            :ok

          {:error, reason} ->
            Logger.warning("channel seed skipped for #{name}: #{inspect(reason)}")
            :ok
        end
      else
        Logger.warning("channel seed skipped for #{name}: agents not ready")
        :ok
      end
    end
  end

  defp storefront_tour do
    """
    Guided tour — send one of these:
    • can you check order ord-3?              → @concierge routes to @orders
    • is ord-3 eligible for a return?         → @returns checks the 30-day policy
    • refund ord-3 because it arrived late    → @returns proposes; approve to write
    • restock sku-tee-01                      → @inventory proposes; approve to write
    • notify ops that ord-4 is delayed        → approval-gated notice
    Swarms: open /swarm and load a scenario (growth-lab debate, fulfillment backlog).
    """
  end

  defp growth_tour do
    """
    Growth lab — three specialists, one goal.
    Try /swarm debate A gold customer's order is late: choose 15% credit, free expedited shipping, or a personal apology.
    Or open /swarm and load a scenario to compare debate, fan-out and shared-board work.
    """
  end

  defp fulfillment_tour do
    """
    Shared-board demo: agents claim order checks until the board is empty.
    Try /swarm board check order ord-3, check order ord-4, check order ord-5, check order ord-7
    """
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
