defmodule Knotra.Observability.Snapshot do
  @moduledoc false

  @running [:running, :accepted]
  @failed [:failed, :blocked, :cancelled, :rejected, :expired]
  @message_events [
    :started,
    :model_result,
    :tool_result,
    :input_answered,
    :approval_answered,
    :failed,
    :blocked,
    :cancelled,
    :rejected,
    :expired,
    :waiting
  ]

  def build(records, opts) do
    records = Enum.sort_by(records, &{&1.started_at, &1.seq}, :desc)
    agents = agents(records)

    %{
      stats: stats(records, agents),
      agents: agents,
      executions: Enum.map(records, &summary/1),
      graph: graph(records, Keyword.get(opts, :links, [])),
      messages: messages(records, Keyword.get(opts, :message_limit, 200))
    }
  end

  def summary(record) do
    timings = Knotra.Observability.Timing.summary(:queue.to_list(record.events))

    record
    |> Map.drop([:events])
    |> Map.put(:duration_ms, duration_ms(record))
    |> Map.put(:truncated?, record.event_count > record.retained_events)
    |> Map.put(:timings, timings)
  end

  defp stats(records, agents) do
    models =
      records |> Enum.map(& &1.definition.model.id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      executions: length(records),
      running: Enum.count(records, &(&1.status in @running)),
      waiting: Enum.count(records, &(&1.status == :waiting)),
      completed: Enum.count(records, &(&1.status == :completed)),
      failed: Enum.count(records, &(&1.status in @failed)),
      agents: length(agents),
      models: models,
      events: Enum.reduce(records, 0, &(&1.event_count + &2)),
      newest_started_at:
        case records do
          [first | _] -> first.started_at
          [] -> nil
        end
    }
  end

  defp agents(records) do
    records
    |> Enum.group_by(& &1.definition.version)
    |> Enum.map(fn {version, runs} ->
      latest = Enum.max_by(runs, &{&1.started_at, &1.seq})

      %{
        id: version,
        label: latest.trace.agent || version,
        model: latest.definition.model,
        tools: latest.definition.tools,
        loop: latest.definition.loop,
        tool_runtime: latest.definition.tool_runtime,
        observer: latest.definition.observer,
        executions: length(runs),
        running: Enum.count(runs, &(&1.status in @running)),
        waiting: Enum.count(runs, &(&1.status == :waiting)),
        completed: Enum.count(runs, &(&1.status == :completed)),
        failed: Enum.count(runs, &(&1.status in @failed)),
        events: Enum.reduce(runs, 0, &(&1.event_count + &2)),
        last_started_at: latest.started_at,
        execution_ids: runs |> Enum.sort_by(& &1.started_at, :desc) |> Enum.map(& &1.id)
      }
    end)
    |> Enum.sort_by(& &1.last_started_at, :desc)
  end

  defp graph(records, explicit_links) do
    by_id = Map.new(records, &{to_string(&1.id), &1})

    parent_edges =
      records
      |> Enum.flat_map(fn record ->
        case record.trace.parent_id do
          nil ->
            []

          parent_id ->
            case Map.fetch(by_id, to_string(parent_id)) do
              {:ok, parent} ->
                [execution_edge(parent, record, "delegates")]

              :error ->
                [
                  %{
                    from: to_string(parent_id),
                    to: to_string(record.id),
                    kind: :link,
                    label: "delegates",
                    from_agent: nil,
                    to_agent: agent_of(record),
                    at: record.started_at
                  }
                ]
            end
        end
      end)

    link_edges =
      Enum.map(explicit_links, fn link ->
        from = Map.get(by_id, to_string(link.from))
        to = Map.get(by_id, to_string(link.to))

        %{
          from: to_string(link.from),
          to: to_string(link.to),
          kind: :link,
          label: link.label,
          from_agent: from && agent_of(from),
          to_agent: to && agent_of(to),
          at: link.at
        }
      end)

    conversations = conversations(records)
    links = parent_edges ++ link_edges
    link_pairs = MapSet.new(links, &{&1.from, &1.to})

    conversation_edges =
      conversations
      |> Enum.flat_map(&conversation_edges/1)
      |> Enum.reject(&MapSet.member?(link_pairs, {&1.from, &1.to}))

    %{
      conversations: conversations,
      edges: links ++ conversation_edges,
      agent_edges: agent_edges(links ++ conversation_edges),
      links: links
    }
  end

  defp execution_edge(parent, child, label) do
    %{
      from: to_string(parent.id),
      to: to_string(child.id),
      kind: :link,
      label: label,
      from_agent: agent_of(parent),
      to_agent: agent_of(child),
      at: child.started_at
    }
  end

  defp conversations(records) do
    records
    |> Enum.group_by(fn record ->
      record.trace.conversation_id || "execution:#{record.id}"
    end)
    |> Enum.map(fn {id, runs} ->
      runs = Enum.sort_by(runs, &{&1.started_at, &1.seq})

      %{
        id: id,
        agents: runs |> Enum.map(&agent_of/1) |> Enum.uniq(),
        started_at: hd(runs).started_at,
        updated_at: runs |> Enum.map(& &1.updated_at) |> Enum.max(),
        executions: Enum.map(runs, &execution_node/1)
      }
    end)
    |> Enum.sort_by(& &1.updated_at, :desc)
    |> Enum.take(40)
  end

  defp conversation_edges(%{executions: [_single]}), do: []

  defp conversation_edges(%{executions: executions}) do
    executions
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [left, right] ->
      %{
        from: left.id,
        to: right.id,
        kind: :conversation,
        label: "conversation",
        from_agent: left.agent,
        to_agent: right.agent,
        at: right.started_at
      }
    end)
  end

  defp agent_edges(edges) do
    edges
    |> Enum.reject(&(is_nil(&1.from_agent) or is_nil(&1.to_agent)))
    |> Enum.group_by(&{&1.from_agent, &1.to_agent})
    |> Enum.map(fn {{from, to}, group} ->
      %{
        from: from,
        to: to,
        count: length(group),
        kinds: group |> Enum.map(& &1.kind) |> Enum.uniq(),
        last_at: group |> Enum.map(& &1.at) |> Enum.max()
      }
    end)
    |> Enum.sort_by(& &1.last_at, :desc)
  end

  defp execution_node(record) do
    %{
      id: to_string(record.id),
      agent: agent_of(record),
      version: record.definition.version,
      model: record.definition.model.id,
      status: record.status,
      started_at: record.started_at,
      updated_at: record.updated_at,
      duration_ms: duration_ms(record),
      event_count: record.event_count,
      input: record.input
    }
  end

  defp messages(_records, 0), do: []

  defp messages(records, limit) do
    records
    |> Enum.flat_map(fn record ->
      record.events
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.filter(&(&1.type in @message_events))
      |> Enum.take(limit)
      |> Enum.map(fn event -> {record.started_at + event.elapsed_ms, record, event} end)
    end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_at, record, event} -> message(record, event) end)
  end

  defp message(record, event) do
    data = event.data || %{}

    %{
      id: "#{record.id}:#{event.sequence}",
      execution_id: to_string(record.id),
      agent: agent_of(record),
      model: record.definition.model.id,
      type: event.type,
      kind: message_kind(event.type),
      at: record.started_at + event.elapsed_ms,
      elapsed_ms: event.elapsed_ms,
      text: message_text(event.type, data, record),
      tool: message_tool(event.type, data),
      usage: message_usage(event.type, data)
    }
  end

  defp message_kind(:started), do: :input
  defp message_kind(:model_result), do: :assistant
  defp message_kind(:tool_result), do: :tool
  defp message_kind(type) when type in [:input_answered, :approval_answered], do: :human
  defp message_kind(type) when type in [:failed, :blocked, :cancelled, :rejected], do: :error
  defp message_kind(:expired), do: :error
  defp message_kind(:waiting), do: :notice

  defp message_text(:started, data, _record), do: Map.get(data, :input)
  defp message_text(:model_result, data, _record), do: Map.get(data, :text)
  defp message_text(:tool_result, data, _record), do: Map.get(data, :output)

  defp message_text(type, data, _record) when type in [:input_answered, :approval_answered] do
    Map.get(data, :answer) || Map.get(data, :decision) || inspect(data)
  end

  defp message_text(:waiting, data, record) do
    cond do
      match?(%{prompt: prompt} when is_binary(prompt), record.input_request) ->
        record.input_request.prompt

      match?(%{name: name} when is_binary(name), record.approval) ->
        "Approval required: " <> record.approval.name

      true ->
        Map.get(data, :prompt) || "waiting"
    end
  end

  defp message_text(_type, data, _record), do: Map.get(data, :error) || Map.get(data, :reason)

  defp message_tool(:tool_result, %{call: %{name: name}}), do: name
  defp message_tool(_type, _data), do: nil

  defp message_usage(:model_result, data), do: Map.get(data, :usage)
  defp message_usage(_type, _data), do: nil

  defp agent_of(record), do: record.trace.agent || record.definition.version

  defp duration_ms(record) do
    finish = record.finished_at || record.updated_at
    max(finish - record.started_at, 0)
  end
end
