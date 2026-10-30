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
    {trace, opts} = Keyword.pop(opts, :trace)

    if valid_options?(definition, input, opts) do
      Process.flag(:trap_exit, true)
      limits = Map.new(limits(opts))
      started_at = System.monotonic_time(:millisecond)
      started_at_system = System.system_time(:millisecond)
      timer = Process.send_after(self(), :deadline, limits.timeout)

      state = %{
        tasks: tasks,
        instance: instance_name(tasks),
        definition: definition,
        definition_meta: Knotra.Observability.describe_definition(definition),
        trace: trace || Knotra.Observability.empty_trace(),
        input: input,
        auth: auth,
        limits: limits,
        id: execution_id(durable),
        started_at: started_at,
        started_at_system: started_at_system,
        deadline_at: started_at + limits.timeout,
        status: :running,
        events: [],
        next_sequence: 0,
        output: nil,
        error: nil,
        last: nil,
        loop_state: nil,
        exchanges: [],
        tool_definitions: [],
        prepared_tools: nil,
        counts: %{turns: 0, tools: 0, retries: 0, steps: 0},
        task: nil,
        stage: nil,
        timer: timer,
        observation_error: nil
      }

      state =
        Map.put(state, :observability_meta, %{
          id: state.id,
          definition: state.definition_meta,
          trace: state.trace,
          input: state.input,
          started_at: state.started_at_system
        })

      Knotra.Observability.register(state)

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
    case state.instance do
      nil -> {:reply, {:error, :not_found}, state}
      instance -> {:reply, {:ok, {:via, Registry, {instance, :executions}}}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

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
    state = %{stop_task(state) | observation_error: :observer_timeout}
    Knotra.Observability.update(state)
    durable_result(state)
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
    state = %{state | observation_error: :observer_failed}
    Knotra.Observability.update(state)
    state
  end

  defp consume({:plugin_error, reason}, state), do: finish(state, :failed, reason)

  defp consume({:ok, {:ok, tools, prepared, loop_state}}, %{stage: :setup} = state) do
    state
    |> Map.merge(%{
      tool_definitions: tools,
      prepared_tools: prepared,
      loop_state: loop_state
    })
    |> event(:started, %{input: state.input})
    |> observe()
  end

  defp consume({:ok, :ok}, %{stage: :observation} = state), do: advance(state)

  defp consume({:ok, _}, %{stage: :observation} = state),
    do: finish(state, :failed, :observer_failed)

  defp consume({:ok, {:done, text}}, %{stage: :loop} = state) when is_binary(text) do
    cond do
      pending(state) != [] -> finish(state, :failed, :pending_tools)
      String.trim(text) == "" -> finish(state, :failed, :empty_response)
      true -> finish(state, :completed, text)
    end
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
    # Durable runs resolve one pending call per reply, or finish as text-only work
    # with a zero-call reply.
    if valid_reply?(reply, state) and
         (is_nil(state.durable) or length(reply.calls) <= 1) do
      visible = Map.take(reply, [:text, :calls, :usage, :input_request])

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

  defp consume({:ok, {:ok, output}}, %{stage: {:tool, call}} = state) when is_binary(output),
    do: record_tool_result(state, call, output)

  defp consume({:ok, {:ok, validated, output}}, %{stage: {:tool, call}} = state)
       when is_map(validated) and is_binary(output),
       do: record_tool_result(state, %{call | arguments: validated}, output)

  defp consume(
         {:ok, {:not_dispatched, reason}},
         %{stage: {:tool, _}, durable: durable, approval: %{operation: %{status: :dispatching}}} =
           state
       )
       when not is_nil(durable) and is_atom(reason) do
    if state.durable[:retry] do
      # Refusal of this attempt says nothing about the earlier uncertain effect.
      refuse_dispatch(state, reason)
    else
      state = put_in(state.approval.operation.status, :not_dispatched)
      finish(state, :failed, reason)
    end
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

  defp consume({:ok, {:input, request, next}}, %{stage: :loop, durable: durable} = state)
       when not is_nil(durable) do
    if valid_input_request?(request) do
      request = Knotra.Durable.input_request(request, durable.response_timeout)
      finish(%{state | loop_state: next, input_request: request}, :waiting, nil)
    else
      finish(state, :failed, :invalid_plugin_result)
    end
  end

  defp consume({:ok, {:input, _request, _next}}, %{stage: :loop} = state),
    do: finish(state, :failed, :input_not_supported)

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

  defp record_tool_result(state, call, output) do
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

        request = %{
          input: state.input,
          exchanges: state.exchanges,
          tools: state.tool_definitions,
          prepared_tools: state.prepared_tools
        }

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

    if noop_observer?(module, opts) and state.durable do
      # Persist the safe point without spawning a task whose only possible result
      # is `:ok`. Non-durable runs keep the task because terminal observation
      # timing and the release path depend on it.
      case Knotra.Durable.persist(%{state | stage: :observation}) do
        {:ok, recorded} -> consume({:ok, :ok}, recorded)
        {:error, reason} -> block_durable(state, reason)
      end
    else
      snapshot = public(state)
      launch(state, :observation, fn -> module.record(snapshot, opts) end)
    end
  end

  defp noop_observer?(Knotra.Observers.Send, nil), do: true
  defp noop_observer?(_module, _opts), do: false

  defp finish(state, status, value) do
    {status, value} =
      if status in [:failed, :cancelled] and
           match?(%{operation: %{status: :dispatching}}, state[:approval]),
         do: {:blocked, :uncertain_effect},
         else: {status, value}

    {value, reason} = durable_failure(state, status, value)

    Process.cancel_timer(state.timer)

    state = %{
      state
      | status: status,
        output: if(status == :completed, do: value),
        error: if(status != :completed, do: value)
    }

    data = %{output: state.output, error: state.error}
    data = if reason, do: Map.put(data, :reason, reason), else: data
    state = event(state, status, data)

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

  # Host plugins may return any atom from `{:error, atom}`. Durable snapshots must
  # still decode in a fresh VM, so an unknown code becomes the stable
  # `:plugin_error` and the original atom is recorded as a nonsecret binary in the
  # terminal event. Non-durable runs keep the host's atom unchanged.
  defp durable_failure(%{durable: nil}, _status, value), do: {value, nil}

  defp durable_failure(_state, status, value) when status in [:failed, :blocked, :cancelled] do
    cond do
      Knotra.Checkpoint.portable_atom?(value) -> {value, nil}
      is_atom(value) -> {:plugin_error, Atom.to_string(value)}
      true -> {:invalid_plugin_result, nil}
    end
  end

  defp durable_failure(_state, _status, value), do: {value, nil}

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
    state = %{state | status: :blocked, error: reason}
    Knotra.Observability.update(state)

    case Knotra.Durable.block_failed(state, reason) do
      {:ok, snapshot} -> notify_released(state, snapshot)
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
    sequence = state.next_sequence + 1

    entry = %{
      sequence: sequence,
      elapsed_ms: System.monotonic_time(:millisecond) - state.started_at,
      type: type,
      data: data
    }

    Knotra.Observability.record_event(state, entry)

    %{state | events: [entry | state.events], next_sequence: sequence}
  end

  defp count(state, key), do: update_in(state.counts[key], &(&1 + 1))

  @doc false
  def public(state) do
    snapshot = public_record(state)

    if state.durable do
      snapshot
      |> Map.put(:approval, state.approval)
      |> Map.put(:input_request, state.input_request)
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

    valid_input_request?(reply.input_request) and
      (reply.input_request == nil or reply.calls == []) and
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

  defp valid_input_request?(nil), do: true

  defp valid_input_request?(%{prompt: prompt} = request)
       when is_binary(prompt) and prompt != "" and map_size(request) == 1,
       do: true

  defp valid_input_request?(_), do: false

  # state.events is newest-first, so the first answer event is the current one.
  @doc false
  def last_answered(events) do
    Enum.find_value(events, fn
      %{type: :input_answered} -> :input_answered
      %{type: :approval_answered} -> :approval_answered
      _ -> nil
    end)
  end

  defp execution_id(%{row: %{id: id}}), do: id
  defp execution_id(_durable), do: System.unique_integer([:positive, :monotonic])

  defp initialize(state, durable) do
    state = Map.merge(state, %{durable: durable, approval: nil, input_request: nil})

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

    prepared =
      case prepare_tools(state.definition, tools) do
        {:ok, prepared} -> prepared
        {:error, _reason} -> nil
      end

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
      |> Map.merge(
        Map.take(saved, [
          :loop_state,
          :exchanges,
          :last,
          :counts,
          :limits,
          :approval,
          :input_request
        ])
      )
      |> Map.merge(%{
        events: Enum.reverse(snapshot.events),
        next_sequence: length(snapshot.events),
        tool_definitions: tools,
        prepared_tools: prepared,
        started_at: now - elapsed,
        deadline_at: now + remaining,
        timer: Process.send_after(self(), :deadline, remaining)
      })

    cond do
      match?(%{disposition: :answered}, state.input_request) and
          last_answered(state.events) == :input_answered ->
        # Resume the same conversation with the human answer and call the model
        # directly, then let the loop evaluate the new reply at :reply. Entering
        # the loop at :model would request a second model call and re-ask. The most
        # recent answer decides: an approval continuation after an earlier
        # answered clarification must still dispatch its admitted operation.
        state =
          state
          |> Map.put(:loop_state, :reply)
          |> Map.put(
            :exchanges,
            List.update_at(state.exchanges, -1, &Map.put(&1, :answer, state.input_request.answer))
          )

        operation(state, :model)

      state.approval != nil and state.approval.operation.status == :succeeded ->
        advance(state)

      true ->
        dispatch_approved(state)
    end
  end

  defp dispatch_approved(state) do
    approval = state.approval
    call = Enum.find(pending(state), &(&1.id == approval.call_id and &1.name == approval.name))

    cond do
      call == nil ->
        finish(state, :blocked, :invalid_tool_request)

      expired?(state) ->
        refuse_dispatch(state, :deadline_exceeded)

      state.counts.tools >= state.limits.max_tool_calls ->
        refuse_dispatch(state, :tool_limit)

      state.durable[:retry] == true and state.counts.retries >= state.limits.max_retries ->
        refuse_dispatch(state, :retries_exhausted)

      true ->
        call = %{call | arguments: approval.arguments}

        state =
          put_in(state.approval.operation, %{
            state.approval.operation
            | status: :dispatching,
              admitted: true
          })

        state =
          if state.durable[:retry],
            do:
              state
              |> count(:retries)
              |> event(:retry, %{reason: :uncertain_effect, operation_id: approval.operation.id}),
            else: state

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

  defp refuse_dispatch(state, reason) do
    if state.durable[:retry] do
      state
      |> event(:retry_refused, %{reason: reason, operation_id: state.approval.operation.id})
      |> finish(:blocked, :uncertain_effect)
    else
      finish(state, :failed, reason)
    end
  end

  defp setup definition, durable do
    {loop, opts} = definition.loop

    with {:ok, tools} <- tool_definitions(definition, durable),
         {:ok, prepared} <- prepare_tools(definition, tools) do
      {:ok, tools, prepared, loop.init(opts)}
    end
  end

  defp prepare_tools(definition, tools) do
    {model, _} = definition.model

    if function_exported?(model, :prepare_tools, 1) do
      case model.prepare_tools(tools) do
        {:ok, prepared} -> {:ok, prepared}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        {:error, _reason} -> {:error, :invalid_plugin_result}
        _other -> {:error, :invalid_plugin_result}
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  def validate(definition, input, opts, durable \\ false) do
    if valid_options?(definition, input, opts) do
      # Tool `definition/0` is host code. It may raise, throw, or exit; a
      # preflight must return an error tuple instead of taking the caller down.
      # Model tool preparation stays in `setup/2`, inside the supervised task
      # and its deadline, and runs exactly once.
      try do
        case tool_definitions(definition, durable) do
          {:ok, _tools} -> :ok
          {:error, _reason} = error -> error
        end
      rescue
        _ -> {:error, :invalid_tool_definitions}
      catch
        _, _ -> {:error, :invalid_tool_definitions}
      end
    else
      {:error, :invalid_configuration}
    end
  end

  defp instance_name({:via, Registry, {instance, :tasks}}), do: instance
  defp instance_name(_), do: nil

  @doc false
  def tool_definitions(definition, durable) do
    tools = Enum.map(definition.tools, & &1.definition())
    names = Enum.map(tools, & &1.name)
    allow_writes = durable or runtime_supports_writes?(definition.tool_runtime)

    if length(names) == length(Enum.uniq(names)) and
         Enum.all?(tools, fn tool ->
           match?(
             %{name: name, description: description, parameters: parameters, read_only: read_only}
             when is_binary(name) and name != "" and is_binary(description) and is_map(parameters) and
                    is_boolean(read_only),
             tool
           ) and (tool.read_only or allow_writes)
         end) do
      {:ok, tools}
    else
      {:error, :invalid_tool_definitions}
    end
  end

  defp runtime_supports_writes?({module, _opts}) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :supports_writes?, 0) and
      module.supports_writes?()
  end

  defp runtime_supports_writes?(_), do: false

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
        # Zero is a legal boundary budget: the execution fails deterministically at
        # the corresponding limit (`:turn_limit`, `:tool_limit`, `:step_limit`).
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
