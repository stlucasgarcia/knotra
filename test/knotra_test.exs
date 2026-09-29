defmodule KnotraTest do
  use ExUnit.Case, async: true

  alias Knotra.{Definition, Reply}

  defmodule Model do
    @behaviour Knotra.Model
    @impl true
    def call(request, opts) do
      Keyword.fetch!(opts, :respond).(request)
    end
  end

  defmodule Receipt do
    @behaviour Knotra.Tool
    @impl true
    def definition do
      %{
        name: "receipt",
        description: "Read an authorized receipt",
        read_only: true,
        parameters: %{
          "type" => "object",
          "properties" => %{"id" => %{"type" => "string"}},
          "required" => ["id"],
          "additionalProperties" => false
        }
      }
    end

    @impl true
    def validate(%{"id" => id} = args) when is_binary(id) and map_size(args) == 1 do
      {:ok, args}
    end

    def validate(_) do
      {:error, :invalid_arguments}
    end

    @impl true
    def authorize(%{"id" => id}, context) do
      if Map.has_key?(Map.fetch!(context, :receipts), id) do
        :ok
      else
        {:error, :forbidden}
      end
    end

    @impl true
    def call(%{"id" => id}, context) do
      send(Map.fetch!(context, :owner), {:receipt_read, Map.fetch!(context, :tenant), id})
      {:ok, Map.fetch!(Map.fetch!(context, :receipts), id)}
    end
  end

  defmodule MemoryRecorder do
    @moduledoc "Test-only in-memory snapshot store; no durability claim."
    @behaviour Knotra.Observer
    @impl true
    def record(snapshot, {store, recipient}) do
      Agent.update(store, &Map.put(&1, Map.fetch!(snapshot, :id), snapshot))
      send(recipient, {:knotra, snapshot})
      :ok
    end
  end

  defmodule NoModelLoop do
    @behaviour Knotra.Loop
    @impl true
    def init(opts) do
      Keyword.fetch!(opts, :output)
    end

    @impl true
    def next(_view, output) do
      {:done, output}
    end
  end

  defmodule InvalidLoop do
    @behaviour Knotra.Loop
    @impl true
    def init(_) do
      nil
    end

    @impl true
    def next(_, _) do
      {:tool, %{id: "invented", name: "receipt", arguments: %{"id" => "r1"}}, nil}
    end
  end

  defmodule BrokenObserver do
    @behaviour Knotra.Observer
    @impl true
    def record(snapshot, recipient) do
      send(recipient, {:broken_observer, snapshot})
      raise "private credential"
    end
  end

  defmodule FixtureTools do
    @behaviour Knotra.ToolRuntime
    @impl true
    def execute(_call, _tools, _auth, opts), do: Keyword.fetch!(opts, :result)
  end

  setup do
    start_supervised!({Knotra, name: __MODULE__, max_executions: 2})

    %{
      auth: %{
        tenant: "tenant-a",
        receipts: %{"r1" => "Receipt r1: USD 12.00, paid"},
        owner: self()
      }
    }
  end

  defp definition(respond, changes \\ []) do
    struct!(
      %Definition{
        version: "email-v1",
        model: {Model, respond: respond},
        tools: [Receipt],
        observer: {Knotra.Observers.Send, self()}
      },
      changes
    )
  end

  defp call(id \\ "r1"), do: %{id: "call-1", name: "receipt", arguments: %{"id" => id}}

  defp complete(execution) do
    id = Knotra.snapshot(execution).id
    await_terminal(id)
  end

  defp await_terminal(id) do
    receive do
      {:knotra, %{id: ^id, status: status} = snapshot} when status != :running -> snapshot
      {:knotra, %{id: ^id}} -> await_terminal(id)
    after
      2_000 -> flunk("execution did not publish a terminal snapshot")
    end
  end

  test "sanitized email → authorized receipt → proposed reply, with isolated recording", %{
    auth: auth
  } do
    store = start_supervised!({Agent, fn -> %{} end})
    owner = self()

    respond = fn request ->
      send(owner, {:model_request, request})

      case request.exchanges do
        [] -> {:ok, %Reply{calls: [call()], usage: %{input_tokens: 10}}}
        [%{results: [%{output: receipt}]}] -> {:ok, %Reply{text: "Proposed reply: #{receipt}"}}
      end
    end

    agent = definition(respond, observer: {MemoryRecorder, {store, self()}})
    {:ok, execution} = Knotra.start(__MODULE__, agent, "Please confirm receipt r1", auth)
    record = complete(execution)

    assert record.status == :completed
    assert record.output == "Proposed reply: Receipt r1: USD 12.00, paid"
    assert record.counts == %{turns: 2, tools: 1, retries: 0, steps: 4}
    assert_receive {:receipt_read, "tenant-a", "r1"}
    assert_receive {:model_request, request}
    refute Map.has_key?(request, :auth)
    assert Agent.get(store, &Map.fetch!(&1, record.id)) == record
    assert Enum.map(record.events, & &1.sequence) == Enum.to_list(1..length(record.events))
    assert Enum.any?(record.events, &match?(%{type: :model_result, data: %{usage: nil}}, &1))
    refute inspect(record) =~ "respond:"
    assert :ok = Knotra.release(execution)
  end

  test "loop replacement works without model or tool execution", %{auth: auth} do
    agent =
      definition(fn _ -> flunk("model must not run") end,
        loop: {NoModelLoop, output: "Fixed proposal"}
      )

    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth)

    assert %{status: :completed, output: "Fixed proposal", counts: %{turns: 0, tools: 0}} =
             complete(execution)

    refute_receive {:receipt_read, _, _}
  end

  test "unauthorized receipt and model-selected tenant never reach the host read", %{auth: auth} do
    for requested <- [
          call("another-tenant-receipt"),
          put_in(call().arguments["tenant"], "tenant-b")
        ] do
      agent = definition(fn _ -> {:ok, %Reply{calls: [requested]}} end)
      {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth)
      assert %{status: :failed, error: error} = complete(execution)
      assert error in [:forbidden, :invalid_arguments]
      :ok = Knotra.release(execution)
    end

    refute_receive {:receipt_read, _, _}
  end

  test "unknown tools, malformed calls, and duplicate call IDs fail closed", %{auth: auth} do
    replies = [
      %Reply{calls: [%{call() | name: "send_payment"}]},
      %Reply{calls: [%{call() | arguments: "not a map"}]},
      %Reply{calls: [call(), call()]}
    ]

    for reply <- replies do
      {:ok, execution} =
        Knotra.start(__MODULE__, definition(fn _ -> {:ok, reply} end), "Email", auth)

      assert %{status: :failed} = complete(execution)
      :ok = Knotra.release(execution)
    end

    refute_receive {:receipt_read, _, _}
  end

  test "alternate loop cannot execute an unrequested tool", %{auth: auth} do
    agent = definition(fn _ -> flunk("unexpected model") end, loop: {InvalidLoop, []})
    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth)
    assert %{error: :invalid_tool_request} = complete(execution)
    refute_receive {:receipt_read, _, _}
  end

  test "turn, tool and strategy budgets are enforced by the core", %{auth: auth} do
    for {opts, error} <- [
          {[max_turns: 0], :turn_limit},
          {[max_tool_calls: 0], :tool_limit},
          {[max_steps: 0], :step_limit}
        ] do
      {:ok, execution} =
        Knotra.start(
          __MODULE__,
          definition(fn _ -> {:ok, %Reply{calls: [call()]}} end),
          "Email",
          auth,
          opts
        )

      assert %{status: :failed, error: ^error} = complete(execution)
      :ok = Knotra.release(execution)
    end

    refute_receive {:receipt_read, _, _}
  end

  test "transient retries consume the shared retry and model budgets", %{auth: auth} do
    agent = definition(fn _ -> {:retry, :temporarily_unavailable} end)
    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth, max_retries: 2)

    assert %{status: :failed, error: :retries_exhausted, counts: %{turns: 3, retries: 2}} =
             complete(execution)

    assert :ok = Knotra.release(execution)

    {:ok, execution} =
      Knotra.start(__MODULE__, agent, "Email", auth, max_retries: 10, max_turns: 1)

    assert %{error: :turn_limit, counts: %{turns: 1}} = complete(execution)
  end

  test "model failures and plugin exceptions are recorded without exception contents", %{
    auth: auth
  } do
    for respond <- [
          fn _ -> {:error, :provider_unavailable} end,
          fn _ -> raise "secret api key" end
        ] do
      {:ok, execution} = Knotra.start(__MODULE__, definition(respond), "Email", auth)
      record = complete(execution)
      assert record.status == :failed
      assert record.error in [:provider_unavailable, :plugin_exception]
      refute inspect(record) =~ "secret api key"
      :ok = Knotra.release(execution)
    end
  end

  test "cancellation remains responsive while a provider is blocked", %{auth: auth} do
    owner = self()

    agent =
      definition(fn _ ->
        send(owner, {:blocked, self()})

        receive do
          :never -> {:ok, %Reply{text: "late"}}
        end
      end)

    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth)
    assert_receive {:blocked, task}
    monitor = Process.monitor(task)
    assert Knotra.snapshot(execution).status == :running
    assert {:error, :running} = Knotra.release(execution)
    assert :ok = Knotra.cancel(execution)
    assert %{status: :cancelled} = complete(execution)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    assert Knotra.snapshot(execution).output == nil
    assert :ok = Knotra.cancel(execution)
  end

  test "deadline terminates blocked tasks", %{auth: auth} do
    owner = self()

    agent =
      definition(fn _ ->
        send(owner, {:blocked, self()})

        receive do
          :never -> {:ok, %Reply{}}
        end
      end)

    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth, timeout: 200)
    assert_receive {:blocked, task}
    monitor = Process.monitor(task)
    assert %{error: :deadline_exceeded} = complete(execution)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
  end

  test "capacity includes retained records and release frees a slot", %{auth: auth} do
    agent = definition(fn _ -> {:ok, %Reply{text: "Done"}} end)
    {:ok, first} = Knotra.start(__MODULE__, agent, "First", auth)
    {:ok, second} = Knotra.start(__MODULE__, agent, "Second", auth)
    assert complete(first).status == :completed
    assert complete(second).status == :completed
    refute Knotra.snapshot(first).id == Knotra.snapshot(second).id
    assert {:error, :max_children} = Knotra.start(__MODULE__, agent, "Third", auth)
    assert :ok = Knotra.release(first)
    assert {:ok, _} = Knotra.start(__MODULE__, agent, "Third", auth)
  end

  test "isolated evaluation replaces tool effects as well as the model", %{auth: auth} do
    respond = fn
      %{exchanges: []} ->
        {:ok, %Reply{calls: [call()]}}

      %{exchanges: [%{results: [%{output: output}]}]} ->
        {:ok, %Reply{text: "Proposal: #{output}"}}
    end

    agent =
      definition(respond, tool_runtime: {FixtureTools, result: {:ok, "Fixture: USD 12.00 paid"}})

    {:ok, execution} = Knotra.start(__MODULE__, agent, "Sanitized email", auth)

    assert %{status: :completed, output: "Proposal: Fixture: USD 12.00 paid"} =
             complete(execution)

    refute_receive {:receipt_read, _, _}
  end

  test "tool failures and retries obey execution-wide budgets", %{auth: auth} do
    for {result, error, attempts} <- [{:error, :lookup_failed, 1}, {:retry, :busy, 2}] do
      agent =
        definition(fn _ -> {:ok, %Reply{calls: [call()]}} end,
          tool_runtime: {FixtureTools, result: {result, error}}
        )

      {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth, max_retries: 1)
      record = complete(execution)
      assert record.status == :failed
      assert record.error == if(result == :retry, do: :retries_exhausted, else: error)
      assert record.counts.tools == attempts
      :ok = Knotra.release(execution)
    end

    refute_receive {:receipt_read, _, _}
  end

  test "observer exceptions do not crash the coordinator or leak exception text", %{auth: auth} do
    agent =
      definition(fn _ -> flunk("model must not run after recording failure") end,
        observer: {BrokenObserver, self()}
      )

    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth)
    assert_receive {:broken_observer, %{status: :running}}
    assert_receive {:broken_observer, %{status: :failed, error: :plugin_exception}}
    assert Knotra.snapshot(execution).status == :failed
    refute inspect(Knotra.snapshot(execution)) =~ "private credential"
  end

  test "invalid configuration is rejected before a model call", %{auth: auth} do
    agent = definition(fn _ -> flunk("unexpected model call") end)

    assert {:error, :invalid_configuration} =
             Knotra.start(__MODULE__, agent, "Email", auth, timeout: -1)

    assert {:error, :invalid_configuration} =
             Knotra.start(__MODULE__, %{agent | model: {String, []}}, "Email", auth)

    assert {:error, :invalid_configuration} =
             Knotra.start(__MODULE__, agent, "Email", auth, unknown: 1)
  end

  test "killing an execution also kills its in-flight task without automatic replay", %{
    auth: auth
  } do
    owner = self()

    agent =
      definition(fn _ ->
        send(owner, {:blocked, self()})

        receive do
          :never -> {:ok, %Reply{}}
        end
      end)

    {:ok, execution} = Knotra.start(__MODULE__, agent, "Email", auth)
    assert_receive {:blocked, task}
    monitor = Process.monitor(task)
    Process.exit(execution, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    refute_receive {:blocked, _}
  end
end
