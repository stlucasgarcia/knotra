defmodule Knotra.Execution do
  @moduledoc false
  use GenServer, restart: :temporary

  @defaults [max_turns: 8, max_tool_calls: 16, max_retries: 0, max_steps: 64, timeout: 30_000]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({tasks, definition, input, auth, opts}) do
    if valid_options?(definition, input, opts) do
      Process.flag(:trap_exit, true)
      limits = Keyword.merge(@defaults, opts) |> Map.new()
      timer = Process.send_after(self(), :deadline, limits.timeout)

      state = %{
        tasks: tasks,
        definition: definition,
        input: input,
        auth: auth,
        limits: limits,
        id: System.unique_integer([:positive, :monotonic]),
        started_at: System.monotonic_time(:millisecond),
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

      {:ok, launch(state, :setup, fn -> setup(definition) end)}
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

  def handle_call(:release, _from, %{status: :running} = state),
    do: {:reply, {:error, :running}, state}

  def handle_call(:release, _from, state), do: {:stop, :normal, :ok, stop_task(state)}

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, consume(result, %{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, consume({:plugin_error, :task_exit}, %{state | task: nil})}
  end

  def handle_info(:deadline, %{status: :running} = state) do
    {:noreply, state |> stop_task() |> finish(:failed, :deadline_exceeded)}
  end

  def handle_info(:observer_deadline, state) do
    {:noreply, %{stop_task(state) | observation_error: :observer_timeout}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_task(state)
    :ok
  end

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
    if valid_reply?(reply, state) do
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

    state
    |> Map.merge(%{exchanges: exchanges, last: {:tool, %{call: call, output: output}}})
    |> event(:tool_result, %{call: call, output: output})
    |> observe()
  end

  defp consume({:ok, {:retry, reason}}, %{stage: stage} = state)
       when is_atom(reason) and (stage == :model or elem(stage, 0) == :tool) do
    if state.counts.retries < state.limits.max_retries do
      state |> count(:retries) |> event(:retry, %{reason: reason}) |> operation(stage)
    else
      finish(state, :failed, :retries_exhausted)
    end
  end

  defp consume({:ok, {:error, reason}}, state) when is_atom(reason),
    do: finish(state, :failed, reason)

  defp consume(_result, state), do: finish(state, :failed, :invalid_plugin_result)

  defp advance(state) do
    if state.counts.steps < state.limits.max_steps do
      {module, _} = state.definition.loop
      view = %{input: state.input, last: state.last, counts: state.counts}
      launch(count(state, :steps), :loop, fn -> module.next(view, state.loop_state) end)
    else
      finish(state, :failed, :step_limit)
    end
  end

  defp operation(state, :model) do
    if state.counts.turns < state.limits.max_turns do
      {module, opts} = state.definition.model
      request = %{input: state.input, exchanges: state.exchanges, tools: state.tool_definitions}
      state = state |> count(:turns) |> event(:model_started, %{})
      launch(state, :model, fn -> module.call(request, opts) end)
    else
      finish(state, :failed, :turn_limit)
    end
  end

  defp operation(state, {:tool, call} = stage) do
    if state.counts.tools < state.limits.max_tool_calls do
      {module, opts} = state.definition.tool_runtime
      state = state |> count(:tools) |> event(:tool_started, %{call: call})

      launch(state, stage, fn ->
        module.execute(call, state.definition.tools, state.auth, opts)
      end)
    else
      finish(state, :failed, :tool_limit)
    end
  end

  defp observe(state) do
    {module, opts} = state.definition.observer
    snapshot = public(state)
    launch(state, :observation, fn -> module.record(snapshot, opts) end)
  end

  defp finish(state, status, value) do
    Process.cancel_timer(state.timer)

    state = %{
      state
      | status: status,
        output: if(status == :completed, do: value),
        error: if(status != :completed, do: value)
    }

    state = event(state, status, %{output: state.output, error: state.error})
    state = observe(state)

    %{
      state
      | stage: :terminal_observation,
        timer: Process.send_after(self(), :observer_deadline, 1_000)
    }
  end

  defp launch(state, stage, fun) do
    # Plugin exceptions may contain credentials. Retain a stable failure class,
    # never raw exception messages or provider response bodies in public records.
    task =
      Task.Supervisor.async(state.tasks, fn ->
        try do
          {:ok, fun.()}
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

  defp public(state) do
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

  defp valid_reply?(reply, state) do
    previous_ids = for exchange <- state.exchanges, call <- exchange.reply.calls, do: call.id

    is_binary(reply.text) and (is_nil(reply.usage) or is_map(reply.usage)) and
      is_list(reply.calls) and
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

  defp setup(definition) do
    {loop, opts} = definition.loop
    tools = Enum.map(definition.tools, & &1.definition())
    names = Enum.map(tools, & &1.name)

    if length(names) == length(Enum.uniq(names)) and
         Enum.all?(tools, fn tool ->
           match?(
             %{name: name, description: description, parameters: parameters, read_only: true}
             when is_binary(name) and is_binary(description) and is_map(parameters),
             tool
           )
         end) do
      {:ok, tools, loop.init(opts)}
    else
      {:error, :invalid_tool_definitions}
    end
  end

  defp valid_options?(definition, input, opts) do
    is_binary(input) and input != "" and is_binary(definition.version) and
      definition.version != "" and
      is_list(definition.tools) and
      Enum.all?(
        definition.tools,
        &implements?(&1, definition: 0, validate: 1, authorize: 2, call: 2)
      ) and
      plugin?(definition.loop, init: 1, next: 2) and plugin?(definition.model, call: 2) and
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
