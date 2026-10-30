defmodule Knotra.SwarmTest do
  @moduledoc """
  Swarm behavior without a provider: stub models and definitions exercise all
  three modes, failure isolation, capacity retry, deadline and cancellation.
  """
  use ExUnit.Case, async: true

  alias Knotra.{Definition, Reply}
  alias Knotra.Swarm.{Agent, Result, Spec}

  defmodule Model do
    @behaviour Knotra.Model
    @impl true
    def call(request, opts), do: Keyword.fetch!(opts, :respond).(request)
  end

  defmodule WriteProbe do
    @behaviour Knotra.Tool

    @impl true
    def definition do
      %{
        name: "write_probe",
        description: "records a write",
        read_only: false,
        parameters: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}},
          "required" => ["value"],
          "additionalProperties" => false
        }
      }
    end

    @impl true
    def validate(%{"value" => value} = args)
        when is_binary(value) and value != "" and map_size(args) == 1,
        do: {:ok, args}

    def validate(_args), do: {:error, :invalid_arguments}

    @impl true
    def authorize(_args, _scope), do: :ok

    @impl true
    def call(%{"value" => value}, _scope) do
      send(:persistent_term.get({__MODULE__, :witness}), {:wrote, value})
      {:ok, "wrote " <> value}
    end
  end

  setup do
    name = :"swarm_test_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Knotra, name: name, max_executions: 32})
    %{instance: name}
  end

  test "fan-out runs every task concurrently and merges in task order", %{instance: instance} do
    barrier = start_barrier(4)

    agents =
      for n <- 1..4 do
        agent("agent-#{n}", fn request ->
          send(barrier, {:arrive, self()})

          receive do
            :pass -> {:ok, %Reply{text: "out:" <> request.input}}
          after
            2_000 -> {:error, :barrier_timeout}
          end
        end)
      end

    spec = %Spec{
      mode: :fan_out,
      goal: "add two numbers",
      agents: agents,
      tasks: for(n <- 1..4, do: %{id: "task-#{n}", input: "value-#{n}"}),
      timeout: 5_000
    }

    assert {:ok, %Result{status: :completed, output: output, tasks: parts}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert output ==
             "task-1: out:value-1\n\ntask-2: out:value-2\n\ntask-3: out:value-3\n\ntask-4: out:value-4"

    assert Enum.map(parts, & &1.status) == [:completed, :completed, :completed, :completed]
    assert Enum.map(parts, & &1.id) == ["task-1", "task-2", "task-3", "task-4"]
    assert_no_executions(instance)
  end

  test "children are traced into one observability conversation", %{instance: instance} do
    agents = [agent("left", &echo/1), agent("right", &echo/1)]

    spec = %Spec{
      mode: :fan_out,
      goal: "traced",
      agents: agents,
      tasks: [%{id: "a", input: "1"}, %{id: "b", input: "2"}]
    }

    assert {:ok, %Result{swarm_id: swarm_id, tasks: parts}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert String.starts_with?(swarm_id, "swarm-")
    assert Enum.all?(parts, &is_integer(&1.elapsed_ms))
    assert Enum.all?(parts, &match?(%{turns: 1}, &1.counts))

    assert {:ok, executions} = Knotra.Observability.executions(instance)
    traced = Enum.filter(executions, &(&1.trace.conversation_id == swarm_id))

    assert length(traced) == 2
    assert traced |> Enum.map(& &1.trace.agent) |> Enum.sort() == ["left", "right"]
    assert Enum.all?(traced, &(&1.trace.labels["mode"] == "fanout"))

    assert traced |> Enum.map(& &1.trace.labels["part"]) |> Enum.sort() == ["a", "b"]
  end

  test "fan-out decomposition produces the task list once", %{instance: instance} do
    caller = self()

    spec = %Spec{
      mode: :fan_out,
      goal: "split",
      agents: [agent("solo", &echo/1)],
      decompose: fn goal, agents ->
        send(caller, {:decomposed, goal, length(agents)})
        {:ok, [%{id: "a", input: "one"}, %{id: "b", input: "two"}]}
      end
    }

    assert {:ok, %Result{status: :completed, output: "a: out:one\n\nb: out:two", tasks: parts}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert_receive {:decomposed, "split", 1}
    assert Enum.map(parts, & &1.id) == ["a", "b"]
  end

  test "fan-out assigns more tasks than agents round-robin", %{instance: instance} do
    agents = [agent("one", &echo/1), agent("two", &echo/1)]

    spec = %Spec{
      mode: :fan_out,
      goal: "many",
      agents: agents,
      tasks: for(n <- 1..4, do: %{id: "t#{n}", input: "i#{n}"})
    }

    assert {:ok, %Result{tasks: parts}} = Knotra.Swarm.run(instance, spec, await_timeout: 5_000)
    assert Enum.map(parts, & &1.agent) == ["one", "two", "one", "two"]
  end

  test "board members claim distinct tasks and self-select until empty", %{instance: instance} do
    test = self()

    agents =
      for n <- 1..3 do
        agent("member-#{n}", fn request ->
          send(test, {:model_start, request.input, self()})

          receive do
            {:release, input} when input == request.input -> {:ok, %Reply{text: "out:" <> input}}
          after
            2_000 -> {:error, :release_timeout}
          end
        end)
      end

    spec = %Spec{
      mode: :board,
      goal: "drain the board",
      agents: agents,
      tasks: for(n <- 1..3, do: %{id: "t#{n}", input: "work-#{n}"}),
      timeout: 5_000
    }

    {:ok, swarm} = Knotra.Swarm.start(instance, spec)

    starts =
      for _ <- 1..3 do
        assert_receive {:model_start, input, pid}, 2_000
        {input, pid}
      end

    # Every member started on its own task before any result existed.
    assert length(Enum.uniq(Enum.map(starts, &elem(&1, 0)))) == 3

    Enum.each(starts, fn {input, pid} -> send(pid, {:release, input}) end)

    assert {:ok, %Result{status: :completed, tasks: parts}} =
             Knotra.Swarm.await(swarm, 5_000)

    assert Enum.all?(parts, &(&1.status == :completed))

    assert MapSet.new(Enum.map(parts, & &1.agent)) ==
             MapSet.new(["member-1", "member-2", "member-3"])

    assert_no_executions(instance)
  end

  test "board self-selection with a scripted model completes every task once",
       %{instance: instance} do
    test = self()

    agents =
      for n <- 1..3 do
        agent("member-#{n}", fn request ->
          send(test, {:model_input, request.input})
          Process.sleep(20)
          {:ok, %Reply{text: "out:" <> request.input}}
        end)
      end

    tasks = for(n <- 1..9, do: %{id: "t#{n}", input: "work-#{n}"})

    spec = %Spec{
      mode: :board,
      goal: "nine pieces",
      agents: agents,
      tasks: tasks,
      timeout: 10_000
    }

    assert {:ok, %Result{status: :completed, output: output, tasks: parts}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 10_000)

    assert Enum.map(parts, & &1.id) == Enum.map(tasks, & &1.id)
    assert Enum.all?(parts, &(&1.status == :completed))
    assert Enum.all?(parts, &(&1.agent in ["member-1", "member-2", "member-3"]))
    assert output =~ "t1: out:work-1"
    assert length(Enum.uniq(collect_inputs())) == 9
    assert_no_executions(instance)
  end

  test "debate keeps every attempt and selects the longest by default", %{instance: instance} do
    agents = [
      agent("short", fn _ -> {:ok, %Reply{text: "a"}} end),
      agent("long", fn _ -> {:ok, %Reply{text: "the longest answer"}} end),
      agent("medium", fn _ -> {:ok, %Reply{text: "medium"}} end)
    ]

    spec = %Spec{mode: :debate, goal: "pick one", agents: agents}

    assert {:ok, %Result{selected: 1, output: "the longest answer", tasks: parts}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert length(parts) == 3
    assert Enum.map(parts, & &1.status) == [:completed, :completed, :completed]
  end

  test "debate accepts a custom merge selector", %{instance: instance} do
    agents = [
      agent("a", fn _ -> {:ok, %Reply{text: "first"}} end),
      agent("b", fn _ -> {:ok, %Reply{text: "second"}} end)
    ]

    spec = %Spec{
      mode: :debate,
      goal: "merge",
      agents: agents,
      select: fn _goal, attempts ->
        {:merge, Enum.map_join(attempts, "+", & &1.output)}
      end
    }

    assert {:ok, %Result{status: :completed, output: "first+second", selected: nil}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)
  end

  test "a failed part is isolated and makes the swarm incomplete", %{instance: instance} do
    agents = [
      agent("ok", &echo/1),
      agent("broken", fn _ -> {:error, :boom} end)
    ]

    spec = %Spec{
      mode: :fan_out,
      goal: "partial",
      agents: agents,
      tasks: [%{id: "good", input: "yes"}, %{id: "bad", input: "no"}]
    }

    assert {:error, {:incomplete, %Result{status: :partial, tasks: parts} = result}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert result.output =~ "good: out:yes"
    refute result.output =~ "bad:"

    assert Enum.map(parts, &{&1.id, &1.status, &1.error}) == [
             {"good", :completed, nil},
             {"bad", :failed, :boom}
           ]

    assert_no_executions(instance)
  end

  test "instance capacity is retried instead of failing queued work" do
    name = :"swarm_capacity_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Knotra, name: name, max_executions: 1})

    spec = %Spec{
      mode: :fan_out,
      goal: "queue",
      agents: [agent("solo", &echo/1)],
      tasks: for(n <- 1..3, do: %{id: "t#{n}", input: "i#{n}"}),
      timeout: 5_000
    }

    assert {:ok, %Result{status: :completed}} =
             Knotra.Swarm.run(name, spec, await_timeout: 5_000)

    assert_no_executions(name)
  end

  test "the swarm deadline cancels running executions", %{instance: instance} do
    slow = fn _request ->
      Process.sleep(5_000)
      {:ok, %Reply{text: "late"}}
    end

    spec = %Spec{mode: :debate, goal: "slow", agents: [agent("slow", slow)], timeout: 150}

    assert {:error, :timeout} = Knotra.Swarm.run(instance, spec, await_timeout: 5_000)
    assert_no_executions(instance)
  end

  test "cancel/1 stops the swarm and answers a waiting caller", %{instance: instance} do
    slow = fn _request ->
      Process.sleep(5_000)
      {:ok, %Reply{text: "late"}}
    end

    spec = %Spec{mode: :debate, goal: "slow", agents: [agent("slow", slow)], timeout: 10_000}

    {:ok, swarm} = Knotra.Swarm.start(instance, spec)
    task = Task.async(fn -> Knotra.Swarm.await(swarm, 5_000) end)
    Process.sleep(50)
    assert :ok = Knotra.Swarm.cancel(swarm)
    assert {:error, :cancelled} = Task.await(task, 5_000)
    assert_no_executions(instance)
  end

  test "snapshot reports progress while work is queued", %{instance: instance} do
    spec = %Spec{
      mode: :fan_out,
      goal: "progress",
      agents: [agent("solo", &echo/1)],
      tasks: [%{id: "t1", input: "i1"}, %{id: "t2", input: "i2"}, %{id: "t3", input: "i3"}],
      max_concurrency: 1
    }

    {:ok, swarm} = Knotra.Swarm.start(instance, spec)
    progress = Knotra.Swarm.snapshot(swarm)

    assert progress.mode == :fan_out
    assert progress.status == :running
    assert progress.agents == 1
    assert progress.tasks == 3
    assert {:ok, %Result{status: :completed}} = Knotra.Swarm.await(swarm, 5_000)
  end

  test "a coordinator plan creates agents and assigns their tasks", %{instance: instance} do
    plan = fn _goal, _agents ->
      {:ok,
       %{
         agents: [
           %Agent{
             name: "created-a",
             definition: %Definition{version: "p1", model: {Model, respond: &echo/1}}
           },
           %Agent{
             name: "created-b",
             definition: %Definition{version: "p1", model: {Model, respond: &echo/1}}
           }
         ],
         tasks: [
           %{id: "t1", input: "one", agent: "created-a", depth: 0},
           %{id: "t2", input: "two", agent: "created-b", depth: 0}
         ],
         trace: %{model: "test-coordinator", input: "plan input", output: "plan output"}
       }}
    end

    spec = %Spec{
      mode: :coordinator,
      goal: "plan work",
      agents: [agent("predeclared", &echo/1)],
      plan: plan,
      timeout: 5_000
    }

    assert {:ok,
            %Result{
              status: :completed,
              agents: agents,
              tasks: parts,
              agent_details: details,
              swarm_id: swarm_id
            }} = Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert Enum.sort(agents) == ["created-a", "created-b", "predeclared"]
    assert Enum.map(parts, & &1.agent) == ["created-a", "created-b"]
    assert Enum.map(parts, & &1.status) == [:completed, :completed]
    assert Enum.all?(parts, &(&1.iteration == 1))

    assert Enum.any?(
             details,
             &(&1.name == "created-a" and &1.created and &1.version == "p1")
           )

    assert Enum.any?(
             details,
             &(&1.name == "predeclared" and not &1.created and &1.version == "v1")
           )

    assert {:ok, executions} = Knotra.Observability.executions(instance)
    traced = Enum.filter(executions, &(&1.trace.conversation_id == swarm_id))
    assert traced |> Enum.map(& &1.trace.agent) |> Enum.sort() == ["created-a", "created-b"]

    Knotra.Observability.sync(instance)
    assert {:ok, [summary]} = Knotra.Observability.swarms(instance)
    assert summary.id == swarm_id
    assert summary.mode == :coordinator
    assert summary.created_agents == ["created-a", "created-b"]
    assert summary.tasks == 2

    assert {:ok, detail} = Knotra.Observability.swarm(instance, swarm_id)
    assert detail.swarm.planner.output == "plan output"
    assert detail.swarm.planner.input == "plan input"
    assert Enum.any?(detail.timeline, &(&1.source == "coordinator" and &1.type == :planned))
    assert Enum.any?(detail.timeline, &(&1.type == :task_finished))
    assert Enum.any?(detail.timeline, &(&1.source == "created-a"))
  end

  test "a board plan lets predeclared and created agents share the board",
       %{instance: instance} do
    plan = fn _goal, _agents ->
      {:ok,
       %{
         agents: [
           %Agent{
             name: "created",
             definition: %Definition{version: "p1", model: {Model, respond: &echo/1}}
           }
         ],
         tasks: [
           %{id: "a", input: "one"},
           %{id: "b", input: "two"}
         ]
       }}
    end

    spec = %Spec{
      mode: :board,
      goal: "drain",
      agents: [agent("predeclared", &echo/1)],
      plan: plan,
      timeout: 5_000
    }

    assert {:ok,
            %Result{status: :completed, agents: agents, tasks: parts, agent_details: details}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert Enum.sort(agents) == ["created", "predeclared"]
    assert Enum.map(parts, & &1.id) == ["a", "b"]
    assert Enum.all?(parts, &(&1.status == :completed))
    assert Enum.all?(parts, &(&1.iteration == 1))
    assert Enum.any?(details, &(&1.name == "created" and &1.created))
    assert Enum.any?(details, &(&1.name == "predeclared" and not &1.created))
  end

  test "an in-policy write executes once", %{instance: instance} do
    :persistent_term.put({WriteProbe, :witness}, self())
    on_exit(fn -> :persistent_term.erase({WriteProbe, :witness}) end)

    respond = fn request ->
      if request.exchanges == [] do
        {:ok,
         %Reply{
           calls: [
             %{id: "write-1", name: "write_probe", arguments: %{"value" => "allowed"}}
           ]
         }}
      else
        {:ok, %Reply{text: "done"}}
      end
    end

    plan = fn _goal, _agents ->
      {:ok,
       %{
         agents: [
           %Agent{
             name: "writer",
             definition: %Definition{
               version: "p1",
               model: {Model, respond: respond},
               tools: [WriteProbe]
             }
           }
         ],
         tasks: [%{id: "write", input: "do it", agent: "writer", depth: 0}]
       }}
    end

    spec = %Spec{
      mode: :coordinator,
      goal: "write",
      agents: [agent("predeclared", &echo/1)],
      plan: plan,
      write_policy: fn _call, _args, _opts -> :approve end,
      timeout: 5_000
    }

    assert {:ok, %Result{status: :completed, escalations: [], tasks: [part]}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert part.output == "done"
    assert_receive {:wrote, "allowed"}
  end

  test "an out-of-policy write escalates without an effect", %{instance: instance} do
    :persistent_term.put({WriteProbe, :witness}, self())
    on_exit(fn -> :persistent_term.erase({WriteProbe, :witness}) end)

    respond = fn request ->
      if request.exchanges == [] do
        {:ok,
         %Reply{
           calls: [
             %{id: "write-1", name: "write_probe", arguments: %{"value" => "blocked"}}
           ]
         }}
      else
        {:ok, %Reply{text: "done"}}
      end
    end

    plan = fn _goal, _agents ->
      {:ok,
       %{
         agents: [
           %Agent{
             name: "writer",
             definition: %Definition{
               version: "p1",
               model: {Model, respond: respond},
               tools: [WriteProbe]
             }
           }
         ],
         tasks: [
           %{id: "write", input: "do it", agent: "writer", depth: 0},
           %{id: "still-works", input: "keep going", agent: "predeclared", depth: 0}
         ]
       }}
    end

    spec = %Spec{
      mode: :coordinator,
      goal: "write",
      agents: [agent("predeclared", &echo/1)],
      plan: plan,
      write_policy: fn _call, _args, _opts -> {:escalate, :over_limit} end,
      timeout: 5_000
    }

    assert {:error, {:incomplete, %Result{escalations: [escalation], tasks: parts}}} =
             Knotra.Swarm.run(instance, spec, await_timeout: 5_000)

    assert Enum.find(parts, &(&1.id == "still-works")).status == :completed

    part = Enum.find(parts, &(&1.id == "write"))
    assert part.status == :failed
    assert part.error == :escalation_required
    assert escalation.agent == "writer"
    assert escalation.task == "write"
    assert escalation.tool == "write_probe"
    assert escalation.arguments == %{"value" => "blocked"}
    assert escalation.reason == :over_limit
    refute_receive {:wrote, _value}, 100
  end

  test "plans are rejected before work starts when caps are exceeded", %{instance: instance} do
    created = fn name ->
      %Agent{
        name: name,
        definition: %Definition{version: "p1", model: {Model, respond: &echo/1}}
      }
    end

    base = %Spec{
      mode: :coordinator,
      goal: "caps",
      agents: [agent("predeclared", &echo/1)],
      timeout: 5_000
    }

    assert {:error, :plan_agent_limit} =
             Knotra.Swarm.run(instance, %{
               base
               | max_created_agents: 1,
                 plan: fn _goal, _agents ->
                   {:ok,
                    %{
                      agents: [created.("a"), created.("b")],
                      tasks: [%{id: "t", input: "x", agent: "a", depth: 0}]
                    }}
                 end
             })

    assert {:error, :plan_task_limit} =
             Knotra.Swarm.run(instance, %{
               base
               | max_tasks: 1,
                 plan: fn _goal, _agents ->
                   {:ok,
                    %{
                      agents: [],
                      tasks: [
                        %{id: "a", input: "x", agent: "predeclared", depth: 0},
                        %{id: "b", input: "y", agent: "predeclared", depth: 0}
                      ]
                    }}
                 end
             })

    assert {:error, :task_depth_exceeded} =
             Knotra.Swarm.run(instance, %{
               base
               | max_depth: 1,
                 plan: fn _goal, _agents ->
                   {:ok,
                    %{
                      agents: [],
                      tasks: [%{id: "a", input: "x", agent: "predeclared", depth: 2}]
                    }}
                 end
             })

    assert {:error, :missing_task_agent} =
             Knotra.Swarm.run(instance, %{
               base
               | plan: fn _goal, _agents ->
                   {:ok, %{agents: [], tasks: [%{id: "a", input: "x", depth: 0}]}}
                 end
             })
  end

  test "invalid specs fail before any process starts", %{instance: instance} do
    agents = [agent("one", &echo/1), agent("one", &echo/1)]

    assert {:error, :invalid_agents} =
             Knotra.Swarm.start(instance, %Spec{mode: :debate, goal: "x", agents: agents})

    assert {:error, :missing_tasks} =
             Knotra.Swarm.start(instance, %Spec{
               mode: :board,
               goal: "x",
               agents: [agent("a", &echo/1)]
             })

    assert {:error, :invalid_mode} =
             Knotra.Swarm.start(instance, %Spec{
               mode: :nope,
               goal: "x",
               agents: [agent("a", &echo/1)]
             })

    assert {:error, :invalid_timeout} =
             Knotra.Swarm.start(instance, %Spec{
               mode: :debate,
               goal: "x",
               agents: [agent("a", &echo/1)],
               timeout: 0
             })

    assert {:error, :unknown_instance} =
             Knotra.Swarm.start(:missing_instance, %Spec{
               mode: :debate,
               goal: "x",
               agents: [agent("a", &echo/1)]
             })
  end

  # --- helpers ---------------------------------------------------------------

  defp agent(name, respond) do
    %Agent{name: name, definition: %Definition{version: "v1", model: {Model, respond: respond}}}
  end

  defp echo(request), do: {:ok, %Reply{text: "out:" <> request.input}}

  defp start_barrier(count) do
    spawn_link(fn ->
      wait(count, [])
    end)
  end

  defp wait(0, waiters) do
    Enum.each(waiters, &send(&1, :pass))
    wait(0, [])
  end

  defp wait(remaining, waiters) do
    receive do
      {:arrive, pid} -> wait(remaining - 1, [pid | waiters])
    end
  end

  defp collect_inputs(acc \\ []) do
    receive do
      {:model_input, input} -> collect_inputs([input | acc])
      {:model_start, _input, _pid} -> collect_inputs(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_no_executions(instance) do
    children = DynamicSupervisor.which_children({:via, Registry, {instance, :executions}})
    assert children == []
  end
end
