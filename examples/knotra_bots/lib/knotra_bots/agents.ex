defmodule KnotraBots.Agents do
  @moduledoc """
  Host-owned agent rows and the durable definitions built from them.

  Edits bump `revision`, so a definition version (`agent-<id>-r<revision>`)
  changes whenever the prompt, model or tools do. Chat messages pin that version
  through their execution, which keeps an answered pending interaction compatible
  only with the composition that produced it.
  """

  import Ecto.Query, except: [update: 2]

  alias KnotraBots.{Agent, ChannelAgent, Repo}
  alias KnotraBots.Tools

  @tools %{"lookup" => Tools.Lookup, "notify" => Tools.Notify}

  @assistant_prompt "You are a concise general assistant. Ask one short clarifying question when a request is ambiguous."
  @researcher_prompt """
  You research orders with the lookup tool. Use an order id such as ord-1.
  When you need a detail, ask one short question. Keep replies short.
  """
  @concierge_prompt """
  You are the workspace concierge. For order, shipping, or lookup questions,
  hand off to @researcher by mentioning them. For notice or message requests,
  propose the notify operation. Keep replies short.
  """

  @doc "Host tool names an agent may offer."
  def tool_names, do: Map.keys(@tools)

  def list, do: Repo.all(from(a in Agent, order_by: [asc: a.name]))
  def get(id), do: Repo.get(Agent, id)
  def get!(id), do: Repo.get!(Agent, id)

  @doc "Builds the durable definition for one chat message."
  def definition(%Agent{} = agent) do
    %Knotra.Definition{
      version: "agent-#{agent.id}-r#{agent.revision}",
      model: model(agent),
      tools: tool_modules(agent),
      observer: {Knotra.Observers.Send, nil}
    }
  end

  @doc "The tool modules an agent offers."
  def tool_modules(%Agent{tools: tools}), do: Enum.map(split(tools), &Map.fetch!(@tools, &1))

  @doc "True when the agent offers the named tool and that tool is declared read-only."
  def read_only_tool?(%Agent{} = agent, name) when is_binary(name) do
    Enum.any?(tool_modules(agent), fn module ->
      definition = module.definition()
      definition.name == name and definition.read_only == true
    end)
  end

  def read_only_tool?(_agent, _name), do: false

  def create(attrs) do
    %Agent{id: new_id()}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  def create!(attrs) do
    case create(attrs) do
      {:ok, agent} ->
        agent

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  def update(%Agent{} = agent, attrs) do
    changeset = Agent.changeset(agent, attrs)

    if changeset.valid? do
      updated_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      changes =
        changeset.changes
        |> Map.put(:updated_at, updated_at)
        |> Map.put(:revision, agent.revision + 1)

      set = Keyword.new(changes)

      query =
        from(a in Agent,
          where: a.id == ^agent.id and a.revision == ^agent.revision,
          update: [set: ^set]
        )

      case Repo.update_all(query, []) do
        {1, _} ->
          {:ok, struct(agent, changes)}

        {0, _} ->
          {:error, :stale}
      end
    else
      {:error, changeset}
    end
  end

  def update!(%Agent{} = agent, attrs) do
    case update(agent, attrs) do
      {:ok, agent} ->
        agent

      {:error, :stale} ->
        raise ArgumentError, "agent #{agent.id} changed since it was loaded"

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  @doc "Deletes an agent unless a channel still lists it."
  def delete(%Agent{} = agent) do
    referenced? = Repo.exists?(from(ca in ChannelAgent, where: ca.agent_id == ^agent.id))

    if referenced? do
      {:error, :referenced}
    else
      try do
        case Repo.delete(agent) do
          {:ok, deleted} -> {:ok, deleted}
          {:error, changeset} -> {:error, changeset}
        end
      rescue
        # A channel referencing the agent can commit between the check and the
        # delete; the restrictive foreign key then rejects it.
        Ecto.ConstraintError -> {:error, :referenced}
      end
    end
  end

  @doc "JSON snapshot of the fields a durable definition is built from."
  def definition_snapshot(%Agent{} = agent) do
    JSON.encode!(%{
      "id" => agent.id,
      "revision" => agent.revision,
      "name" => agent.name,
      "handle" => agent.handle,
      "system_prompt" => agent.system_prompt,
      "model" => agent.model,
      "tools" => agent.tools
    })
  end

  @doc "Rebuilds the definition a queued message was created with."
  def definition_from_snapshot(json, %Agent{} = fallback) do
    case json && JSON.decode(json) do
      {:ok, snapshot} when is_map(snapshot) ->
        definition(%Agent{
          id: snapshot["id"],
          revision: snapshot["revision"],
          name: snapshot["name"],
          handle: snapshot["handle"],
          system_prompt: snapshot["system_prompt"],
          model: snapshot["model"],
          tools: snapshot["tools"]
        })

      _ ->
        definition(fallback)
    end
  end

  @doc """
  Seeds three chat agents when the table is empty.

  The configured model is used, so a `KNOTRA_BOTS_MODEL=fake` (or test) run seeds
  offline agents while the default run seeds Gemini agents.
  """
  def seed! do
    if Repo.aggregate(Agent, :count) == 0 do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      model = KnotraBots.configured_model()

      Repo.insert_all(Agent, [
        %{
          id: "assistant",
          name: "Assistant",
          handle: "assistant",
          system_prompt: @assistant_prompt,
          model: model,
          tools: "",
          revision: 1,
          inserted_at: now,
          updated_at: now
        },
        %{
          id: "researcher",
          name: "Researcher",
          handle: "researcher",
          system_prompt: @researcher_prompt,
          model: model,
          tools: "lookup",
          revision: 1,
          inserted_at: now,
          updated_at: now
        },
        %{
          id: "concierge",
          name: "Concierge",
          handle: "concierge",
          system_prompt: @concierge_prompt,
          model: model,
          tools: "notify",
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    :ok
  end

  defp model(%Agent{model: "fake"} = agent) do
    {KnotraBots.Models.ChatFake,
     [name: agent.name, handle: agent.handle, system_prompt: agent.system_prompt]}
  end

  defp model(%Agent{} = agent), do: KnotraBots.req_llm_plugin(agent)

  defp split(""), do: []
  defp split(names), do: names |> String.split(",", trim: true) |> Enum.uniq()

  defp new_id, do: "agent-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
