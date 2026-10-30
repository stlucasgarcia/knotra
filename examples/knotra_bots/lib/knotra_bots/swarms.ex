defmodule KnotraBots.Swarms do
  @moduledoc """
  Host-owned swarm runs over a channel's agents.

  One non-durable `Knotra.Swarm` group per run, in `:fan_out`, `:board`,
  `:debate` or `:coordinator` mode. Ordinary modes use
  `KnotraBots.Agents.swarm_definition/1`, so they offer declared read-only tools
  only. Coordinator mode uses full definitions and a host write policy: the
  coordinator can synthesize specialists, assign tasks, auto-approve writes
  inside the policy, and escalate the rest. Both the chat relay
  (`/swarm ...` message) and the `/swarm` page call this module.

  Members read the same `Human:` turn shape as the chat transcript, so a host
  model that expects that format works unchanged inside a swarm.
  """

  require Logger

  alias KnotraBots.{Agents, Commerce}

  @modes [
    %{
      label: "debate",
      mode: :debate,
      title: "Debate",
      description:
        "Every agent answers the same goal independently; the selector keeps the strongest attempt.",
      use_case: "Pick one decision from competing expert views — pricing vs retention vs brand.",
      outcome: "One selected answer, plus every rejected attempt for comparison."
    },
    %{
      label: "fanout",
      mode: :fan_out,
      title: "Fan out",
      description:
        "The goal splits into comma-separated parts; agents run them concurrently and the results are merged.",
      use_case: "Split a goal into independent parts and run them in parallel.",
      outcome: "One merged report, one row per part, with the agent that handled it."
    },
    %{
      label: "board",
      mode: :board,
      title: "Shared board",
      description:
        "Members claim parts from a shared board and self-select until it is empty; no coordinator assigns work.",
      use_case: "Drain a support or operations backlog without a dispatcher.",
      outcome: "Agents claim work until the board is empty; unclaimed parts stay visible."
    },
    %{
      label: "coordinator",
      mode: :coordinator,
      title: "Coordinator",
      description: "A planner synthesizes specialists at runtime and assigns each task by name.",
      use_case: "Create the team the goal needs and route work with explicit limits.",
      outcome:
        "Created agents run assigned tasks; policy-approved writes execute; the rest escalate."
    }
  ]
  @mode_by_label Map.new(@modes, &{&1.label, &1.mode})

  @scenarios [
    %{
      id: "retention-debate",
      mode: :debate,
      channel: "growth-lab",
      title: "Late-delivery recovery",
      goal:
        "A gold customer's order is late for the second time. Choose the best recovery: " <>
          "15% credit, free expedited shipping, or a personal apology with a small credit. Defend one.",
      why: "Three specialists answer the same question; the strongest attempt is selected."
    },
    %{
      id: "launch-plan",
      mode: :fan_out,
      channel: "growth-lab",
      title: "Launch plan",
      goal:
        "choose the tone for a late-order apology email; " <>
          "choose the launch price for the $68 Summit Hoodie with 38 units in stock; " <>
          "choose the retention offer for gold customer Maya Chen with $1840 LTV and a second late delivery",
      why: "Three independent decisions run in parallel and merge into one launch brief."
    },
    %{
      id: "backlog",
      mode: :board,
      channel: "fulfillment",
      title: "Order backlog",
      goal: "check order ord-3, check order ord-4, check order ord-5, check order ord-7",
      why: "Agents claim order checks from a shared board; no coordinator assigns them."
    },
    %{
      id: "coordinator-plan",
      mode: :coordinator,
      channel: "storefront-ops",
      title: "Coordinator plan",
      goal: "Plan the refund and restock backlog",
      why:
        "A coordinator creates two specialists, assigns four tasks, auto-approves in-policy writes and escalates the rest."
    }
  ]
  @timeout 120_000

  @doc "Selectable modes, in page order, each with a title and description."
  def modes, do: @modes

  @doc "Ready-made e-commerce scenarios the page can load in one click."
  def scenarios, do: @scenarios

  @doc "One scenario by id."
  def scenario(id), do: Enum.find(@scenarios, &(&1.id == id))

  @doc "Resolves a command or page label to a mode."
  def fetch_mode(label) do
    case Map.fetch(@mode_by_label, label) do
      {:ok, mode} -> {:ok, mode}
      :error -> {:error, :unknown_mode}
    end
  end

  @doc "Human-readable explanation for a member failure shown in notes and the page."
  def error_label(:incomplete_response),
    do: "provider stopped early (often a token/thinking budget)"

  def error_label(:model_error),
    do: "provider call failed; run mix knotra_bots.check"

  def error_label(:escalation_required),
    do: "escalated to a human; no effect was performed"

  def error_label(other), do: inspect(other)

  @doc "Short label used in notes and the page."
  def label(:fan_out), do: "fanout"
  def label(mode), do: Atom.to_string(mode)

  @doc """
  Parses `/swarm [fanout|board|debate] <goal>`.

  A bare mode is rejected so `/swarm debate` cannot accidentally run with
  "debate" as the goal.
  """
  def parse_command(text) do
    rest = text |> String.replace_prefix("/swarm", "") |> String.trim()

    case String.split(rest, " ", parts: 2) do
      [label] ->
        if Map.has_key?(@mode_by_label, label),
          do: {:error, :empty_swarm_goal},
          else: parsed(:debate, rest)

      [label, goal] ->
        case Map.fetch(@mode_by_label, label) do
          {:ok, mode} -> parsed(mode, String.trim(goal))
          :error -> parsed(:debate, rest)
        end
    end
  end

  defp parsed(_mode, ""), do: {:error, :empty_swarm_goal}
  defp parsed(mode, goal), do: {:ok, mode, goal}

  @doc """
  Runs one swarm and returns `Knotra.Swarm`'s result or error.

  Blocks the calling process until the swarm settles; callers on a web path run
  it from a supervised task.
  """
  def run(agents, mode, goal) do
    {members, extra} =
      if mode == :coordinator do
        members =
          Enum.map(agents, fn agent ->
            %Knotra.Swarm.Agent{
              name: agent.name,
              definition: Agents.definition(agent),
              prompt: agent.system_prompt
            }
          end)

        {members,
         [
           plan: &coordinator_plan/2,
           write_policy: &coordinator_policy/3,
           max_created_agents: 2,
           max_tasks: 4,
           max_depth: 1
         ]}
      else
        members =
          Enum.map(agents, fn agent ->
            %Knotra.Swarm.Agent{
              name: agent.name,
              definition: Agents.swarm_definition(agent),
              prompt: agent.system_prompt
            }
          end)

        {members, []}
      end

    spec =
      struct(
        %Knotra.Swarm.Spec{
          mode: mode,
          goal: human_turn(goal),
          agents: members,
          tasks: if(mode in [:debate, :coordinator], do: [], else: tasks(goal)),
          # Tools authorize against the host scope, exactly like the durable chat
          # path; without it a tool callback matches no clause and the member
          # fails as a redacted :plugin_exception.
          context: KnotraBots.scope(),
          timeout: @timeout
        },
        extra
      )

    Knotra.Swarm.run(KnotraBots.Instance, spec, await_timeout: @timeout + 5_000)
  end

  @demo_agents ["Refund Specialist", "Stock Specialist"]
  @demo_task_ids ["refund-in-policy", "refund-escalated", "restock", "notify"]

  @coordinator_prompt """
  You are the swarm coordinator. Return only a JSON object with this shape:
  {"agents":[{"name":"...","handle":"...","prompt":"...","tools":["..."]}],
   "tasks":[{"id":"...","input":"...","agent":"...","depth":0}]}
  Create exactly the two agents and four tasks listed in the backlog. Use the
  exact task ids, the exact assigned agent names, and only allowed tools. Do not
  include the "Human:" prefix in task inputs.
  """

  @doc false
  def coordinator_plan(goal, agents) do
    case coordinator_plan_json(goal, agents) do
      {:ok, plan, trace} ->
        case normalize_coordinator_plan(plan, agents) do
          {:ok, normalized} ->
            case validate_demo_plan(normalized) do
              :ok -> {:ok, Map.put(normalized, :trace, trace)}
              {:error, reason} -> fallback_plan(reason, agents, trace)
            end

          {:error, reason} ->
            fallback_plan(reason, agents, trace)
        end

      {:error, reason, trace} ->
        fallback_plan(reason, agents, trace)
    end
  rescue
    error ->
      Logger.warning("coordinator plan raised: #{Exception.message(error)}")
      fallback_plan(:plan_raised, agents, trace_for(goal, agents))
  catch
    kind, reason ->
      Logger.warning("coordinator plan failed: #{inspect({kind, reason})}")
      fallback_plan(:plan_failed, agents, trace_for(goal, agents))
  end

  defp trace_for(goal, agents) do
    %{model: KnotraBots.configured_model(), input: planner_input(goal, agents), output: nil}
  end

  defp fallback_plan(reason, agents, trace) do
    Logger.warning("coordinator plan fallback: #{inspect(reason)}")
    trace = Map.put(trace || %{}, :fallback, reason)

    case normalize_coordinator_plan(KnotraBots.Models.CoordinatorFake.plan(), agents) do
      {:ok, normalized} -> {:ok, Map.put(normalized, :trace, trace)}
      {:error, _reason} = error -> error
    end
  end

  defp coordinator_plan_json(goal, agents) do
    input = planner_input(goal, agents)

    case KnotraBots.configured_model() do
      "fake" ->
        plan = KnotraBots.Models.CoordinatorFake.plan()

        {:ok, plan, %{model: "fake", input: input, output: JSON.encode!(plan)}}

      model ->
        {module, opts} =
          KnotraBots.req_llm_plugin(%{model: model, system_prompt: @coordinator_prompt})

        request = %{input: input, exchanges: [], tools: []}
        trace = %{model: model, input: input, output: nil}

        case module.call(request, opts) do
          {:ok, %Knotra.Reply{text: text}} ->
            trace = %{trace | output: text}

            case JSON.decode(strip_fence(text)) do
              {:ok, plan} when is_map(plan) -> {:ok, plan, trace}
              _other -> {:error, :planner_invalid_json, trace}
            end

          _other ->
            {:error, :planner_failed, trace}
        end
    end
  end

  defp planner_input(goal, agents) do
    """
    Goal: #{goal}
    Available agents: #{Enum.map_join(agents, ", ", & &1.name)}
    Allowed tools: #{Enum.join(Agents.tool_names(), ", ")}
    Backlog (use these exact task ids and assigned agents):
    - refund-in-policy: refund ord-5 because it arrived late -> Refund Specialist
    - refund-escalated: refund ord-3 because it arrived late -> Refund Specialist
    - restock: restock sku-tee-01 by 24 units -> Stock Specialist
    - notify: notify ops that ord-4 is delayed -> Concierge
    Create agents Refund Specialist with tools order_lookup, return_policy, refund
    and Stock Specialist with tools stock_lookup, restock.
    """
  end

  @doc false
  def validate_demo_plan(%{agents: created, tasks: tasks}) do
    names = Enum.map(created, & &1.name)
    ids = Enum.map(tasks, & &1.id)

    if Enum.sort(names) == Enum.sort(@demo_agents) and
         Enum.sort(ids) == Enum.sort(@demo_task_ids),
       do: :ok,
       else: {:error, :non_demo_plan}
  end

  def validate_demo_plan(_plan), do: {:error, :non_demo_plan}

  defp strip_fence(text) do
    text
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end

  @doc false
  def normalize_coordinator_plan(
        %{"agents" => agent_specs, "tasks" => task_specs},
        agents
      )
      when is_list(agent_specs) and is_list(task_specs) do
    created = Enum.map(agent_specs, &build_plan_agent/1)
    names = MapSet.new(Enum.map(agents, & &1.name) ++ Enum.map(created, & &1.name))
    tasks = Enum.map(task_specs, &build_plan_task(&1, names, agents))
    {:ok, %{agents: created, tasks: tasks}}
  end

  def normalize_coordinator_plan(_plan, _agents), do: {:error, :invalid_plan}

  defp build_plan_agent(%{
         "name" => name,
         "handle" => handle,
         "prompt" => prompt,
         "tools" => tools
       })
       when is_binary(name) and is_binary(handle) and is_binary(prompt) and is_list(tools) do
    %Knotra.Swarm.Agent{
      name: name,
      definition: Agents.synthetic_definition(name, handle, prompt, tools),
      prompt: prompt
    }
  end

  defp build_plan_agent(_spec), do: raise(ArgumentError, "invalid coordinator agent")

  defp build_plan_task(%{"id" => id, "input" => input, "agent" => agent}, names, agents)
       when is_binary(id) and is_binary(input) and is_binary(agent) do
    agent =
      if agent == "Concierge" and not MapSet.member?(names, agent),
        do: hd(agents).name,
        else: agent

    # The demo coordinator plans one round. Ignore model-provided depth noise
    # (null, strings, or deeper values) rather than failing the whole swarm.
    %{id: id, input: human_turn(input), agent: agent, depth: 0}
  end

  defp build_plan_task(_spec, _names, _agents),
    do: raise(ArgumentError, "invalid coordinator task")

  @doc false
  def coordinator_policy(%{name: "refund"}, %{"order" => order}, _opts) do
    case Commerce.order(order) do
      nil ->
        {:escalate, :unknown_order}

      record ->
        if Commerce.return_policy(record).eligible and Commerce.total_cents(record) <= 5_000 do
          :approve
        else
          {:escalate, :refund_over_limit}
        end
    end
  end

  def coordinator_policy(%{name: "restock"}, %{"quantity" => quantity}, _opts)
      when quantity <= 24,
      do: :approve

  def coordinator_policy(%{name: "notify"}, _args, _opts), do: :approve
  def coordinator_policy(_call, _args, _opts), do: {:escalate, :outside_policy}

  # Fan-out and board tasks come from the goal itself: each comma, semicolon or
  # newline starts one required part. A single part is still a valid swarm.
  defp tasks(goal) do
    parts =
      goal
      |> String.split(~r/[,;\n]/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    parts = if parts == [], do: [goal], else: parts

    parts
    |> Enum.with_index(1)
    |> Enum.map(fn {input, n} -> %{id: "task-#{n}", input: human_turn(input)} end)
  end

  defp human_turn(text), do: "Human: " <> text
end
