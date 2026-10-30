defmodule Knotra.Swarm do
  @moduledoc """
  A coordinated group of executions pursuing one objective under one deadline.

  All modes reuse the ordinary non-durable execution path: each agent is a
  `Knotra.Execution` GenServer started through the instance's `DynamicSupervisor`,
  so agents cost BEAM processes, not OS threads, and the instance's
  `:max_executions` capacity bounds the whole swarm. A swarm adds one coordinator
  process and, for `:board`, one member process per agent.

  * `:fan_out` resolves tasks (given, or from `:decompose`) and runs one execution
    per task, assigning agents round-robin and admitting at most
    `:max_concurrency` at a time.
  * `:board` seeds one shared ETS board; members claim pending tasks themselves
    and run one execution per claim until nothing is left. The coordinator never
    assigns work.
  * `:debate` gives every agent the same goal and keeps the attempts for `:select`.
  * `:coordinator` calls a host `:plan` function that may synthesize ephemeral
    agents and assign tasks to them by name, then runs those tasks concurrently.

  Terminal execution snapshots are relayed by `Knotra.Swarm.Observer`, which also
  forwards to the definition's own observer. Abandoned children are released, so
  capacity is returned as soon as a task finishes.

  Nothing is persisted: the board, ownership and results live in memory, and a
  host restart loses the swarm. Durable swarm acceptance remains planned.
  """

  use GenServer

  alias Knotra.Swarm.{Board, Member, Observer, Result, Spec}

  @retry_ms 10

  @doc """
  Starts the coordinator without linking it to the caller.

  Validation and task resolution happen before the coordinator accepts work, so a
  bad spec returns an error instead of a later crash.
  """
  @spec start(GenServer.server(), Spec.t()) :: {:ok, pid()} | {:error, atom()}
  def start(instance, %Spec{} = spec) do
    with :ok <- Spec.validate(spec),
         :ok <- instance_available(instance) do
      GenServer.start(__MODULE__, {instance, spec})
    end
  end

  @doc "Starts a swarm and waits for its outcome."
  @spec run(GenServer.server(), Spec.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def run(instance, %Spec{} = spec, opts \\ []) do
    case start(instance, spec) do
      {:ok, swarm} -> await(swarm, Keyword.get(opts, :await_timeout, :infinity))
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Waits for the swarm outcome.

  Returns `{:ok, result}` only when every required part completed. A partially
  failed swarm returns `{:error, {:incomplete, result}}` after the healthy work
  finishes, `{:error, :timeout}` when the swarm deadline fires, and
  `{:error, :cancelled}` after `cancel/1`.
  """
  @spec await(GenServer.server(), timeout()) :: {:ok, Result.t()} | {:error, term()}
  def await(swarm, timeout \\ :infinity) do
    GenServer.call(swarm, :await, timeout)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Current progress: queue depth, running executions, members and counters."
  @spec snapshot(GenServer.server()) :: map() | {:error, :not_found}
  def snapshot(swarm) do
    GenServer.call(swarm, :snapshot)
  catch
    :exit, _ -> {:error, :not_found}
  end

  @doc "Stops admitting work, cancels running executions and waits nothing."
  @spec cancel(GenServer.server()) :: :ok | {:error, :not_found}
  def cancel(swarm) do
    GenServer.call(swarm, :cancel)
  catch
    :exit, _ -> {:error, :not_found}
  end

  # --- Coordinator ------------------------------------------------------------

  @impl true
  def init({instance, spec}) do
    started_at = System.monotonic_time(:millisecond)

    state = %{
      instance: instance,
      spec: spec,
      swarm_id: new_id(),
      started_at: started_at,
      deadline_at: started_at + spec.timeout,
      status: :running,
      tasks: [],
      board: nil,
      members: %{},
      queue: [],
      running: %{},
      results: %{},
      escalations: [],
      created_agents: [],
      children: MapSet.new(),
      result: nil,
      waiters: [],
      counts: %{started: 0, completed: 0, failed: 0},
      retry_timer: nil,
      deadline_timer: Process.send_after(self(), :deadline, spec.timeout)
    }

    Knotra.Observability.swarm_event(instance, state.swarm_id, :started, %{
      mode: spec.mode,
      goal: spec.goal,
      config: %{
        timeout: spec.timeout,
        max_concurrency: spec.max_concurrency,
        max_created_agents: spec.max_created_agents,
        max_tasks: spec.max_tasks,
        max_depth: spec.max_depth
      },
      agents: agent_details(spec.agents, [])
    })

    case prepare(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        Process.cancel_timer(state.deadline_timer)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:await, from, state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, progress(state), state}
  end

  def handle_call(:cancel, _from, state) do
    {:stop, :normal, :ok, halt(state, :cancelled)}
  end

  def handle_call({:escalation, escalation}, _from, state) do
    Knotra.Observability.swarm_event(state.instance, state.swarm_id, :escalation, escalation)
    {:reply, :ok, %{state | escalations: [escalation | state.escalations]}}
  end

  @impl true
  def handle_info({:knotra_swarm_child, tag, snapshot}, state) do
    step(state, {:child, tag, snapshot})
  end

  def handle_info({:knotra_swarm_member_done, pid}, state) do
    step(state, {:member_done, pid})
  end

  def handle_info({:knotra_swarm_child_started, pid}, state) do
    step(state, {:child_started, pid})
  end

  def handle_info({:knotra_swarm_child_finished, pid}, state) do
    step(state, {:child_finished, pid})
  end

  def handle_info({:DOWN, _reference, :process, pid, reason}, state) do
    step(state, {:down, pid, reason})
  end

  def handle_info(:retry, state) do
    step(state, :retry)
  end

  def handle_info(:deadline, state) do
    {:stop, :normal, halt(state, :timeout)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_children(state)
    if state.board, do: Board.close(state.board)
    :ok
  end

  # --- Preparation ------------------------------------------------------------

  defp prepare(%{spec: %{mode: :debate}} = state) do
    {:ok, admit(%{state | queue: debate_jobs(state.spec)})}
  end

  defp prepare(%{spec: %{mode: :fan_out}} = state) do
    with {:ok, state} <- maybe_plan(state),
         {:ok, tasks} <- resolve_tasks(state.spec) do
      {:ok, admit(%{state | tasks: tasks, queue: fan_out_jobs(state.spec, tasks)})}
    end
  end

  defp prepare(%{spec: %{mode: :board}} = state) do
    with {:ok, state} <- maybe_plan(state),
         {:ok, tasks} <- resolve_tasks(state.spec) do
      board = Board.new()
      Board.seed(board, tasks)
      start_members(%{state | tasks: tasks, board: board})
    end
  end

  defp prepare(%{spec: %{mode: :coordinator}} = state) do
    with {:ok, state} <- maybe_plan(state),
         {:ok, tasks} <- resolve_tasks(state.spec),
         {:ok, jobs} <- coordinator_jobs(state.spec, tasks) do
      {:ok, admit(%{state | tasks: tasks, queue: jobs})}
    end
  end

  # A host planner may add ephemeral agents and tasks before admission. All of
  # it is validated against explicit caps before any execution starts.
  defp maybe_plan(%{spec: %{plan: nil}} = state), do: {:ok, state}

  defp maybe_plan(%{spec: %{plan: fun}} = state) when is_function(fun, 2) do
    case call_plan(fun, state.spec.goal, state.spec.agents) do
      {:ok, plan} -> apply_plan(state, plan)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_plan(_state), do: {:error, :invalid_plan}

  defp call_plan(fun, goal, agents) do
    case fun.(goal, agents) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_plan}
    end
  rescue
    _ -> {:error, :plan_failed}
  catch
    _, _ -> {:error, :plan_failed}
  end

  defp apply_plan(state, plan) when is_map(plan) do
    created = Map.get(plan, :agents, [])
    tasks = Map.get(plan, :tasks, [])

    with true <- is_list(created) and is_list(tasks),
         {:ok, agents} <- merge_plan_agents(created, state.spec),
         :ok <- validate_agent_definitions(created, state),
         {:ok, tasks} <- validate_plan_tasks(tasks, agents, state.spec) do
      new_state = %{
        state
        | spec: %{state.spec | agents: agents, tasks: tasks},
          created_agents: Enum.map(created, & &1.name)
      }

      Knotra.Observability.swarm_event(state.instance, state.swarm_id, :planned, %{
        planner: Map.get(plan, :trace),
        agents: agent_details(agents, new_state.created_agents),
        tasks:
          Enum.map(tasks, fn task ->
            %{
              id: task.id,
              agent: task.agent,
              iteration: task.depth + 1,
              input: task.input
            }
          end)
      })

      {:ok, new_state}
    else
      false -> {:error, :invalid_plan}
      {:error, _reason} = error -> error
    end
  end

  defp apply_plan(_state, _plan), do: {:error, :invalid_plan}

  defp merge_plan_agents([], spec), do: {:ok, spec.agents}

  defp merge_plan_agents(created, spec) do
    valid? =
      Enum.all?(created, fn
        %Knotra.Swarm.Agent{name: name, definition: %Knotra.Definition{}}
        when is_binary(name) and name != "" ->
          true

        _ ->
          false
      end)

    names = Enum.map(spec.agents ++ created, & &1.name)

    cond do
      not valid? -> {:error, :invalid_plan_agents}
      length(created) > spec.max_created_agents -> {:error, :plan_agent_limit}
      length(names) != length(Enum.uniq(names)) -> {:error, :duplicate_agent_name}
      true -> {:ok, spec.agents ++ created}
    end
  end

  defp validate_agent_definitions(agents, state) do
    Enum.reduce_while(agents, :ok, fn agent, :ok ->
      definition =
        with_swarm_runtime(agent.definition, state, %{agent: agent.name, id: "plan"})

      case Knotra.Execution.validate(definition, "plan", []) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_plan_tasks(tasks, agents, spec) do
    names = MapSet.new(Enum.map(agents, & &1.name))

    cond do
      length(tasks) > spec.max_tasks ->
        {:error, :plan_task_limit}

      true ->
        tasks
        |> Enum.reduce_while([], fn task, acc ->
          case normalize_plan_task(task, names, spec) do
            {:ok, task} -> {:cont, [task | acc]}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:error, _reason} = error ->
            error

          tasks ->
            ids = Enum.map(tasks, & &1.id)

            if length(ids) == length(Enum.uniq(ids)),
              do: {:ok, Enum.reverse(tasks)},
              else: {:error, :duplicate_task_id}
        end
    end
  end

  defp normalize_plan_task(%{id: id, input: input} = task, names, spec)
       when is_binary(id) and id != "" and is_binary(input) and input != "" do
    agent = Map.get(task, :agent)
    depth = Map.get(task, :depth, 0)

    cond do
      not is_integer(depth) or depth < 0 or depth > spec.max_depth ->
        {:error, :task_depth_exceeded}

      agent != nil and not MapSet.member?(names, agent) ->
        {:error, :unknown_agent}

      spec.mode == :coordinator and agent == nil ->
        {:error, :missing_task_agent}

      true ->
        {:ok, %{id: id, input: input, agent: agent, depth: depth}}
    end
  end

  defp normalize_plan_task(_task, _names, _spec), do: {:error, :invalid_tasks}

  defp resolve_tasks(spec) do
    case Spec.tasks(spec) do
      {:ok, tasks} ->
        {:ok,
         Enum.map(tasks, fn task ->
           %{
             id: task.id,
             input: task.input,
             agent: Map.get(task, :agent),
             depth: Map.get(task, :depth, 0)
           }
         end)}

      {:error, _reason} = error ->
        error
    end
  end

  defp debate_jobs(spec) do
    spec.agents
    |> Enum.with_index()
    |> Enum.map(fn {agent, index} ->
      job(index, index, agent, spec.goal)
    end)
  end

  defp fan_out_jobs(spec, tasks) do
    agents = spec.agents
    count = length(agents)

    tasks
    |> Enum.with_index()
    |> Enum.map(fn {task, index} ->
      job(index, task.id, Enum.at(agents, rem(index, count)), task.input)
    end)
  end

  defp coordinator_jobs(spec, tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {task, index}, {:ok, acc} ->
      case Enum.find(spec.agents, &(&1.name == task.agent)) do
        nil ->
          {:halt, {:error, :unknown_agent}}

        agent ->
          job = job(index, task.id, agent, task.input) |> Map.put(:depth, task.depth)
          {:cont, {:ok, [job | acc]}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  defp job(index, id, agent, input) do
    %{
      index: index,
      id: id,
      tag: make_ref(),
      agent: agent.name,
      definition: agent.definition,
      depth: 0
    }
    |> Map.put(:input, input)
  end

  defp start_members(state) do
    supervisor = {:via, Registry, {state.instance, :tasks}}
    limit = min(length(state.spec.agents), concurrency(state))
    start_members(Enum.take(state.spec.agents, limit), supervisor, state)
  end

  defp start_members([], _supervisor, state), do: {:ok, state}

  defp start_members([agent | rest], supervisor, state) do
    args = %{
      instance: state.instance,
      board: state.board,
      swarm_id: state.swarm_id,
      mode: state.spec.mode,
      agent: agent,
      task_ids: Enum.map(state.tasks, & &1.id),
      context: state.spec.context,
      execution_opts: state.spec.execution_opts,
      deadline_at: state.deadline_at,
      coordinator: self()
    }

    case Task.Supervisor.start_child(supervisor, fn -> Member.run(args) end) do
      {:ok, pid} ->
        Process.monitor(pid)

        start_members(rest, supervisor, %{
          state
          | members: Map.put(state.members, pid, agent.name)
        })

      {:error, reason} when map_size(state.members) == 0 ->
        {:error, reason}

      {:error, _reason} ->
        # The remaining members still drain the board; tasks nobody claims finish
        # as `:unassigned` rather than being reported complete.
        {:ok, state}
    end
  end

  # --- Admission --------------------------------------------------------------

  defp admit(%{status: :running} = state) do
    fill(state, concurrency(state) - map_size(state.running))
  end

  defp concurrency(%{spec: spec}) do
    min(spec.max_concurrency || length(spec.agents), max(length(spec.agents), 1))
  end

  defp fill(state, available) when available <= 0, do: state
  defp fill(%{queue: []} = state, _available), do: state

  defp fill(state, available) do
    [job | rest] = state.queue

    case launch(%{state | queue: rest}, job) do
      {:ok, state} ->
        fill(state, available - 1)

      {:retry, state} ->
        # Instance capacity is occupied by other work; keep the job queued and ask
        # again shortly instead of failing it or spinning.
        schedule_retry(%{state | queue: [job | rest]})

      {:failed, state} ->
        fill(state, available - 1)
    end
  end

  defp launch(state, job) do
    definition =
      job.definition
      |> with_observer(job.tag)
      |> with_swarm_runtime(state, job)

    opts = Keyword.put(state.spec.execution_opts, :trace, child_trace(state, job))

    Knotra.Observability.swarm_event(state.instance, state.swarm_id, :task_started, %{
      id: job.id,
      agent: job.agent,
      iteration: Map.get(job, :depth, 0) + 1,
      input: job.input
    })

    case Knotra.start(state.instance, definition, job.input, state.spec.context, opts) do
      {:ok, pid} ->
        Process.monitor(pid)

        running =
          Map.put(state.running, job.tag, %{job: job, pid: pid, started_at: now()})

        {:ok,
         %{
           state
           | running: running,
             children: MapSet.put(state.children, pid),
             counts: Map.update!(state.counts, :started, &(&1 + 1))
         }}

      {:error, :max_children} ->
        {:retry, state}

      {:error, reason} ->
        {:failed, record(state, job, :failed, nil, reason)}
    end
  end

  defp with_observer(definition, tag) do
    %{
      definition
      | observer: {Observer, %{notify: self(), tag: tag, delegate: definition.observer}}
    }
  end

  # Coordinator runs always get the write-capable boundary. Other modes keep
  # their configured runtime unless the host explicitly opts into a write policy.
  defp with_swarm_runtime(definition, %{spec: %{mode: :coordinator}} = state, job) do
    attach_swarm_runtime(definition, state, job)
  end

  defp with_swarm_runtime(definition, %{spec: %{write_policy: nil}}, _job),
    do: definition

  defp with_swarm_runtime(definition, state, job) do
    attach_swarm_runtime(definition, state, job)
  end

  defp attach_swarm_runtime(definition, state, job) do
    opts = [
      coordinator: self(),
      policy: state.spec.write_policy,
      delegate: definition.tool_runtime,
      agent: job.agent,
      task: job.id,
      swarm_id: state.swarm_id
    ]

    %{definition | tool_runtime: {Knotra.Swarm.ToolRuntime, opts}}
  end

  # Every child execution is tagged for the host's observability store: one
  # conversation per swarm, the agent name, and the part/mode as labels. Without
  # this a non-durable child shows up as an anonymous integer-id execution.
  defp child_trace(state, job) do
    child_trace(state.swarm_id, state.spec.mode, job.agent, job.id)
  end

  defp child_trace(swarm_id, mode, agent, part) do
    %{
      agent: agent,
      conversation_id: swarm_id,
      labels: %{"mode" => mode_label(mode), "part" => to_string(part)}
    }
  end

  defp mode_label(:fan_out), do: "fanout"
  defp mode_label(mode), do: Atom.to_string(mode)

  defp new_id do
    "swarm-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp schedule_retry(%{retry_timer: nil} = state) do
    %{state | retry_timer: Process.send_after(self(), :retry, @retry_ms)}
  end

  defp schedule_retry(state), do: state

  # --- Progress ---------------------------------------------------------------

  defp step(state, event) do
    state = reduce(state, event)

    if done?(state) do
      {:stop, :normal, finish(state)}
    else
      {:noreply, state}
    end
  end

  defp reduce(state, {:child, tag, snapshot}) do
    case Map.pop(state.running, tag) do
      {nil, _running} ->
        # A release already accounted for this execution.
        state

      {%{job: job, pid: pid, started_at: started_at}, running} ->
        release(pid)

        state = %{
          state
          | running: running,
            children: MapSet.delete(state.children, pid)
        }

        extra = %{elapsed_ms: now() - started_at, counts: snapshot[:counts]}

        state =
          case snapshot do
            %{status: :completed, output: output} ->
              record(state, job, :completed, output, nil, extra)

            %{status: :cancelled} ->
              record(state, job, :failed, nil, :cancelled, extra)

            %{error: error} when is_atom(error) ->
              record(state, job, :failed, nil, error, extra)

            _other ->
              record(state, job, :failed, nil, :execution_failed, extra)
          end

        admit(state)
    end
  end

  defp reduce(state, {:member_done, pid}) do
    %{state | members: Map.delete(state.members, pid)}
  end

  defp reduce(state, {:down, pid, reason}) do
    cond do
      Map.has_key?(state.members, pid) ->
        %{state | members: Map.delete(state.members, pid)}

      true ->
        case Enum.find(state.running, fn {_tag, running} -> running.pid == pid end) do
          nil ->
            state

          {tag, %{job: job, started_at: started_at}} ->
            state = %{
              state
              | running: Map.delete(state.running, tag),
                children: MapSet.delete(state.children, pid)
            }

            entry =
              record(state, job, :failed, nil, exit_reason(reason), %{
                elapsed_ms: now() - started_at
              })

            admit(entry)
        end
    end
  end

  defp reduce(state, {:child_started, pid}) do
    %{state | children: MapSet.put(state.children, pid)}
  end

  defp reduce(state, {:child_finished, pid}) do
    %{state | children: MapSet.delete(state.children, pid)}
  end

  defp reduce(state, :retry) do
    admit(%{state | retry_timer: nil})
  end

  defp exit_reason(:normal), do: :execution_exited
  defp exit_reason(:killed), do: :execution_killed
  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason(_reason), do: :execution_exited

  defp record(state, job, status, output, error, extra \\ %{}) do
    Knotra.Observability.swarm_event(state.instance, state.swarm_id, :task_finished, %{
      id: job.id,
      agent: job.agent,
      iteration: Map.get(job, :depth, 0) + 1,
      status: status,
      error: error,
      elapsed_ms: Map.get(extra, :elapsed_ms),
      counts: Map.get(extra, :counts)
    })

    entry = %{
      job: job,
      status: status,
      output: output,
      error: error,
      elapsed_ms: Map.get(extra, :elapsed_ms),
      counts: Map.get(extra, :counts)
    }

    counter = if status == :completed, do: :completed, else: :failed

    %{
      state
      | results: Map.put(state.results, job.tag, entry),
        counts: Map.update!(state.counts, counter, &(&1 + 1))
    }
  end

  defp done?(%{status: :running} = state) do
    state.queue == [] and map_size(state.running) == 0 and
      case state.spec.mode do
        :board -> map_size(state.members) == 0
        _mode -> true
      end
  end

  defp done?(_state), do: true

  # --- Completion -------------------------------------------------------------

  defp finish(state) do
    cancel_timers(state)
    result = assemble(state)

    Knotra.Observability.swarm_event(state.instance, state.swarm_id, :finished, %{
      status: result.status,
      output: result.output,
      error: result.error,
      elapsed_ms: result.elapsed_ms,
      counts: state.counts,
      escalations: result.escalations
    })

    reply_waiters(state.waiters, outcome(result))
    if state.board, do: Board.close(state.board)

    %{state | status: :finished, result: result, waiters: [], board: nil}
  end

  defp outcome(%Result{status: :completed} = result), do: {:ok, result}
  defp outcome(result), do: {:error, {:incomplete, result}}

  defp halt(state, reason) do
    state = cancel_children(state)
    cancel_timers(state)

    Knotra.Observability.swarm_event(state.instance, state.swarm_id, :finished, %{
      status: if(reason == :timeout, do: :timeout, else: :cancelled),
      output: nil,
      error: reason,
      elapsed_ms: elapsed(state),
      counts: state.counts,
      escalations: Enum.reverse(state.escalations)
    })

    reply_waiters(state.waiters, {:error, reason})
    if state.board, do: Board.close(state.board)

    %{state | status: :halted, board: nil, waiters: []}
  end

  defp cancel_children(state) do
    Enum.each(state.children, fn pid ->
      Knotra.cancel(pid)
      release(pid)
    end)

    Enum.each(state.members, fn {pid, _name} -> Process.exit(pid, :kill) end)
    %{state | running: %{}, members: %{}, children: MapSet.new()}
  end

  defp cancel_timers(state) do
    Process.cancel_timer(state.deadline_timer)
    if state.retry_timer, do: Process.cancel_timer(state.retry_timer)
    :ok
  end

  defp reply_waiters(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp release(pid) do
    Knotra.release(pid)
  catch
    :exit, _ -> :ok
  end

  # --- Result assembly --------------------------------------------------------

  defp assemble(state) do
    case state.spec.mode do
      :debate -> assemble_debate(state)
      _mode -> assemble_tasks(state)
    end
  end

  defp assemble_tasks(state) do
    parts = parts(state)

    base = %Result{
      mode: state.spec.mode,
      goal: state.spec.goal,
      swarm_id: state.swarm_id,
      agents: Enum.map(state.spec.agents, & &1.name),
      created_agents: state.created_agents,
      agent_details: agent_details(state),
      tasks: parts,
      escalations: Enum.reverse(state.escalations),
      elapsed_ms: elapsed(state)
    }

    case merge(state.spec.merge, state.spec.goal, parts) do
      {:ok, output} ->
        %{base | status: parts_status(parts), output: output}

      {:error, reason} ->
        %{base | status: :failed, error: reason}
    end
  end

  defp assemble_debate(state) do
    parts = parts(state)

    base = %Result{
      mode: :debate,
      goal: state.spec.goal,
      swarm_id: state.swarm_id,
      agents: Enum.map(state.spec.agents, & &1.name),
      created_agents: state.created_agents,
      agent_details: agent_details(state),
      tasks: parts,
      escalations: Enum.reverse(state.escalations),
      elapsed_ms: elapsed(state)
    }

    case select(state.spec.select, state.spec.goal, parts) do
      {:pick, id} ->
        case Enum.find(parts, &(&1.id == id and &1.status == :completed)) do
          nil -> %{base | status: :failed, error: :invalid_selection}
          attempt -> %{base | status: :completed, output: attempt.output, selected: id}
        end

      {:merge, output} when is_binary(output) and output != "" ->
        %{base | status: :completed, output: output}

      {:error, reason} when is_atom(reason) ->
        %{base | status: :failed, error: reason}

      _other ->
        %{base | status: :failed, error: :invalid_selection}
    end
  end

  defp parts(%{spec: %{mode: :board}} = state) do
    outcomes = Map.new(Board.outcomes(state.board), &{&1.id, &1})

    Enum.map(state.tasks, fn task ->
      case Map.get(outcomes, task.id) do
        nil ->
          %{
            id: task.id,
            agent: nil,
            iteration: 1,
            status: :failed,
            output: nil,
            error: :unassigned,
            elapsed_ms: nil,
            counts: nil
          }

        outcome ->
          %{
            id: task.id,
            agent: outcome.agent,
            iteration: 1,
            status: outcome.status,
            output: outcome.output,
            error: outcome.error,
            elapsed_ms: outcome.elapsed_ms,
            counts: outcome.counts
          }
      end
    end)
  end

  defp parts(state) do
    state.results
    |> Enum.sort_by(fn {_tag, entry} -> entry.job.index end)
    |> Enum.map(fn {_tag, entry} ->
      %{
        id: entry.job.id,
        agent: entry.job.agent,
        iteration: Map.get(entry.job, :depth, 0) + 1,
        status: entry.status,
        output: entry.output,
        error: entry.error,
        elapsed_ms: entry.elapsed_ms,
        counts: entry.counts
      }
    end)
  end

  defp agent_details(state), do: agent_details(state.spec.agents, state.created_agents)

  defp agent_details(agents, created_names) do
    created = MapSet.new(created_names)

    Enum.map(agents, fn agent ->
      %{
        name: agent.name,
        prompt: Map.get(agent, :prompt),
        tools: Enum.map(agent.definition.tools, & &1.definition().name),
        version: agent.definition.version,
        created: MapSet.member?(created, agent.name)
      }
    end)
  end

  defp parts_status(parts) do
    completed = Enum.count(parts, &(&1.status == :completed))

    cond do
      completed == length(parts) -> :completed
      completed == 0 -> :failed
      true -> :partial
    end
  end

  defp merge(plugin, goal, parts) do
    case apply_plugin(plugin, [goal, parts]) do
      {:ok, output} when is_binary(output) -> {:ok, output}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_merge_result}
    end
  rescue
    _ -> {:error, :merge_failed}
  catch
    _, _ -> {:error, :merge_failed}
  end

  defp select(plugin, goal, parts) do
    case apply_plugin(plugin, [goal, parts]) do
      {:pick, id} -> {:pick, id}
      {:merge, output} when is_binary(output) -> {:merge, output}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_selection}
    end
  rescue
    _ -> {:error, :select_failed}
  catch
    _, _ -> {:error, :select_failed}
  end

  defp apply_plugin(fun, args) when is_function(fun, 2), do: apply(fun, args)

  defp apply_plugin({module, function}, args) when is_atom(module) and is_atom(function),
    do: apply(module, function, args)

  defp apply_plugin({module, function, extra}, args)
       when is_atom(module) and is_atom(function) and is_list(extra),
       do: apply(module, function, args ++ extra)

  defp apply_plugin(_plugin, _args), do: {:error, :invalid_plugin}

  # --- Introspection ----------------------------------------------------------

  defp progress(state) do
    %{
      id: state.swarm_id,
      mode: state.spec.mode,
      goal: state.spec.goal,
      status: state.status,
      agents: length(state.spec.agents),
      tasks: length(state.tasks),
      queue: length(state.queue),
      running: map_size(state.running),
      members: map_size(state.members),
      counts: state.counts,
      escalations: length(state.escalations),
      elapsed_ms: elapsed(state)
    }
  end

  defp elapsed(state), do: System.monotonic_time(:millisecond) - state.started_at

  defp instance_available(instance) when is_atom(instance) do
    case Registry.lookup(instance, :tasks) do
      [{_pid, _value}] -> :ok
      _other -> {:error, :unknown_instance}
    end
  rescue
    ArgumentError -> {:error, :unknown_instance}
  end

  defp instance_available(_instance), do: {:error, :unknown_instance}
end
