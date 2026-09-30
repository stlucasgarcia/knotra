defmodule Knotra.Execution do
  @moduledoc false
  use GenServer, restart: :temporary

  @defaults [max_turns: 8, max_tool_calls: 16, max_retries: 0, max_steps: 64, timeout: 30_000]

  @doc false
  def limits(opts), do: @defaults |> Keyword.merge(opts) |> Enum.sort()

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({tasks, definition, input, auth, opts}) do
    init({tasks, definition, input, auth, opts, nil})
  end

  def init({tasks, definition, input, auth, opts, durable}) do
    if valid_options?(definition, input, opts) do
      Process.flag(:trap_exit, true)
      limits = Map.new(limits(opts))
      started_at = System.monotonic_time(:millisecond)
      timer = Process.send_after(self(), :deadline, limits.timeout)

      state = %{
        tasks: tasks,
        definition: definition,
        input: input,
        auth: auth,
        limits: limits,
        id: System.unique_integer([:positive, :monotonic]),
        started_at: started_at,
        deadline_at: started_at + limits.timeout,
        status: :running,
        events: [],
        output: nil,
        error: nil,
        last: nil,
        loop_state: nil,
        exchanges: [],
        tool_definitions: [],
        counts: %{turns: 0, tools: 0, retries: 0, steps: 0},
        task: nil,
        stage: nil,
        timer: timer,
        observation_error: nil
      }

      {:ok, initialize(state, durable)}
    else
      {:stop, :invalid_configuration}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, public(state), state}

  def handle_call(:cancel, _from, %{status: :running} = state) do
    state = state |> stop_task() |> finish(:cancelled, :cancelled)
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call(:release, _from, %{status: :running} = state) do
    {:reply, {:error, :running}, state}
  end

  def handle_call(:release, _from, state) do
    {:via, Registry, {instance, :tasks}} = state.tasks
    {:reply, {:ok, {:via, Registry, {instance, :executions}}}, state}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    next = consume_in_time(result, %{state | task: nil})
    durable_result(next)
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    durable_result(consume_in_time({:plugin_error, :task_exit}, %{state | task: nil}))
  end

  def handle_info(:deadline, %{status: :running} = state) do
    {:noreply, state |> stop_task() |> finish(:failed, :deadline_exceeded)}
  end

  def handle_info(:observer_deadline, %{stage: :terminal_observation, task: %Task{}} = state) do
    durable_result(%{stop_task(state) | observation_error: :observer_timeout})
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_task(state)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, state} when is_map(state) -> {:state, Map.take(state, [:id, :status, :counts])}
      {:state, _} -> {:state, :redacted}
      {:log, _} -> {:log, []}
      {key, _} when key in [:message, :reason] -> {key, :redacted}
      entry -> entry
    end)
  end

  defp durable_result(%{durable: durable, status: status, task: nil} = state)
       when not is_nil(durable) and status != :running do
    {:stop, :normal, state}
  end

  defp durable_result(state) do
    {:noreply, state}
  end

  defp expired?(state) do
    System.monotonic_time(:millisecond) >= state.deadline_at
  end

  defp consume_in_time(result, %{status: :running} = state) do
    if expired?(state),
      do: finish(state, :failed, :deadline_exceeded),
      else: consume(result, state)
  end

  defp consume_in_time(result, state), do: consume(result, state)

  defp consume({:ok, :ok}, %{stage: :terminal_observation} = state) do
    Process.cancel_timer(state.timer)
    state
  end

  defp consume(_result, %{stage: :terminal_observation} = state) do
    Process.cancel_timer(state.timer)
    %{state | observation_error: :observer_failed}
  end

  defp consume({:plugin_error, reason}, state), do: finish(state, :failed, reason)

  defp consume({:ok, {:ok, tools, loop_state}}, %{stage: :setup} = state) do
    state
    |> Map.merge(%{tool_definitions: tools, loop_state: loop_state})
    |> event(:started, %{input: state.input})
    |> observe()
  end

  defp consume({:ok, :ok}, %{stage: :observation} = state), do: advance(state)

  defp consume({:ok, _}, %{stage: :observation} = state),
    do: finish(state, :failed, :observer_failed)

  defp consume({:ok, {:done, text}}, %{stage: :loop} = state) when is_binary(text) do
    if pending(state) == [],
      do: finish(state, :completed, text),
      else: finish(state, :failed, :pending_tools)
  end

  defp consume({:ok, {:model, next}}, %{stage: :loop} = state) do
    if pending(state) == [],
      do: operation(%{state | loop_state: next}, :model),
      else: finish(state, :failed, :pending_tools)
  end

  defp consume({:ok, {:tool, call, next}}, %{stage: :loop} = state) do
    if call in pending(state),
      do: operation(%{state | loop_state: next}, {:tool, call}),
      else: finish(state, :failed, :invalid_tool_request)
  end

  defp consume({:ok, {:ok, %Knotra.Reply{} = reply}}, %{stage: :model} = state) do
    if valid_reply?(reply, state) and
         (is_nil(state.durable) or length(reply.calls) == 1 or
            (state.counts.tools > 0 and reply.calls == [])) do
      visible = Map.take(reply, [:text, :calls, :usage])

      state
      |> Map.merge(%{
        exchanges: state.exchanges ++ [%{reply: reply, results: []}],
        last: {:model, visible}
      })
      |> event(:model_result, visible)
      |> observe()
    else
      finish(state, :failed, :invalid_model_reply)
    end
  end

  defp consume({:ok, {:ok, output}}, %{stage: {:tool, call}} = state) when is_binary(output) do
    exchanges =
      List.update_at(state.exchanges, -1, fn exchange ->
        %{exchange | results: exchange.results ++ [%{call: call, output: output}]}
      end)

    state =
      if state.durable,
        do:
          put_in(state.approval.operation, %{
            state.approval.operation
            | status: :succeeded,
              result: output
          }),
        else: state

    result = %{call: call, output: output}

    result =
      if state.durable,
        do: Map.put(result, :operation_id, state.approval.operation.id),
        else: result

    state
    |> Map.merge(%{exchanges: exchanges, last: {:tool, %{call: call, output: output}}})
    |> event(:tool_result, result)
    |> observe()
  end

  defp consume(
         {:ok, {:not_dispatched, reason}},
         %{stage: {:tool, _}, durable: durable, approval: %{operation: %{status: :dispatching}}} =
           state
       )
       when not is_nil(durable) and is_atom(reason) do
    state = put_in(state.approval.operation.status, :not_dispatched)
    finish(state, :failed, reason)
  end

  defp consume({:ok, {:retry, reason}}, %{stage: stage} = state)
       when is_atom(reason) and (stage == :model or elem(stage, 0) == :tool) do
    if state.durable && match?({:tool, _}, stage) do
      finish(state, :blocked, :uncertain_effect)
    else
      if state.counts.retries < state.limits.max_retries do
        state |> count(:retries) |> event(:retry, %{reason: reason}) |> operation(stage)
      else
        finish(state, :failed, :retries_exhausted)
      end
    end
  end

  defp consume({:ok, {:error, reason}}, state) when is_atom(reason),
    do: finish(state, :failed, reason)

  defp consume({:ok, {:ok, approval}}, %{stage: :approval} = state) when is_map(approval) do
    approval =
      Map.put(
        approval,
        :expires_at,
        System.system_time(:millisecond) + state.durable.response_timeout
      )

    finish(%{state | approval: approval}, :waiting, nil)
  end

  defp consume(_result, state) do
    finish(state, :failed, :invalid_plugin_result)
  end

  defp advance(state) do
    cond do
      expired?(state) ->
        finish(state, :failed, :deadline_exceeded)

      state.counts.steps >= state.limits.max_steps ->
        finish(state, :failed, :step_limit)

      true ->
        {module, _} = state.definition.loop
        view = %{input: state.input, last: state.last, counts: state.counts}
        launch(count(state, :steps), :loop, fn -> module.next(view, state.loop_state) end)
    end
  end

  defp operation(state, :model) do
    cond do
      expired?(state) ->
        finish(state, :failed, :deadline_exceeded)

      state.counts.turns >= state.limits.max_turns ->
        finish(state, :failed, :turn_limit)

      true ->
        {module, opts} = state.definition.model
        request = %{input: state.input, exchanges: state.exchanges, tools: state.tool_definitions}
        state = state |> count(:turns) |> event(:model_started, %{})
        launch(state, :model, fn -> module.call(request, opts) end)
    end
  end

  defp operation(%{durable: durable} = state, {:tool, call}) when not is_nil(durable) do
    cond do
      expired?(state) ->
        finish(state, :failed, :deadline_exceeded)

      state.counts.tools >= state.limits.max_tool_calls ->
        finish(state, :failed, :tool_limit)

      true ->
        launch(state, :approval, fn ->
          Knotra.Durable.approval(call, state.definition.tools, state.auth)
        end)
    end
  end

  defp operation(state, {:tool, call} = stage) do
    cond do
      expired?(state) ->
        finish(state, :failed, :deadline_exceeded)

      state.counts.tools >= state.limits.max_tool_calls ->
        finish(state, :failed, :tool_limit)

      true ->
        {module, opts} = state.definition.tool_runtime
        state = event(count(state, :tools), :tool_started, %{call: call})

        launch(state, stage, fn ->
          module.execute(call, state.definition.tools, state.auth, opts)
        end)
    end
  end

  defp observe(state) do
    {module, opts} = state.definition.observer
    snapshot = public(state)
    launch(state, :observation, fn -> module.record(snapshot, opts) end)
  end

  defp finish(state, status, value) do
    {status, value} =
      if status in [:failed, :cancelled] and
           match?(%{operation: %{status: :dispatching}}, state[:approval]),
         do: {:blocked, :uncertain_effect},
         else: {status, value}

    Process.cancel_timer(state.timer)

    state = %{
      state
      | status: status,
        output: if(status == :completed, do: value),
        error: if(status != :completed, do: value)
    }

    state = event(state, status, %{output: state.output, error: state.error})

    if state.durable do
      case Knotra.Durable.persist(%{state | stage: :terminal_observation}) do
        {:ok, recorded} -> notify_released(recorded, public(recorded))
        {:error, reason} -> block_durable(state, reason)
      end
    else
      state = observe(state)

      %{
        state
        | stage: :terminal_observation,
          timer: Process.send_after(self(), :observer_deadline, 1_000)
      }
    end
  end

  defp launch(state, stage, fun) do
    case Knotra.Durable.persist(%{state | stage: stage}) do
      {:ok, recorded} ->
        launch_task(recorded, stage, fun)

      {:error, reason} ->
        block_durable(state, reason)
    end
  end

  defp block_durable(state, reason) do
    Process.cancel_timer(state.timer)

    case Knotra.Durable.block_failed(state, reason) do
      {:ok, snapshot} -> notify_released(%{state | status: :blocked, error: reason}, snapshot)
      {:error, _} -> exit(:persistence_failed)
    end
  end

  defp notify_released(state, snapshot) do
    worker = self()
    supervisor = {:via, Registry, {state.durable.instance, :executions}}
    {observer, opts} = state.definition.observer
    tasks = state.tasks

    # This notifier is supervised independently of the finished worker. The
    # supervisor acknowledgment, not a worker DOWN signal, proves capacity is free.
    Task.Supervisor.start_child(tasks, fn ->
      try do
        DynamicSupervisor.terminate_child(supervisor, worker)

        notification =
          Task.Supervisor.async_nolink(tasks, fn ->
            try do
              observer.record(snapshot, opts)
            rescue
              _ -> :observer_failed
            catch
              _, _ -> :observer_failed
            end
          end)

        Task.yield(notification, 1_000) || Task.shutdown(notification, :brutal_kill)
      catch
        :exit, _ -> :ok
      end
    end)

    %{state | task: nil}
  end

  defp launch_task(state, stage, fun) do
    deadline =
      if state.status == :running do
        state.deadline_at
      end

    task =
      Task.Supervisor.async(state.tasks, fn ->
        try do
          if deadline != nil and System.monotonic_time(:millisecond) >= deadline do
            {:plugin_error, :deadline_exceeded}
          else
            {:ok, fun.()}
          end
        rescue
          _ -> {:plugin_error, :plugin_exception}
        catch
          _, _ -> {:plugin_error, :plugin_exit}
        end
      end)

    %{state | task: task, stage: stage}
  end

  defp stop_task(%{task: nil} = state), do: state

  defp stop_task(state) do
    Task.shutdown(state.task, :brutal_kill)
    %{state | task: nil}
  end

  defp event(state, type, data) do
    entry = %{
      sequence: length(state.events) + 1,
      elapsed_ms: System.monotonic_time(:millisecond) - state.started_at,
      type: type,
      data: data
    }

    %{state | events: [entry | state.events]}
  end

  defp count(state, key), do: update_in(state.counts[key], &(&1 + 1))

  @doc false
  def public(state) do
    snapshot = public_record(state)

    if state.durable do
      Map.put(snapshot, :approval, state.approval)
    else
      snapshot
    end
  end

  defp public_record(state) do
    %{
      id: state.id,
      definition_version: state.definition.version,
      status: state.status,
      output: state.output,
      error: state.error,
      counts: state.counts,
      events: Enum.reverse(state.events),
      observation_error: state.observation_error
    }
  end

  defp pending(%{exchanges: []}), do: []

  defp pending(state) do
    exchange = List.last(state.exchanges)
    completed = Enum.map(exchange.results, & &1.call.id)
    Enum.reject(exchange.reply.calls, &(&1.id in completed))
  end

  # length/1 is a guard BIF: improper tails fail the guard instead of raising.
  defp proper_list?(value) when is_list(value) and length(value) >= 0, do: true
  defp proper_list?(_), do: false

  defp valid_reply?(reply, state) do
    previous_ids = for exchange <- state.exchanges, call <- exchange.reply.calls, do: call.id

    is_binary(reply.text) and (is_nil(reply.usage) or is_map(reply.usage)) and
      proper_list?(reply.calls) and
      Enum.all?(reply.calls, fn
        %{id: id, name: name, arguments: args} ->
          is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(args)

        _ ->
          false
      end) and
      (
        ids = Enum.map(reply.calls, & &1.id)
        length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &(&1 not in previous_ids))
      )
  end

  defp initialize(state, durable) do
    state = Map.merge(state, %{durable: durable, approval: nil})

    state =
      if durable do
        case Registry.register(durable.instance, {:durable, durable.row.id}, nil) do
          {:ok, _} -> %{state | id: durable.row.id}
          {:error, _} -> exit(:already_running)
        end
      else
        state
      end

    if durable && durable[:resume] do
      restore(state)
    else
      launch(state, :setup, fn -> setup(state.definition, durable != nil) end)
    end
  end

  defp restore(state) do
    {:ok, saved} = Knotra.Checkpoint.decode(state.durable.row.checkpoint)
    {:ok, snapshot} = Knotra.Checkpoint.decode(state.durable.row.snapshot)
    {:ok, tools} = tool_definitions(state.definition, true)
    Process.cancel_timer(state.timer)
    now = System.monotonic_time(:millisecond)

    remaining =
      case saved.active_deadline_at do
        nil -> saved.remaining_ms
        deadline -> min(saved.remaining_ms, max(deadline - System.system_time(:millisecond), 0))
      end

    elapsed =
      case List.last(snapshot.events) do
        nil -> 0
        event -> event.elapsed_ms
      end

    state =
      state
      |> Map.merge(Map.take(saved, [:loop_state, :exchanges, :last, :counts, :limits, :approval]))
      |> Map.merge(%{
        events: Enum.reverse(snapshot.events),
        tool_definitions: tools,
        started_at: now - elapsed,
        deadline_at: now + remaining,
        timer: Process.send_after(self(), :deadline, remaining)
      })

    if state.approval.operation.status == :succeeded,
      do: advance(state),
      else: dispatch_approved(state)
  end

  defp dispatch_approved(state) do
    approval = state.approval
    call = Enum.find(pending(state), &(&1.id == approval.call_id and &1.name == approval.name))

    cond do
      call == nil ->
        finish(state, :blocked, :invalid_tool_request)

      expired?(state) ->
        finish(state, :failed, :deadline_exceeded)

      state.counts.tools >= state.limits.max_tool_calls ->
        finish(state, :failed, :tool_limit)

      true ->
        call = %{call | arguments: approval.arguments}

        state =
          put_in(state.approval.operation, %{
            state.approval.operation
            | status: :dispatching,
              admitted: true
          })

        state = state |> count(:tools) |> event(:tool_started, %{call: call})
        # Persist dispatch intent before entering the host boundary. The task uses
        # the resulting revision, never the pre-intent row.
        case Knotra.Durable.persist(%{state | stage: {:tool, call}}) do
          {:ok, recorded} ->
            launch_task(recorded, {:tool, call}, fn ->
              Knotra.Durable.dispatch(recorded, call)
            end)

          {:error, reason} ->
            block_durable(state, reason)
        end
    end
  end

  defp setup definition, durable do
    {loop, opts} = definition.loop

    with {:ok, tools} <- tool_definitions(definition, durable) do
      {:ok, tools, loop.init(opts)}
    end
  end

  @doc false
  def tool_definitions(definition, durable) do
    tools = Enum.map(definition.tools, & &1.definition())
    names = Enum.map(tools, & &1.name)

    if length(names) == length(Enum.uniq(names)) and
         Enum.all?(tools, fn tool ->
           match?(
             %{name: name, description: description, parameters: parameters, read_only: read_only}
             when is_binary(name) and name != "" and is_binary(description) and is_map(parameters) and
                    is_boolean(read_only),
             tool
           ) and (tool.read_only or durable)
         end) do
      {:ok, tools}
    else
      {:error, :invalid_tool_definitions}
    end
  end

  @doc false
  def valid_options?(definition, input, opts) do
    is_binary(input) and input != "" and is_binary(definition.version) and
      definition.version != "" and proper_list?(definition.tools) and
      Enum.all?(
        definition.tools,
        &implements?(&1, definition: 0, validate: 1, authorize: 2, call: 2)
      ) and plugin?(definition.loop, init: 1, next: 2) and plugin?(definition.model, call: 2) and
      plugin?(definition.tool_runtime, execute: 4) and plugin?(definition.observer, record: 2) and
      Keyword.keyword?(opts) and
      Enum.all?(opts, fn {key, value} ->
        Keyword.has_key?(@defaults, key) and is_integer(value) and value >= 0 and
          (key != :timeout or value > 0)
      end)
  end

  defp plugin?({module, _opts}, callbacks), do: implements?(module, callbacks)
  defp plugin?(_, _), do: false

  defp implements?(module, callbacks) do
    is_atom(module) and Code.ensure_loaded?(module) and
      Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
  end
end
