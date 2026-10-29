defmodule Knotra.ObservabilityTest do
  use ExUnit.Case, async: false

  alias Knotra.Definition

  defmodule Model do
    @behaviour Knotra.Model

    @impl true
    def call(%{input: input}, _opts) do
      {:ok, %Knotra.Reply{text: "echo: " <> input, usage: %{total_tokens: 3}}}
    end
  end

  defmodule GateLoop do
    @behaviour Knotra.Loop

    @impl true
    def init(opts), do: Keyword.fetch!(opts, :owner)

    @impl true
    def next(_view, owner) do
      send(owner, {:gate, self()})

      receive do
        {:return, output} -> {:done, output}
      end
    end
  end

  setup do
    instance = :"knotra_obs_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Knotra,
       name: instance,
       max_executions: 10,
       observability: [max_records: 200, max_events: 200, notify_ms: 0]}
    )

    %{instance: instance}
  end

  test "records agents, models, executions, events, and messages", %{instance: instance} do
    execution =
      run(instance, "hello observability", trace: %{agent: "greeter", conversation_id: "c1"})

    assert {:ok, agents} = Knotra.Observability.agents(instance)
    assert [agent] = agents
    assert agent.id == "observable-v1"
    assert agent.label == "greeter"
    assert agent.model == %{id: "fake:observable", module: inspect(Model)}
    assert agent.executions == 1
    assert agent.completed == 1
    assert agent.running == 0

    assert {:ok, stats} = Knotra.Observability.stats(instance)
    assert stats.executions == 1
    assert stats.completed == 1
    assert stats.agents == 1
    assert stats.models == ["fake:observable"]

    assert {:ok, [summary]} = Knotra.Observability.executions(instance)
    assert summary.id == execution.id
    assert summary.trace.conversation_id == "c1"
    assert summary.trace.agent == "greeter"
    assert summary.event_count >= 4
    assert summary.duration_ms >= 0
    assert summary.timings.turn_count == 1
    assert summary.timings.last_turn_ms >= 0
    assert is_integer(summary.timings.total_ms)

    assert {:ok, detail} = Knotra.Observability.execution(instance, execution.id)

    assert Enum.map(detail.events, & &1.type) == [
             :started,
             :model_started,
             :model_result,
             :completed
           ]

    assert detail.events |> List.first() |> Map.get(:sequence) == 1
    assert detail.output == "echo: hello observability"
    assert detail.timings.turn_count == 1
    assert detail.timings.total_ms >= 0
    assert [turn] = detail.timings.turns
    assert turn.number == 1
    assert turn.duration_ms >= turn.model_ms
    assert summary.timings.last_turn_ms == turn.duration_ms

    assert {:ok, messages} = Knotra.Observability.messages(instance)
    assert Enum.any?(messages, &(&1.kind == :input and &1.text == "hello observability"))

    assert Enum.any?(
             messages,
             &(&1.kind == :assistant and &1.text == "echo: hello observability")
           )

    assert Enum.all?(messages, &(&1.agent == "greeter"))
  end

  test "links parent executions and exposes agent-level connections", %{instance: instance} do
    parent = run(instance, "delegate this", trace: %{agent: "concierge", conversation_id: "flow"})

    child =
      run(instance, "do the work",
        trace: %{agent: "researcher", conversation_id: "flow", parent_id: parent.id}
      )

    assert {:ok, graph} = Knotra.Observability.graph(instance)

    assert Enum.any?(graph.edges, fn edge ->
             edge.from == to_string(parent.id) and edge.to == to_string(child.id) and
               edge.label == "delegates"
           end)

    assert Enum.any?(graph.agent_edges, fn edge ->
             edge.from == "concierge" and edge.to == "researcher" and edge.count == 1 and
               edge.kinds == [:link]
           end)

    [conversation] = graph.conversations
    assert conversation.id == "flow"
    assert Enum.map(conversation.executions, & &1.agent) == ["concierge", "researcher"]
  end

  test "annotates executions after the fact and records explicit links", %{instance: instance} do
    execution = run(instance, "later annotation")

    assert :ok =
             Knotra.Observability.annotate(instance, execution.id, %{
               agent: "annotated",
               conversation_id: "later",
               labels: %{"tenant" => "t1"}
             })

    assert {:ok, detail} = Knotra.Observability.execution(instance, execution.id)
    assert detail.trace.agent == "annotated"
    assert detail.trace.conversation_id == "later"
    assert detail.trace.labels == %{"tenant" => "t1"}

    other = run(instance, "linked")
    assert :ok = Knotra.Observability.link(instance, execution.id, other.id, label: "handoff")

    assert {:ok, graph} = Knotra.Observability.graph(instance)

    assert Enum.any?(graph.links, fn link ->
             link.from == to_string(execution.id) and link.to == to_string(other.id) and
               link.label == "handoff"
           end)
  end

  test "notifies subscribed processes about store changes", %{instance: instance} do
    assert :ok = Knotra.Observability.subscribe(instance)

    _execution = run(instance, "notify me")

    assert_receive {:knotra_observability, ^instance}, 500
  end

  test "rejects malformed trace metadata", %{instance: instance} do
    definition = definition()

    assert {:error, :invalid_configuration} =
             Knotra.start(instance, definition, "bad trace", %{}, trace: %{bogus: true})

    assert {:error, :invalid_trace} = Knotra.Observability.annotate(instance, 1, %{bogus: true})
  end

  test "retains running executions when terminal records exceed the cap" do
    instance = :"knotra_obs_running_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Knotra,
       name: instance,
       max_executions: 5,
       observability: [max_records: 1, max_events: 50, notify_ms: 0]}
    )

    definition = %Definition{
      version: "gated-v1",
      model: {Model, model: "fake:observable"},
      loop: {GateLoop, [owner: self()]}
    }

    assert {:ok, pid} = Knotra.start(instance, definition, "hold", %{})
    assert_receive {:gate, _task}, 500
    running = Knotra.snapshot(pid)

    _terminal = run(instance, "terminal")
    Knotra.Observability.sync(instance)

    assert {:ok, executions} = Knotra.Observability.executions(instance)
    assert [retained] = executions
    assert retained.id == running.id
    assert retained.status == :running

    assert :ok = Knotra.cancel(pid)
  end

  test "retains a bounded number of terminal executions" do
    instance = :"knotra_obs_bounded_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Knotra,
       name: instance,
       max_executions: 10,
       observability: [max_records: 2, max_events: 50, notify_ms: 0]}
    )

    first = run(instance, "one")
    second = run(instance, "two")
    third = run(instance, "three")

    Knotra.Observability.sync(instance)

    assert {:ok, executions} = Knotra.Observability.executions(instance)
    assert length(executions) == 2
    assert Enum.sort(Enum.map(executions, & &1.id)) == Enum.sort([second.id, third.id])
    refute Enum.any?(executions, &(&1.id == first.id))
  end

  defp run(instance, input, opts \\ []) do
    assert {:ok, pid} = Knotra.start(instance, definition(), input, %{}, opts)
    assert %{status: status} = await(pid)
    assert status in [:completed, :failed]
    Knotra.Observability.sync(instance)
    Knotra.snapshot(pid)
  end

  defp await(pid, attempts \\ 200) do
    case Knotra.snapshot(pid) do
      %{status: status} = snapshot when status in [:completed, :failed, :cancelled, :blocked] ->
        snapshot

      _ when attempts == 0 ->
        flunk("execution did not reach a terminal state")

      _ ->
        Process.sleep(10)
        await(pid, attempts - 1)
    end
  end

  defp definition do
    %Definition{version: "observable-v1", model: {Model, model: "fake:observable"}}
  end
end
