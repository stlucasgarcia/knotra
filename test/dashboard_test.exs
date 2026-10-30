if Code.ensure_loaded?(Knotra.Dashboard.Live) do
  defmodule Knotra.DashboardTest.RouterMount do
    @moduledoc false
    def on_mount(:default, _params, _session, socket), do: {:cont, socket}
  end

  # Helpers stay enabled here: the macro must compile under a normal Phoenix
  # router, not only when a host disables helpers.
  defmodule Knotra.DashboardTest.Router do
    @moduledoc false
    use Phoenix.Router, helpers: true

    import Phoenix.LiveView.Router
    import Knotra.Dashboard.Router

    knotra_dashboard("/knotra",
      instance: :unused,
      on_mount: [{Knotra.DashboardTest.RouterMount, :default}]
    )
  end

  defmodule Knotra.DashboardTest do
    use ExUnit.Case, async: false

    alias Knotra.{Dashboard, Definition}
    alias Knotra.Dashboard.Live
    alias Knotra.Swarm.{Agent, Spec}

    test "the router macro compiles with helpers, names the helper, and forwards on_mount" do
      assert [route] =
               Enum.filter(
                 Knotra.DashboardTest.Router.__routes__(),
                 &(&1.plug == Phoenix.LiveView.Plug)
               )

      assert route.path == "/knotra"
      assert route.helper == "knotra_dashboard"

      assert %{
               phoenix_live_view:
                 {Live, :index, _opts,
                  %{extra: %{on_mount: [%{id: {Knotra.DashboardTest.RouterMount, :default}}]}}}
             } = route.metadata
    end

    defmodule Model do
      @behaviour Knotra.Model

      @impl true
      def call(%{input: input}, _opts) do
        {:ok, %Knotra.Reply{text: "echo: " <> input}}
      end
    end

    defmodule ToolModel do
      @behaviour Knotra.Model

      @impl true
      def call(%{exchanges: []}, _opts) do
        {:ok,
         %Knotra.Reply{
           calls: [
             %{id: "call-1", name: "lookup", arguments: %{"query" => "ord-1"}}
           ]
         }}
      end

      def call(%{exchanges: [%{results: [_]}]}, _opts) do
        {:ok, %Knotra.Reply{text: "lookup finished"}}
      end
    end

    defmodule Lookup do
      @behaviour Knotra.Tool

      @impl true
      def definition do
        %{
          name: "lookup",
          description: "Look up an order",
          read_only: true,
          parameters: %{"type" => "object", "properties" => %{}}
        }
      end

      @impl true
      def validate(args), do: {:ok, args}

      @impl true
      def authorize(_args, _scope), do: :ok

      @impl true
      def call(%{"query" => query}, _scope), do: {:ok, "result for " <> query}
    end

    setup do
      instance = :"knotra_dash_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Knotra,
         name: instance,
         max_executions: 10,
         observability: [max_records: 50, max_events: 200, notify_ms: 0]}
      )

      definition = %Definition{version: "dash-v1", model: {Model, model: "fake:dashboard"}}

      assert {:ok, pid} =
               Knotra.start(instance, definition, "hello dashboard", %{},
                 trace: %{agent: "dash-agent", conversation_id: "conv-dash"}
               )

      assert %{status: :completed} = await(pid)
      Knotra.Observability.sync(instance)
      assert {:ok, [execution]} = Knotra.Observability.executions(instance)

      %{instance: instance, execution: execution}
    end

    test "mounts and renders overview, executions, agents, topology, and messages", context do
      assert Dashboard.available?()

      {:ok, socket} = mount(context.instance)

      html = render(socket)
      assert html =~ "Knotra Observability"
      assert html =~ "dash-agent"
      assert html =~ "fake:dashboard"
      assert html =~ "hello dashboard"
      assert html =~ ".knotra"
      refute html =~ "{@css}"

      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "executions"}, socket)
      executions = render(socket)
      assert executions =~ "hello dashboard"
      assert executions =~ "dash-agent"
      assert executions =~ "Last turn"

      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "agents"}, socket)
      agents = render(socket)
      assert agents =~ "Agent definitions"
      assert agents =~ "dash-v1"
      assert agents =~ "fake:dashboard"

      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "topology"}, socket)
      topology = render(socket)
      assert topology =~ "conv-dash"
      assert topology =~ "dash-agent"

      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "messages"}, socket)
      messages = render(socket)
      assert messages =~ "echo: hello dashboard"
      assert messages =~ "hello dashboard"
    end

    test "renders swarms and the coordinator timeline", context do
      plan = fn _goal, _agents ->
        {:ok,
         %{
           agents: [
             %Agent{
               name: "worker",
               prompt: "worker prompt",
               definition: %Definition{
                 version: "swarm-worker",
                 model: {Model, model: "fake"},
                 tools: []
               }
             }
           ],
           tasks: [%{id: "t1", input: "swarm input", agent: "worker", depth: 0}],
           trace: %{
             model: "test-coordinator",
             input: "coordinator input",
             output: "coordinator said hello"
           }
         }}
      end

      spec = %Spec{
        mode: :coordinator,
        goal: "swarm goal",
        agents: [
          %Agent{
            name: "pre",
            definition: %Definition{version: "swarm-pre", model: {Model, model: "fake"}}
          }
        ],
        plan: plan,
        timeout: 5_000
      }

      assert {:ok, result} = Knotra.Swarm.run(context.instance, spec, await_timeout: 5_000)
      Knotra.Observability.sync(context.instance)
      assert {:ok, swarms} = Knotra.Observability.swarms(context.instance)
      swarm = Enum.find(swarms, &(&1.id == result.swarm_id))
      assert swarm.status == :completed

      {:ok, socket} = mount(context.instance)
      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "swarms"}, socket)

      html = render(socket)
      assert html =~ "Swarms"
      assert html =~ "swarm goal"
      assert html =~ "worker"

      {:noreply, socket} =
        Live.handle_event("select_swarm", %{"id" => swarm.id}, socket)

      detail = render(socket)
      assert detail =~ "Coordinator output"
      assert detail =~ "coordinator said hello"
      assert detail =~ "Initial prompt"
      assert detail =~ "worker prompt"
      assert detail =~ "Timeline"
      assert detail =~ "echo: swarm input"
      assert detail =~ "task t1"
    end

    test "opens the execution detail with the model and tool timeline", context do
      {:ok, socket} = mount(context.instance)

      {:noreply, socket} =
        Live.handle_event("select", %{"id" => to_string(context.execution.id)}, socket)

      assert socket.assigns.selected.id == context.execution.id

      detail = render(socket)
      assert detail =~ "Timeline"
      assert detail =~ "assistant"
      assert detail =~ "echo: hello dashboard"
      assert detail =~ "Input"
      assert detail =~ "completed"
      assert detail =~ "dash-v1"
      assert detail =~ "Turn timings"
      assert detail =~ "Run total"
      assert detail =~ "Last turn"

      {:noreply, socket} = Live.handle_event("close", %{}, socket)
      assert socket.assigns.selected == nil
    end

    test "renders tool call and tool result events", context do
      definition = %Definition{
        version: "tool-dash-v1",
        model: {ToolModel, []},
        tools: [Lookup]
      }

      assert {:ok, pid} = Knotra.start(context.instance, definition, "lookup ord-1", %{})
      assert %{status: :completed} = await(pid)
      Knotra.Observability.sync(context.instance)

      execution_id = Knotra.snapshot(pid).id

      {:ok, socket} = mount(context.instance)

      {:noreply, socket} =
        Live.handle_event("select", %{"id" => to_string(execution_id)}, socket)

      html = render(socket)
      assert html =~ "tool call"
      assert html =~ "tool result"
      assert html =~ "lookup"
      assert html =~ "result for ord-1"
      assert html =~ "lookup finished"
    end

    test "filters executions and messages", context do
      {:ok, socket} = mount(context.instance)
      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "executions"}, socket)

      {:noreply, socket} =
        Live.handle_event("filter", %{"status" => "failed", "query" => ""}, socket)

      refute render(socket) =~ "dash-agent"

      {:noreply, socket} =
        Live.handle_event("filter", %{"status" => "all", "query" => "missing-term"}, socket)

      refute render(socket) =~ "dash-agent"

      {:noreply, socket} =
        Live.handle_event("filter", %{"status" => "all", "query" => "hello"}, socket)

      assert render(socket) =~ "dash-agent"

      {:noreply, socket} = Live.handle_event("tab", %{"tab" => "messages"}, socket)

      {:noreply, socket} =
        Live.handle_event("filter", %{"kind" => "tool", "query" => ""}, socket)

      refute render(socket) =~ "echo: hello dashboard"

      {:noreply, socket} =
        Live.handle_event("filter", %{"kind" => "assistant", "query" => ""}, socket)

      assert render(socket) =~ "echo: hello dashboard"
    end

    test "pauses and resumes live updates", context do
      {:ok, socket} = mount(context.instance)

      {:noreply, socket} = Live.handle_event("toggle_pause", %{}, socket)
      assert socket.assigns.paused
      assert render(socket) =~ "Paused"

      {:noreply, socket} = Live.handle_event("toggle_pause", %{}, socket)
      refute socket.assigns.paused
      assert render(socket) =~ "Live"
    end

    test "renders without a configured instance" do
      {:ok, socket} =
        Knotra.Dashboard.Live.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      html = render(socket)
      assert html =~ "No Knotra instance configured"
      assert socket.assigns.error == :missing_instance
    end

    defp mount(instance) do
      Knotra.Dashboard.Live.mount(
        %{},
        %{"knotra_instance" => instance},
        %Phoenix.LiveView.Socket{}
      )
    end

    defp render(socket) do
      socket.assigns
      |> Knotra.Dashboard.Live.render()
      |> Phoenix.LiveViewTest.rendered_to_string()
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
  end
end
