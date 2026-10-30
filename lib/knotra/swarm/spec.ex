defmodule Knotra.Swarm.Agent do
  @moduledoc """
  One swarm member: a name, the definition its executions use, and an optional
  initial prompt for display.

  The name is host-chosen, unique inside a swarm, and reported in results and
  board outcomes. The prompt is display metadata only; the definition's model
  options remain authoritative. The definition is unchanged except for the
  observer, which the swarm wraps so it can learn when the execution reaches a
  terminal status.
  """
  @enforce_keys [:name, :definition]
  defstruct [:name, :definition, :prompt]

  @type t :: %__MODULE__{
          name: String.t(),
          definition: Knotra.Definition.t(),
          prompt: String.t() | nil
        }
end

defmodule Knotra.Swarm.Spec do
  @moduledoc """
  What one swarm should do, for one of four coordination modes.

  `:fan_out` needs `:tasks` (or a `:decompose` function) and assigns each task to
  an agent round-robin, running up to `:max_concurrency` executions at a time.
  `:board` seeds one shared board with the same tasks; members claim tasks
  themselves until the board is empty. `:debate` gives every agent the goal and
  keeps the independently produced attempts for `:select`. `:coordinator` runs a
  host-supplied `:plan` function first; that function may return new agent
  definitions and tasks assigned by agent name.

  `:plan` receives `(goal, agents)` and returns
  `{:ok, %{agents: [Knotra.Swarm.Agent.t()], tasks: [task]}}` or `{:error, atom}`.
  It may add ephemeral agents up to `:max_created_agents` and tasks up to
  `:max_tasks`; each task may carry `:agent` and `:depth`. `:write_policy` is
  called by the swarm tool runtime for every declared write tool and returns
  `:approve`, `:reject`, or `{:escalate, reason}`.

  `:merge` receives `(goal, parts)` and returns `{:ok, binary} | {:error, atom}`;
  `:select` receives `(goal, attempts)` and returns `{:pick, id} | {:merge, binary}
  | {:error, atom}`. Both accept a 2-arity function, `{module, function}`, or
  `{module, function, extra_args}`. A part is
  `%{id: term, agent: binary, status: :completed | :failed, output: binary | nil,
  error: atom | nil}`.

  `:execution_opts` are the ordinary `Knotra.start/5` limits. `:timeout` bounds
  the whole swarm, not one execution; `:max_concurrency` bounds simultaneous
  executions and defaults to the number of agents.
  """
  @enforce_keys [:goal, :agents]
  defstruct mode: :fan_out,
            goal: nil,
            agents: [],
            tasks: [],
            decompose: nil,
            plan: nil,
            max_created_agents: 4,
            max_tasks: 64,
            max_depth: 2,
            write_policy: nil,
            merge: {Knotra.Swarm.Merges.Concat, :merge},
            select: {Knotra.Swarm.Selectors.Longest, :select},
            context: nil,
            execution_opts: [],
            max_concurrency: nil,
            timeout: 60_000

  @type mode :: :fan_out | :board | :debate | :coordinator
  @type task :: %{
          id: String.t(),
          input: String.t(),
          agent: String.t() | nil,
          depth: non_neg_integer()
        }

  @type t :: %__MODULE__{
          mode: mode(),
          goal: String.t(),
          agents: [Knotra.Swarm.Agent.t()],
          tasks: [task()],
          decompose:
            (String.t(), [Knotra.Swarm.Agent.t()] ->
               {:ok, [task()]} | {:error, atom()})
            | nil,
          plan:
            (String.t(), [Knotra.Swarm.Agent.t()] ->
               {:ok, %{agents: [Knotra.Swarm.Agent.t()], tasks: [task()]}}
               | {:error, atom()})
            | nil,
          max_created_agents: non_neg_integer(),
          max_tasks: non_neg_integer(),
          max_depth: non_neg_integer(),
          write_policy: term(),
          merge: term(),
          select: term(),
          context: term(),
          execution_opts: keyword(),
          max_concurrency: pos_integer() | nil,
          timeout: pos_integer()
        }

  @modes [:fan_out, :board, :debate, :coordinator]

  @doc "Checks a spec before any process starts; returns a stable atom on error."
  @spec validate(t()) :: :ok | {:error, atom()}
  def validate(%__MODULE__{} = spec) do
    with :ok <- validate_mode(spec.mode),
         :ok <- validate_goal(spec.goal),
         :ok <- validate_agents(spec.agents),
         :ok <- validate_tasks_field(spec),
         :ok <- validate_timeout(spec.timeout),
         :ok <- validate_concurrency(spec.max_concurrency),
         :ok <- validate_plan(spec.plan, spec.mode),
         :ok <- validate_caps(spec),
         :ok <- validate_write_policy(spec.write_policy),
         :ok <- validate_options(spec.execution_opts) do
      validate_tasks_shape(spec.tasks)
    end
  end

  def validate(_), do: {:error, :invalid_spec}

  @doc false
  def tasks(%__MODULE__{tasks: [_ | _] = tasks}), do: validate_task_list(tasks)

  def tasks(%__MODULE__{tasks: [], decompose: fun, goal: goal, agents: agents})
      when is_function(fun, 2) do
    case fun.(goal, agents) do
      {:ok, tasks} -> validate_task_list(tasks)
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_tasks}
    end
  rescue
    _ -> {:error, :invalid_tasks}
  catch
    _, _ -> {:error, :invalid_tasks}
  end

  def tasks(%__MODULE__{}), do: {:error, :missing_tasks}

  defp validate_mode(mode) when mode in @modes, do: :ok
  defp validate_mode(_), do: {:error, :invalid_mode}

  defp validate_goal(goal) when is_binary(goal) and goal != "", do: :ok
  defp validate_goal(_), do: {:error, :invalid_goal}

  defp validate_agents([_ | _] = agents) do
    names = Enum.map(agents, & &1.name)

    if Enum.all?(
         agents,
         &match?(
           %Knotra.Swarm.Agent{name: name, definition: %Knotra.Definition{}}
           when is_binary(name) and name != "",
           &1
         )
       ) and
         length(names) == length(Enum.uniq(names)),
       do: :ok,
       else: {:error, :invalid_agents}
  end

  defp validate_agents(_), do: {:error, :invalid_agents}

  defp validate_tasks_field(%{mode: :debate}), do: :ok
  defp validate_tasks_field(%{tasks: [_ | _]}), do: :ok
  defp validate_tasks_field(%{plan: fun}) when is_function(fun, 2), do: :ok
  defp validate_tasks_field(%{decompose: fun}) when is_function(fun, 2), do: :ok
  defp validate_tasks_field(_), do: {:error, :missing_tasks}

  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp validate_concurrency(nil), do: :ok
  defp validate_concurrency(n) when is_integer(n) and n > 0, do: :ok
  defp validate_concurrency(_), do: {:error, :invalid_concurrency}

  defp validate_plan(nil, _mode), do: :ok

  defp validate_plan(fun, mode)
       when is_function(fun, 2) and mode in [:coordinator, :board],
       do: :ok

  defp validate_plan(_, _), do: {:error, :invalid_plan}

  defp validate_caps(%{max_created_agents: created, max_tasks: tasks, max_depth: depth})
       when is_integer(created) and created >= 0 and is_integer(tasks) and tasks >= 0 and
              is_integer(depth) and depth >= 0,
       do: :ok

  defp validate_caps(_), do: {:error, :invalid_caps}

  defp validate_write_policy(nil), do: :ok
  defp validate_write_policy(fun) when is_function(fun, 2) or is_function(fun, 3), do: :ok

  defp validate_write_policy({module, function}) when is_atom(module) and is_atom(function),
    do: :ok

  defp validate_write_policy(_), do: {:error, :invalid_write_policy}

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: :ok, else: {:error, :invalid_execution_options}
  end

  defp validate_options(_), do: {:error, :invalid_execution_options}

  defp validate_tasks_shape(tasks) when is_list(tasks), do: :ok
  defp validate_tasks_shape(_), do: {:error, :invalid_tasks}

  defp validate_task_list(tasks) when is_list(tasks) and tasks != [] do
    valid? =
      Enum.all?(tasks, fn
        %{id: id, input: input}
        when is_binary(id) and id != "" and is_binary(input) and input != "" ->
          true

        _ ->
          false
      end)

    ids = Enum.map(tasks, & &1.id)

    if valid? and length(ids) == length(Enum.uniq(ids)),
      do: {:ok, tasks},
      else: {:error, :invalid_tasks}
  end

  defp validate_task_list(_), do: {:error, :invalid_tasks}
end
