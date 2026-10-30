defmodule Knotra.Observability.Store do
  @moduledoc false
  use GenServer

  alias Knotra.Observability.Snapshot

  @defaults [max_records: 200, max_events: 2_000, notify_ms: 100, message_limit: 200]
  # `:waiting` is live: a pending approval or clarification may last indefinitely,
  # so it is never evicted as a finished record.
  @terminal [:completed, :failed, :cancelled, :blocked, :rejected, :expired]
  @max_links 1_000
  @max_pending_annotations 200
  @max_labels 20

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :instance)))

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :instance)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  def via(instance), do: {:via, Registry, {instance, :observability}}

  @doc false
  def record(instance, message) when is_atom(instance) do
    key = {__MODULE__, instance}

    try do
      case Process.get(key) do
        pid when is_pid(pid) ->
          send(pid, {:"$gen_cast", message})

        _ ->
          case GenServer.whereis(via(instance)) do
            pid when is_pid(pid) ->
              Process.put(key, pid)
              GenServer.cast(pid, message)

            _ ->
              :ok
          end
      end
    catch
      _, _ -> :ok
    end
  end

  @impl true
  def init(opts) do
    instance = Keyword.fetch!(opts, :instance)
    config = Keyword.merge(@defaults, Keyword.get(opts, :opts, []))
    validate_config!(config)

    {:ok,
     %{
       instance: instance,
       records: %{},
       swarms: %{},
       pending_annotations: %{},
       pending_seq: 0,
       terminals: :gb_sets.empty(),
       terminal_keys: %{},
       links: [],
       subscribers: %{},
       notify_timer: nil,
       snapshot_cache: %{},
       version: 0,
       seq: 0,
       max_records: Keyword.fetch!(config, :max_records),
       max_swarms: Keyword.fetch!(config, :max_records),
       max_events: Keyword.fetch!(config, :max_events),
       notify_ms: Keyword.fetch!(config, :notify_ms),
       message_limit: Keyword.fetch!(config, :message_limit)
     }}
  end

  @impl true
  def handle_cast({:register, meta}, state) do
    state = state |> upsert(meta, %{}) |> mark_dirty()
    {:noreply, state}
  end

  def handle_cast({:event, meta, attrs, entry}, state) do
    state = state |> upsert(meta, attrs, entry) |> mark_dirty()
    {:noreply, state}
  end

  def handle_cast({:update, id, attrs}, state) do
    state = state |> update_record(id, attrs) |> mark_dirty()
    {:noreply, state}
  end

  def handle_cast({:swarm_event, id, type, data}, state) do
    state = state |> put_swarm_event(id, type, data) |> mark_dirty()
    {:noreply, state}
  end

  def handle_cast({:annotate, id, trace}, state) do
    state = state |> annotate_record(id, trace) |> mark_dirty()
    {:noreply, state}
  end

  def handle_cast({:link, from, to, label}, state) do
    link = %{from: from, to: to, label: label, at: System.system_time(:millisecond)}
    links = Enum.take([link | state.links], @max_links)
    {:noreply, mark_dirty(%{state | links: links})}
  end

  @impl true
  def handle_call({:snapshot, opts}, _from, state) do
    limit = Keyword.get(opts, :message_limit, state.message_limit)

    case state.snapshot_cache do
      %{^limit => {version, snapshot}} when version == state.version ->
        {:reply, {:ok, snapshot}, state}

      _ ->
        snapshot =
          Snapshot.build(
            Map.values(state.records),
            links: state.links,
            message_limit: limit,
            swarms: Map.values(state.swarms)
          )

        cache =
          if map_size(state.snapshot_cache) >= 4,
            do: %{limit => {state.version, snapshot}},
            else: Map.put(state.snapshot_cache, limit, {state.version, snapshot})

        {:reply, {:ok, snapshot}, %{state | snapshot_cache: cache}}
    end
  end

  def handle_call({:execution, id}, _from, state) do
    case fetch_record(state, id) do
      {:ok, record} -> {:reply, {:ok, execution_detail(record)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:swarm, id}, _from, state) do
    case Map.fetch(state.swarms, id) do
      {:ok, swarm} -> {:reply, {:ok, swarm_detail(state, swarm)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:annotate, id, trace}, _from, state) do
    {:reply, :ok, state |> annotate_record(id, trace) |> mark_dirty()}
  end

  def handle_call({:link, from, to, label}, _from, state) do
    link = %{from: from, to: to, label: label, at: System.system_time(:millisecond)}
    links = Enum.take([link | state.links], @max_links)
    {:reply, :ok, mark_dirty(%{state | links: links})}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      case Map.fetch(state.subscribers, pid) do
        {:ok, _ref} ->
          state

        :error ->
          ref = Process.monitor(pid)
          %{state | subscribers: Map.put(state.subscribers, pid, ref)}
      end

    {:reply, :ok, state}
  end

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(:notify, state) do
    Enum.each(Map.keys(state.subscribers), fn pid ->
      send(pid, {:knotra_observability, state.instance})
    end)

    {:noreply, %{state | notify_timer: nil}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @swarm_terminal [:completed, :partial, :failed, :cancelled, :timeout]

  defp put_swarm_event(state, id, type, data) do
    now = now()
    previous = Map.get(state.swarms, id)
    swarm = previous || new_swarm(id, now)

    swarm =
      swarm
      |> merge_swarm_data(type, data, now)
      |> append_swarm_event(type, data, now, state.max_events)

    %{state | swarms: Map.put(state.swarms, id, swarm)}
    |> evict_swarms()
  end

  defp new_swarm(id, now) do
    %{
      id: id,
      mode: nil,
      goal: nil,
      status: :running,
      config: %{},
      started_at: now,
      updated_at: now,
      finished_at: nil,
      events: [],
      event_count: 0,
      planner: nil,
      agents: [],
      tasks: [],
      escalations: [],
      output: nil,
      error: nil,
      counts: %{}
    }
  end

  defp merge_swarm_data(swarm, type, data, now) do
    attrs =
      data
      |> Map.take([
        :mode,
        :goal,
        :config,
        :planner,
        :agents,
        :tasks,
        :escalations,
        :output,
        :error,
        :counts,
        :status
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    swarm =
      swarm
      |> Map.merge(attrs)
      |> Map.put(:updated_at, now)
      |> update_swarm_tasks(type, data)
      |> maybe_append_escalation(type, data)
      |> maybe_finish_swarm(type, data, now)

    swarm
  end

  defp update_swarm_tasks(swarm, :planned, %{tasks: tasks}) when is_list(tasks) do
    %{swarm | tasks: tasks}
  end

  defp update_swarm_tasks(swarm, :task_started, data) do
    task = %{
      id: data[:id],
      agent: data[:agent],
      iteration: Map.get(data, :iteration, 1),
      input: Map.get(data, :input),
      status: :running,
      error: nil,
      elapsed_ms: nil,
      counts: nil
    }

    %{swarm | tasks: put_task(swarm.tasks, task)}
  end

  defp update_swarm_tasks(swarm, :task_finished, data) do
    task = %{
      id: data[:id],
      agent: data[:agent],
      iteration: Map.get(data, :iteration, 1),
      input: Map.get(data, :input),
      status: Map.get(data, :status, :failed),
      error: Map.get(data, :error),
      elapsed_ms: Map.get(data, :elapsed_ms),
      counts: Map.get(data, :counts)
    }

    %{swarm | tasks: put_task(swarm.tasks, task)}
  end

  defp update_swarm_tasks(swarm, _type, _data), do: swarm

  defp put_task(tasks, task) do
    case Enum.find_index(tasks, &(&1.id == task.id)) do
      nil -> tasks ++ [task]
      index -> List.replace_at(tasks, index, Map.merge(Enum.at(tasks, index), task))
    end
  end

  defp maybe_append_escalation(swarm, :escalation, data) do
    %{swarm | escalations: [data | Enum.reject(swarm.escalations, &(&1 == data))]}
  end

  defp maybe_append_escalation(swarm, _type, _data), do: swarm

  defp maybe_finish_swarm(swarm, :finished, data, now) do
    %{swarm | status: Map.get(data, :status, swarm.status), finished_at: now}
  end

  defp maybe_finish_swarm(swarm, _type, _data, _now), do: swarm

  defp append_swarm_event(swarm, type, data, now, max_events) do
    entry = %{
      sequence: swarm.event_count + 1,
      at: now,
      elapsed_ms: max(now - swarm.started_at, 0),
      type: type,
      data: data
    }

    events = swarm.events ++ [entry]

    events =
      if max_events == :infinity or length(events) <= max_events,
        do: events,
        else: Enum.take(events, -max_events)

    %{swarm | events: events, event_count: swarm.event_count + 1}
  end

  defp execution_detail(record) do
    events = :queue.to_list(record.events)
    finish = record.finished_at || record.updated_at

    record
    |> Map.put(:events, events)
    |> Map.put(:duration_ms, max(finish - record.started_at, 0))
    |> Map.put(:truncated?, record.event_count > record.retained_events)
    |> Map.put(:timings, Knotra.Observability.Timing.summarize(events))
  end

  defp swarm_detail(state, swarm) do
    children =
      state.records
      |> Map.values()
      |> Enum.filter(&(&1.trace.conversation_id == to_string(swarm.id)))

    swarm =
      swarm
      |> Map.put(:elapsed_ms, max((swarm.finished_at || swarm.updated_at) - swarm.started_at, 0))
      |> Map.put(:truncated?, swarm.event_count > length(swarm.events))

    %{
      swarm: swarm,
      executions: Enum.map(children, &execution_detail/1),
      timeline: swarm_timeline(swarm, children)
    }
  end

  defp swarm_timeline(swarm, children) do
    coordinator =
      Enum.map(swarm.events, fn event ->
        %{
          at: event.at,
          offset_ms: event.elapsed_ms,
          source: "coordinator",
          execution_id: nil,
          type: event.type,
          sequence: event.sequence,
          data: event.data
        }
      end)

    agents =
      Enum.flat_map(children, fn record ->
        source = record.trace.agent || record.definition.version

        record.events
        |> :queue.to_list()
        |> Enum.map(fn event ->
          at = record.started_at + event.elapsed_ms

          %{
            at: at,
            offset_ms: max(at - swarm.started_at, 0),
            source: source,
            execution_id: record.id,
            type: event.type,
            sequence: event.sequence,
            data: event.data
          }
        end)
      end)

    Enum.sort_by(coordinator ++ agents, &{&1.at, &1.source, &1.sequence})
  end

  defp evict_swarms(%{max_swarms: :infinity} = state), do: state

  defp evict_swarms(state) do
    if map_size(state.swarms) > state.max_swarms do
      finished =
        state.swarms
        |> Enum.filter(fn {_id, swarm} -> swarm.status in @swarm_terminal end)
        |> Enum.sort_by(fn {_id, swarm} -> swarm.finished_at || swarm.updated_at end)

      case finished do
        [{id, _swarm} | _] ->
          state
          |> Map.update!(:swarms, &Map.delete(&1, id))
          |> evict_swarms()

        [] ->
          state
      end
    else
      state
    end
  end

  defp validate_config!(config) do
    records = Keyword.fetch!(config, :max_records)
    events = Keyword.fetch!(config, :max_events)
    notify = Keyword.fetch!(config, :notify_ms)
    messages = Keyword.fetch!(config, :message_limit)

    unless records == :infinity or (is_integer(records) and records > 0) do
      raise ArgumentError, "observability :max_records must be a positive integer or :infinity"
    end

    unless events == :infinity or (is_integer(events) and events > 0) do
      raise ArgumentError, "observability :max_events must be a positive integer or :infinity"
    end

    unless is_integer(notify) and notify >= 0 do
      raise ArgumentError, "observability :notify_ms must be a non-negative integer"
    end

    unless is_integer(messages) and messages >= 0 do
      raise ArgumentError, "observability :message_limit must be a non-negative integer"
    end
  end

  defp upsert(state, meta, attrs, entry \\ nil) do
    now = System.system_time(:millisecond)
    id = Map.fetch!(meta, :id)
    previous = Map.get(state.records, id)

    record =
      case previous do
        nil -> new_record(state, meta, now)
        record -> record
      end

    record =
      record
      |> Map.merge(attrs)
      |> Map.put(:updated_at, now)
      |> maybe_reopen()
      |> maybe_finish(now)
      |> maybe_append(entry, state.max_events)

    %{state | records: Map.put(state.records, id, record), seq: max(state.seq, record.seq)}
    |> track_terminal(previous, record)
    |> apply_pending_annotation(id)
    |> evict()
  end

  defp new_record(state, meta, now) do
    trace = normalize_record_trace(Map.get(meta, :trace))

    seq = state.seq + 1

    %{
      id: Map.fetch!(meta, :id),
      definition: Map.fetch!(meta, :definition),
      trace: trace,
      input: Map.get(meta, :input),
      pid: Map.get(meta, :pid),
      status: Map.get(meta, :status, :running),
      counts: Map.get(meta, :counts, %{turns: 0, tools: 0, retries: 0, steps: 0}),
      output: nil,
      error: nil,
      observation_error: nil,
      approval: nil,
      input_request: nil,
      started_at: Map.get(meta, :started_at, now),
      updated_at: now,
      finished_at: nil,
      # Newest events are appended at the rear; the front is trimmed, so both
      # ends stay O(1) however long the execution runs.
      events: :queue.new(),
      event_count: 0,
      retained_events: 0,
      seq: seq
    }
  end

  defp normalize_record_trace(nil), do: Knotra.Observability.empty_trace()

  defp normalize_record_trace(trace) do
    Map.merge(Knotra.Observability.empty_trace(), trace)
  end

  defp maybe_append(record, nil, _max_events), do: record

  defp maybe_append(record, entry, max_events) do
    events = :queue.in(entry, record.events)
    retained = record.retained_events + 1

    {events, retained} =
      if max_events == :infinity or retained <= max_events do
        {events, retained}
      else
        {:queue.drop(events), max_events}
      end

    %{record | events: events, event_count: record.event_count + 1, retained_events: retained}
  end

  # A durable execution that resumes after a wait runs again; its duration must
  # not end at the first wait. Clearing the timestamp lets the next terminal
  # transition set the real finish.
  defp maybe_reopen(%{finished_at: nil} = record), do: record
  defp maybe_reopen(%{status: status} = record) when status in @terminal, do: record
  defp maybe_reopen(record), do: %{record | finished_at: nil}

  defp maybe_finish(%{finished_at: nil} = record, now) do
    if record.status in @terminal, do: %{record | finished_at: now}, else: record
  end

  defp maybe_finish(record, _now), do: record

  # Terminal records are indexed in eviction order so retention does not scan
  # every running execution on each event.
  defp track_terminal(state, previous, record) do
    was_terminal = previous != nil and previous.status in @terminal
    terminal? = record.status in @terminal

    cond do
      terminal? and not was_terminal ->
        key = {record.started_at, record.seq, record.id}

        %{
          state
          | terminals: :gb_sets.add(key, state.terminals),
            terminal_keys: Map.put(state.terminal_keys, record.id, key)
        }

      was_terminal and not terminal? ->
        case Map.pop(state.terminal_keys, record.id) do
          {nil, keys} ->
            %{state | terminal_keys: keys}

          {key, keys} ->
            %{state | terminal_keys: keys, terminals: :gb_sets.delete_any(key, state.terminals)}
        end

      true ->
        state
    end
  end

  defp update_record(state, id, attrs) do
    case fetch_record(state, id) do
      {:ok, previous} ->
        now = System.system_time(:millisecond)

        record =
          previous
          |> Map.merge(attrs)
          |> Map.put(:updated_at, now)
          |> maybe_reopen()
          |> maybe_finish(now)

        %{state | records: Map.put(state.records, record.id, record)}
        |> track_terminal(previous, record)

      :error ->
        state
    end
  end

  defp annotate_record(state, id, trace) do
    case fetch_record(state, id) do
      {:ok, record} ->
        record = %{record | trace: merge_trace(record.trace, trace), updated_at: now()}
        %{state | records: Map.put(state.records, record.id, record)}

      :error ->
        seq = state.pending_seq + 1

        trace =
          case Map.fetch(state.pending_annotations, id) do
            {:ok, {_seq, previous}} -> merge_trace(previous, trace)
            :error -> trace
          end

        pending =
          state.pending_annotations
          |> Map.put(id, {seq, trace})
          |> prune_pending()

        %{state | pending_annotations: pending, pending_seq: seq}
    end
  end

  # Annotations may arrive before their execution registers. Keep that race
  # working without letting unknown ids grow memory forever.
  defp prune_pending(pending) do
    if map_size(pending) > @max_pending_annotations do
      {id, _} = Enum.min_by(pending, fn {_id, {seq, _trace}} -> seq end)
      Map.delete(pending, id)
    else
      pending
    end
  end

  defp apply_pending_annotation(state, id) do
    case Map.pop(state.pending_annotations, id) do
      {nil, _pending} ->
        state

      {{_seq, trace}, pending} ->
        records =
          Map.update!(state.records, id, fn record ->
            %{record | trace: merge_trace(record.trace, trace)}
          end)

        %{state | records: records, pending_annotations: pending}
    end
  end

  defp merge_trace(left, right) do
    Map.merge(normalize_record_trace(left), normalize_record_trace(right), fn
      :labels, old, new -> cap_labels(Map.merge(old, new))
      _key, old, nil -> old
      _key, _old, new -> new
    end)
  end

  defp cap_labels(labels) when map_size(labels) <= @max_labels, do: labels

  defp cap_labels(labels) do
    labels
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.take(@max_labels)
    |> Map.new()
  end

  defp fetch_record(state, id) do
    case Map.fetch(state.records, id) do
      {:ok, record} ->
        {:ok, record}

      :error when is_binary(id) ->
        case Integer.parse(id) do
          {integer, ""} -> Map.fetch(state.records, integer)
          _ -> :error
        end

      :error when is_integer(id) ->
        Map.fetch(state.records, Integer.to_string(id))

      :error ->
        :error
    end
  end

  defp evict(%{max_records: :infinity} = state), do: state

  defp evict(state) do
    if map_size(state.records) > state.max_records do
      case :gb_sets.is_empty(state.terminals) do
        true ->
          state

        false ->
          {{_started_at, _seq, id}, terminals} = :gb_sets.take_smallest(state.terminals)

          %{
            state
            | terminals: terminals,
              terminal_keys: Map.delete(state.terminal_keys, id),
              records: Map.delete(state.records, id)
          }
          |> evict()
      end
    else
      state
    end
  end

  defp mark_dirty(state) do
    state = %{state | version: state.version + 1}

    if map_size(state.subscribers) > 0 and state.notify_timer == nil do
      %{state | notify_timer: Process.send_after(self(), :notify, state.notify_ms)}
    else
      state
    end
  end

  defp now, do: System.system_time(:millisecond)
end
