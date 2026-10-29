defmodule Knotra.Bench.Observability do
  @moduledoc false
  @executions 50
  @events 800
  @rounds 7
  @snapshot_samples 15

  def run do
    warmup()
    results = for round <- 1..@rounds, do: measure(round)
    ingest = best(for r <- results, do: r.ingest_us)
    snapshot = best(for r <- results, do: r.snapshot_ms)
    detail = best(for r <- results, do: r.detail_ms)

    IO.puts("METRIC ingest_us_per_event=#{Float.round(ingest, 3)}")
    IO.puts("METRIC snapshot_build_ms=#{Float.round(snapshot, 3)}")
    IO.puts("METRIC execution_detail_ms=#{Float.round(detail, 3)}")
    IO.puts("METRIC retained_events=#{@executions * @events}")
  end

  defp warmup do
    measure(0, executions: 4, events: 20)
    :ok
  end

  defp measure(round, opts \\ []) do
    executions = Keyword.get(opts, :executions, @executions)
    events = Keyword.get(opts, :events, @events)
    name = :"knotra_bench_#{round}"
    definition = definition()
    base = 1_700_000_000_000

    {:ok, supervisor} =
      Knotra.start_link(
        name: name,
        max_executions: 1,
        observability: [max_records: 100, max_events: 1_000, notify_ms: 60_000]
      )

    started = System.monotonic_time(:microsecond)

    for id <- 1..executions do
      meta = meta(id, definition, base)

      Knotra.Observability.Store.record(
        name,
        {:register, Map.merge(meta, %{pid: self(), status: :running, counts: counts(0)})}
      )

      for sequence <- 1..events do
        entry = %{
          sequence: sequence,
          elapsed_ms: sequence,
          type: :model_result,
          data: %{text: "message #{sequence}", calls: [], usage: %{total_tokens: sequence}}
        }

        attrs = %{
          status: :running,
          counts: counts(sequence),
          output: nil,
          error: nil,
          observation_error: nil,
          approval: nil,
          input_request: nil
        }

        Knotra.Observability.Store.record(name, {:event, meta, attrs, entry})
      end

      terminal = %{
        status: :completed,
        counts: counts(events),
        output: "done",
        error: nil,
        observation_error: nil,
        approval: nil,
        input_request: nil
      }

      Knotra.Observability.Store.record(
        name,
        {:event, meta, terminal,
         %{
           sequence: events + 1,
           elapsed_ms: events + 1,
           type: :completed,
           data: %{output: "done", error: nil}
         }}
      )
    end

    :ok = Knotra.Observability.sync(name)
    ingest_us = (System.monotonic_time(:microsecond) - started) / (executions * (events + 1))

    gc(name)
    snapshot_ms = sample_ms(fn -> Knotra.Observability.snapshot(name, message_limit: 200) end)

    detail_ms = sample_ms(fn -> Knotra.Observability.execution(name, 1) end)

    Supervisor.stop(supervisor)

    %{ingest_us: ingest_us, snapshot_ms: snapshot_ms, detail_ms: detail_ms}
  end

  defp gc(name) do
    :erlang.garbage_collect()

    case Registry.lookup(name, :observability) do
      [{pid, _}] -> :erlang.garbage_collect(pid)
      _ -> :ok
    end
  end

  defp sample_ms(fun) do
    {us, _} =
      Enum.map_reduce(1..@snapshot_samples, nil, fn _, _ ->
        {microseconds, result} = :timer.tc(fun)
        {microseconds, result}
      end)

    best(us) / 1_000
  end

  defp best([]), do: 0.0
  defp best(values), do: Enum.min(values) * 1.0

  defp meta(id, definition, base) do
    %{
      id: id,
      definition: definition,
      trace: %{
        agent: "agent-#{rem(id, 5)}",
        conversation_id: "conversation-#{rem(id, 10)}",
        parent_id: if(rem(id, 4) == 0, do: id - 1, else: nil),
        labels: %{"tenant" => "bench"}
      },
      input: "input #{id}",
      started_at: base + id
    }
  end

  defp counts(n), do: %{turns: div(n, 10), tools: div(n, 20), retries: 0, steps: n}

  defp definition do
    %{
      version: "bench-v1",
      model: %{id: "fake:bench", module: "Knotra.Bench.Model"},
      tools: ["lookup"],
      loop: "Knotra.Loops.Default",
      tool_runtime: "Knotra.ToolRuntimes.Default",
      observer: "Knotra.Observers.Send"
    }
  end
end

Knotra.Bench.Observability.run()
