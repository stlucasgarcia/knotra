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

  @tools %{
    "order_lookup" => Tools.OrderLookup,
    "customer_lookup" => Tools.CustomerLookup,
    "stock_lookup" => Tools.StockLookup,
    "return_policy" => Tools.ReturnPolicy,
    "refund" => Tools.Refund,
    "restock" => Tools.Restock,
    "notify" => Tools.Notify
  }

  @concierge_prompt """
  You are the Storefront Concierge for an online outdoor-apparel store.
  Answer greetings, route specialist work, and propose a notice when asked.
  Routing: order=@orders, shipping=@orders, customer=@orders, return=@returns, refund=@returns, stock=@inventory, restock=@inventory, inventory=@inventory.
  Mention exactly one specialist for specialist work. Keep replies short.
  """

  @orders_prompt """
  You are the Order Desk. Use order_lookup for order status and tracking, and
  customer_lookup for tier, lifetime value and history. Ask for an order id,
  email or name when it is missing. Keep replies short.
  """

  @returns_prompt """
  You are Returns. Use return_policy to check whether an order is eligible, and
  refund to propose a refund for an eligible order. A refund is only a proposal
  until a human approves it. Ask for an order id when it is missing. Keep replies short.
  """

  @inventory_prompt """
  You are Inventory. Use stock_lookup for stock levels and restock to propose a
  reorder for a low or out-of-stock SKU. Ask for a SKU or product name when it is
  missing. Keep replies short.
  """

  @pricing_prompt """
  You are the Pricing Strategist. Argue from margin, stock cover and price
  elasticity. Choose one option and defend it in at most four sentences.
  """

  @retention_prompt """
  You are the Retention Analyst. Argue from customer lifetime value, churn risk
  and support history. Choose one option and defend it in at most four sentences.
  """

  @brand_prompt """
  You are the Brand Voice. Argue from tone, clarity and long-term customer trust.
  Choose one option and defend it in at most four sentences.
  """

  @seeds [
    %{
      id: "concierge",
      name: "Concierge",
      handle: "concierge",
      prompt: @concierge_prompt,
      tools: "notify"
    },
    %{
      id: "orders",
      name: "Order Desk",
      handle: "orders",
      prompt: @orders_prompt,
      tools: "order_lookup,customer_lookup"
    },
    %{
      id: "returns",
      name: "Returns",
      handle: "returns",
      prompt: @returns_prompt,
      tools: "order_lookup,return_policy,refund"
    },
    %{
      id: "inventory",
      name: "Inventory",
      handle: "inventory",
      prompt: @inventory_prompt,
      tools: "stock_lookup,restock"
    },
    %{
      id: "pricing",
      name: "Pricing Strategist",
      handle: "pricing",
      prompt: @pricing_prompt,
      tools: "stock_lookup"
    },
    %{
      id: "retention",
      name: "Retention Analyst",
      handle: "retention",
      prompt: @retention_prompt,
      tools: "customer_lookup"
    },
    %{id: "brand", name: "Brand Voice", handle: "brand", prompt: @brand_prompt, tools: ""}
  ]

  @tool_names ~w(order_lookup customer_lookup stock_lookup return_policy refund restock notify)

  @doc "Host tool names an agent may offer, in display order."
  def tool_names, do: @tool_names

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

  @doc """
  Builds an ephemeral definition for a coordinator-created swarm agent.

  The definition uses the configured model and only tools named in the host
  registry. A coordinator plan can therefore synthesize behavior without
  inventing modules or bypassing the host's tool surface.
  """
  def synthetic_definition(name, handle, prompt, tool_names)
      when is_binary(name) and is_binary(handle) and is_binary(prompt) and is_list(tool_names) do
    agent = %Agent{
      id: "synthetic-" <> Agent.slug(name),
      name: name,
      handle: handle,
      system_prompt: prompt,
      model: KnotraBots.configured_model(),
      tools: Enum.join(tool_names, ",")
    }

    %Knotra.Definition{
      version: "swarm-#{Agent.slug(name)}-v1",
      model: model(agent),
      tools: Enum.map(tool_names, &Map.fetch!(@tools, &1)),
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

  @doc """
  Builds the non-durable definition one swarm member runs with.

  `Knotra.start/5` dispatches only declared read-only tools and never records an
  approval, so write tools are dropped here. Consequential work keeps using the
  durable chat path, where a proposal waits for a human. The version keeps the
  swarm suffix so a member is not mistaken for a durable chat execution.
  """
  def swarm_definition(%Agent{} = agent) do
    definition = definition(agent)

    %{
      definition
      | version: definition.version <> "-swarm",
        tools: Enum.filter(definition.tools, & &1.definition().read_only)
    }
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
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    model = KnotraBots.configured_model()

    existing =
      Repo.all(from(a in Agent, select: a.id))
      |> MapSet.new()

    rows =
      @seeds
      |> Enum.reject(&MapSet.member?(existing, &1.id))
      |> Enum.map(fn seed ->
        %{
          id: seed.id,
          name: seed.name,
          handle: seed.handle,
          system_prompt: seed.prompt,
          model: model,
          tools: seed.tools,
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [], do: Repo.insert_all(Agent, rows)

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
