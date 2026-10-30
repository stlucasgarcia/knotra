defmodule Knotra.Observability.TimingTest do
  use ExUnit.Case, async: true

  alias Knotra.Observability.Timing

  test "derives total, per-turn, model, and tool durations" do
    events = [
      event(1, 0, :started, %{input: "work"}),
      event(2, 10, :model_started, %{}),
      event(3, 100, :model_result, %{text: "first", calls: [call()], usage: %{total_tokens: 3}}),
      event(4, 110, :tool_started, %{call: call()}),
      event(5, 160, :tool_result, %{call: call(), output: "ok"}),
      event(6, 170, :model_started, %{}),
      event(7, 270, :model_result, %{text: "done", calls: []}),
      event(8, 280, :completed, %{output: "done"})
    ]

    timings = Timing.summarize(events)

    assert timings.total_ms == 280
    assert timings.turn_count == 2
    assert timings.last_turn_ms == 110
    assert timings.avg_turn_ms == 135
    assert timings.slowest_turn_ms == 160
    assert timings.model_ms == 190
    assert timings.tool_ms == 50
    assert timings.other_ms == 30

    assert [first, second] = timings.turns
    assert first.number == 1
    assert first.started_ms == 10
    assert first.ended_ms == 170
    assert first.duration_ms == 160
    assert first.model_ms == 90
    assert first.tool_ms == 50
    assert first.other_ms == 20
    assert first.tools == 1
    assert first.usage == %{total_tokens: 3}

    assert second.number == 2
    assert second.duration_ms == 110
    assert second.model_ms == 100
    assert second.tool_ms == 0
    assert second.other_ms == 10
  end

  test "an approved tool after a wait still contributes tool time" do
    events = [
      event(1, 0, :model_started, %{}),
      event(2, 20, :tool_started, %{call: call()}),
      event(3, 30, :waiting, %{name: "lookup"}),
      event(4, 140, :tool_result, %{call: call(), output: "ok"}),
      event(5, 150, :completed, %{output: "done"})
    ]

    timings = Timing.summarize(events)

    assert timings.tool_ms == 120
    assert [turn] = timings.turns
    assert turn.tool_ms == 0
    assert turn.ended_ms == 30
  end

  test "a running execution totals up to its newest event" do
    timings =
      Timing.summarize([
        event(1, 0, :started, %{input: "work"}),
        event(2, 10, :model_started, %{}),
        event(3, 100, :model_result, %{text: "still working", calls: []})
      ])

    assert timings.total_ms == 100
    assert timings.turn_count == 1
    assert timings.last_turn_ms == 90
    assert timings.model_ms == 90
  end

  test "a waiting turn ends at the wait instead of spanning the human delay" do
    timings =
      Timing.summarize([
        event(1, 0, :started, %{input: "work"}),
        event(2, 10, :model_started, %{}),
        event(3, 100, :model_result, %{text: "need input", calls: []}),
        event(4, 110, :waiting, %{}),
        event(5, 200, :input_answered, %{answer: "details"}),
        event(6, 210, :model_started, %{}),
        event(7, 300, :model_result, %{text: "done", calls: []}),
        event(8, 310, :completed, %{output: "done"})
      ])

    assert timings.total_ms == 310
    assert [first, second] = timings.turns
    assert first.started_ms == 10
    assert first.ended_ms == 110
    assert first.duration_ms == 100
    assert second.started_ms == 210
    assert second.duration_ms == 100
  end

  test "executions without model turns still report total time" do
    timings = Timing.summarize([event(1, 0, :started, %{}), event(2, 5, :completed, %{})])

    assert timings.total_ms == 5
    assert timings.turn_count == 0
    assert timings.last_turn_ms == 0
    assert timings.model_ms == 0
    assert timings.tool_ms == 0

    assert Timing.summary([event(1, 0, :started, %{})]) == %{
             total_ms: 0,
             turn_count: 0,
             last_turn_ms: 0,
             avg_turn_ms: 0,
             slowest_turn_ms: 0,
             model_ms: 0,
             tool_ms: 0,
             other_ms: 0
           }
  end

  defp event(sequence, elapsed_ms, type, data) do
    %{sequence: sequence, elapsed_ms: elapsed_ms, type: type, data: data}
  end

  defp call, do: %{id: "call-1", name: "lookup", arguments: %{"id" => "r1"}}
end
