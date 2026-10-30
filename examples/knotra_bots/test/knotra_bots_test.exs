defmodule KnotraBotsTest do
  @moduledoc """
  Offline end-to-end tests through the LiveViews. The fake chat model is
  configured for the test environment, so no provider key or network access is
  needed.

  Tests share the Repo and the seeded channels, so every assertion scopes to a
  freshly created channel or agent.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [put_req_header: 3]

  alias KnotraBots.{Agents, Channels, Chat, Swarms}

  @endpoint KnotraBotsWeb.Endpoint

  setup do
    notices =
      Path.expand(
        "../_build/notices-#{System.unique_integer([:positive, :monotonic])}.log",
        __DIR__
      )

    effects =
      Path.expand(
        "../_build/effects-#{System.unique_integer([:positive, :monotonic])}.log",
        __DIR__
      )

    File.rm(notices)
    File.rm(effects)
    Application.put_env(:knotra_bots, :notices_path, notices)
    Application.put_env(:knotra_bots, :effects_path, effects)

    on_exit(fn ->
      File.rm(notices)
      File.rm(effects)

      Application.put_env(
        :knotra_bots,
        :notices_path,
        Path.expand("../_build/notices.log", __DIR__)
      )

      Application.put_env(
        :knotra_bots,
        :effects_path,
        Path.expand("../_build/effects.log", __DIR__)
      )
    end)

    %{notices: notices, effects: effects}
  end

  test "a channel message gets an offline agent reply", %{notices: _notices} do
    agent = agent_fixture(%{"name" => "Echo", "handle" => unique_handle("echo")})
    channel = channel_fixture([agent])

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "hello there")

    message = await_agent_message(channel.id, &(&1.status == "completed"))
    assert message.body == "Echo received: hello there"

    html = await_html(view, &String.contains?(&1, "Echo received: hello there"))
    assert html =~ ~s(data-author="human")
    assert html =~ "hello there"
    assert html =~ "data-status=\"completed\""
  end

  test "a mention routes only to the named agent and no mention uses the default",
       %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Alpha", "handle" => unique_handle("alpha")})
    beta = agent_fixture(%{"name" => "Beta", "handle" => unique_handle("beta")})
    channel = channel_fixture([alpha, beta], default: alpha.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "@#{beta.handle} ping")

    beta_reply =
      await_agent_message(channel.id, &(&1.agent_id == beta.id and &1.status == "completed"))

    assert beta_reply.body =~ "Beta received:"
    refute Enum.any?(agent_messages(channel.id), &(&1.agent_id == alpha.id))

    submit_message(view, "hello default")

    alpha_reply =
      await_agent_message(channel.id, &(&1.agent_id == alpha.id and &1.status == "completed"))

    assert alpha_reply.body =~ "Alpha received: hello default"
  end

  test "a /swarm debate runs over the channel agents and posts the outcome",
       %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Swarm Alpha", "handle" => unique_handle("swarm-alpha")})
    beta = agent_fixture(%{"name" => "Swarm Beta", "handle" => unique_handle("swarm-beta")})
    channel = channel_fixture([alpha, beta], default: alpha.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "/swarm debate compare the two plans")

    note = await_note(channel.id, &(&1.status in ["completed", "failed"]))
    assert note.status == "completed"
    assert note.body =~ "Swarm (debate) completed"
    assert note.body =~ "received: compare the two plans"
    assert note.body =~ "by Swarm Alpha: ok"
    assert note.body =~ "by Swarm Beta: ok"

    html = await_html(view, &String.contains?(&1, "Swarm (debate) completed"))
    assert html =~ "Swarm Alpha"
  end

  test "a /swarm fanout splits the goal into one task per part", %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Fan Alpha", "handle" => unique_handle("fan-alpha")})
    beta = agent_fixture(%{"name" => "Fan Beta", "handle" => unique_handle("fan-beta")})
    channel = channel_fixture([alpha, beta], default: alpha.id)

    assert {:ok, human} = Chat.post(channel.id, "/swarm fanout plan the launch, list the risks")
    assert human.body =~ "/swarm fanout"

    note = await_note(channel.id, &(&1.status in ["completed", "failed"]))
    assert note.status == "completed"
    assert note.body =~ "Swarm (fanout) completed"
    assert note.body =~ "task-1:"
    assert note.body =~ "task-2:"
    assert note.body =~ "received: plan the launch"
    assert note.body =~ "received: list the risks"
    assert note.body =~ "by Fan Alpha: ok"
    assert note.body =~ "by Fan Beta: ok"
  end

  test "a /swarm board message posts a completed note without agent replies",
       %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Board Alpha", "handle" => unique_handle("board-alpha")})
    channel = channel_fixture([alpha], default: alpha.id)

    assert {:ok, _human} = Chat.post(channel.id, "/swarm board draft the summary")

    note = await_note(channel.id, &(&1.status in ["completed", "failed"]))
    assert note.status == "completed"
    assert note.body =~ "Swarm (board) completed"
    assert note.body =~ "by Board Alpha: ok"
    assert agent_messages(channel.id) == []
  end

  test "a /swarm message without a goal is rejected before any note is stored",
       %{notices: _notices} do
    agent = agent_fixture(%{"name" => "Empty Goal", "handle" => unique_handle("empty-goal")})
    channel = channel_fixture([agent], default: agent.id)

    assert {:error, :empty_swarm_goal} = Chat.post(channel.id, "/swarm debate")
    assert Chat.messages(channel.id) == []
  end

  test "/swarm page runs a debate over the selected channel's agents",
       %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Page Alpha", "handle" => unique_handle("page-alpha")})
    beta = agent_fixture(%{"name" => "Page Beta", "handle" => unique_handle("page-beta")})
    channel = channel_fixture([alpha, beta], default: alpha.id)

    {:ok, view, html} = live(build_conn(), "/swarm")

    assert html =~ "Swarms"
    assert html =~ ~s(href="/swarm")

    # Every mode is explained before the first run.
    assert html =~ "Every agent answers the same goal independently"
    assert html =~ "The goal splits into comma-separated parts"
    assert html =~ "Members claim parts from a shared board"

    view
    |> element("#swarm-form")
    |> render_change(%{
      "channel_id" => channel.id,
      "mode" => "debate",
      "goal" => "compare the two plans"
    })

    view |> element("#swarm-form") |> render_submit()

    html =
      await_html(view, &String.contains?(&1, ~s(data-testid="swarm-result")), 10_000)

    assert html =~ "Swarm completed"
    assert html =~ "Page Alpha"
    assert html =~ "Page Beta"
    assert html =~ "received: compare the two plans"
    assert html =~ "Conversation"
    assert html =~ "swarm-"
    assert html =~ "Turns"
  end

  test "/swarm page fan-out lists one row per comma-separated part", %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Fanned Alpha", "handle" => unique_handle("fanned-alpha")})
    beta = agent_fixture(%{"name" => "Fanned Beta", "handle" => unique_handle("fanned-beta")})
    channel = channel_fixture([alpha, beta], default: alpha.id)

    {:ok, view, _html} = live(build_conn(), "/swarm")

    view
    |> element("#swarm-form")
    |> render_change(%{
      "channel_id" => channel.id,
      "mode" => "fanout",
      "goal" => "plan the launch, list the risks"
    })

    view |> element("#swarm-form") |> render_submit()

    html =
      await_html(view, &String.contains?(&1, ~s(data-testid="swarm-result")), 10_000)

    assert html =~ "Swarm completed"
    assert html =~ "task-1"
    assert html =~ "task-2"
    assert html =~ "received: plan the launch"
    assert html =~ "received: list the risks"
  end

  test "/swarm page requires a goal", %{notices: _notices} do
    agent = agent_fixture(%{"name" => "No Goal", "handle" => unique_handle("no-goal")})
    _channel = channel_fixture([agent])

    {:ok, view, _html} = live(build_conn(), "/swarm")

    view |> element("#swarm-form") |> render_submit()

    assert render(view) =~ "Write a goal for the swarm."
  end

  test "/swarm members authorize read-only tools with the host scope",
       %{notices: _notices} do
    orders = Agents.get!("orders")
    channel = channel_fixture([orders])

    {:ok, view, _html} = live(build_conn(), "/swarm")

    view
    |> element("#swarm-form")
    |> render_change(%{
      "channel_id" => channel.id,
      "mode" => "fanout",
      "goal" => "look up order ord-3"
    })

    view |> element("#swarm-form") |> render_submit()

    html = await_html(view, &String.contains?(&1, ~s(data-testid="swarm-result")), 10_000)

    assert html =~ "Swarm completed"
    assert html =~ "Order ord-3 delivered 12 days ago"
    refute html =~ "plugin_exception"
  end

  test "typing @ lists channel agents and picking one inserts the handle",
       %{notices: _notices} do
    alpha = agent_fixture(%{"name" => "Picker Alpha", "handle" => unique_handle("picker-alpha")})
    beta = agent_fixture(%{"name" => "Picker Beta", "handle" => unique_handle("picker-beta")})

    outsider =
      agent_fixture(%{"name" => "Picker Outsider", "handle" => unique_handle("picker-outsider")})

    channel = channel_fixture([alpha, beta], default: alpha.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    view |> form("#composer", %{"message" => "@"}) |> render_change()

    html = render(view)
    assert html =~ ~s(data-testid="mention-menu")
    assert html =~ ~s(aria-controls="mention-list")
    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(aria-activedescendant="mention-option-#{alpha.handle}")

    menu = view |> element(~s([data-testid="mention-menu"])) |> render()
    assert menu =~ "@#{alpha.handle}"
    assert menu =~ "@#{beta.handle}"
    assert menu =~ ~s(class="mention-option is-active")
    assert menu =~ ~s(aria-selected="true")
    refute menu =~ "@#{outsider.handle}"

    view
    |> element("#composer-input")
    |> render_hook("dismiss_mentions", %{})

    html = render(view)
    refute html =~ ~s(data-testid="mention-menu")
    assert html =~ ~s(aria-expanded="false")
    refute html =~ "aria-activedescendant"

    send(view.pid, :refresh)
    refute render(view) =~ ~s(data-testid="mention-menu")

    prefix = String.slice(beta.handle, 0, String.length("picker-beta-"))

    view |> form("#composer", %{"message" => "@" <> prefix}) |> render_change()

    menu = view |> element(~s([data-testid="mention-menu"])) |> render()
    assert menu =~ "@#{beta.handle}"
    refute menu =~ "@#{alpha.handle}"

    view
    |> element(~s([data-testid="mention-option-#{beta.handle}"]))
    |> render_click()

    html = render(view)
    refute html =~ ~s(data-testid="mention-menu")
    assert html =~ ~s(data-draft="@#{beta.handle} ")

    view |> form("#composer") |> render_submit()

    reply =
      await_agent_message(
        channel.id,
        &(&1.agent_id == beta.id and &1.status == "completed")
      )

    assert reply.body =~ "Picker Beta received:"
    refute Enum.any?(agent_messages(channel.id), &(&1.agent_id == alpha.id))
  end

  test "the observability dashboard exposes agents, models, conversations, and messages",
       %{notices: _notices} do
    agent = agent_fixture(%{"name" => "Observable", "handle" => unique_handle("observable")})
    channel = channel_fixture([agent])

    {:ok, chat, _html} = live(build_conn(), "/channels/#{channel.id}")
    submit_message(chat, "observability check")

    message =
      await_agent_message(
        channel.id,
        &(&1.agent_id == agent.id and &1.status == "completed")
      )

    assert message.body =~ "Observable received: observability check"

    Knotra.Observability.sync(KnotraBots.Instance)
    assert {:ok, executions} = Knotra.Observability.executions(KnotraBots.Instance)
    assert Enum.any?(executions, &(&1.id == message.execution_id))
    assert is_binary(message.execution_id)

    {:ok, dashboard, html} = live(build_conn(), "/observability")

    assert html =~ "Knotra Observability"
    assert html =~ "Observable"
    assert html =~ "ChatFake"
    assert html =~ "observability check"

    dashboard |> element(~s(button.k-tab[phx-value-tab=\"messages\"])) |> render_click()
    messages = render(dashboard)
    assert messages =~ "Observable received: observability check"
    assert messages =~ "observability check"

    dashboard |> element(~s(button.k-tab[phx-value-tab=\"topology\"])) |> render_click()
    topology = render(dashboard)
    assert topology =~ "Conversations"
    assert topology =~ "Observable"
    assert topology =~ to_string(message.root_id)

    dashboard |> element(~s(button.k-tab[phx-value-tab=\"executions\"])) |> render_click()

    dashboard
    |> element(~s([phx-value-id="#{message.execution_id}"]))
    |> render_click()

    detail = render(dashboard)
    assert detail =~ "Timeline"
    assert detail =~ "Observable received: observability check"
    assert detail =~ "ChatFake"
    assert detail =~ "Turn timings"
    assert detail =~ "Run total"
  end

  test "a concierge handoff becomes an order lookup that runs without a human gate",
       %{notices: _notices} do
    concierge = Agents.get!("concierge")
    orders = Agents.get!("orders")
    channel = channel_fixture([concierge, orders], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "can you check order ord-1?")

    first =
      await_agent_message(
        channel.id,
        &(&1.agent_id == concierge.id and &1.status == "completed")
      )

    assert first.body =~ "@orders"

    research = await_agent_message(channel.id, &(&1.agent_id == orders.id))
    assert research.hop == 1

    done =
      await_agent_message(
        channel.id,
        &(&1.agent_id == orders.id and &1.status == "completed")
      )

    assert done.body =~ "Order ord-1 shipped"

    assert Enum.any?(
             Chat.snapshot(done).events,
             &(&1.type == :approval_answered and &1.responder_id == "policy:read-only")
           )

    html = await_html(view, &String.contains?(&1, "Order ord-1 shipped"))
    refute html =~ ~s(data-testid="approval")

    Knotra.Observability.sync(KnotraBots.Instance)
    assert {:ok, graph} = Knotra.Observability.graph(KnotraBots.Instance)

    assert Enum.any?(graph.agent_edges, fn edge ->
             edge.from == "Concierge" and edge.to == "Order Desk"
           end)

    assert Enum.any?(graph.conversations, fn conversation ->
             Enum.map(conversation.executions, & &1.agent) == ["Concierge", "Order Desk"]
           end)
  end

  test "approving notify writes exactly one fake notice", %{notices: notices} do
    concierge = Agents.get!("concierge")
    channel = channel_fixture([concierge], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "notify ops that order ord-1 shipped")
    message = await_agent_message(channel.id, &(&1.status == "waiting"))

    await_html(view, &String.contains?(&1, ~s(data-testid="approval")))

    view
    |> element(~s(button[phx-value-id="#{message.id}"][phx-value-decision="approve"]))
    |> render_click()

    done = await_agent_message(channel.id, &(&1.status == "completed"))
    assert done.body =~ "notice queued: ops"
    assert notice_lines(notices) == ["ops"]
  end

  test "the observability dashboard shows the coordinator plan and merged timeline",
       %{notices: _notices, effects: _effects} do
    assert {:error, {:incomplete, result}} =
             Swarms.run(Agents.list(), :coordinator, "Plan the refund and restock backlog")

    Knotra.Observability.sync(KnotraBots.Instance)

    {:ok, dashboard, _html} = live(build_conn(), "/observability")

    dashboard
    |> element(~s(button.k-tab[phx-value-tab="swarms"]))
    |> render_click()

    tab = render(dashboard)
    assert tab =~ "Swarms"
    assert tab =~ "Refund Specialist"

    dashboard
    |> element(~s([phx-value-id="#{result.swarm_id}"]))
    |> render_click()

    detail = render(dashboard)
    assert detail =~ "Coordinator output"
    assert detail =~ "Initial prompt"
    assert detail =~ "Escalations"
    assert detail =~ "refund_over_limit"
    assert detail =~ "Timeline"
    assert detail =~ "Refund Specialist"
    assert detail =~ "Stock Specialist"
  end

  test "rejecting notify records rejection and writes no notice", %{notices: notices} do
    concierge = Agents.get!("concierge")
    channel = channel_fixture([concierge], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "notify ops that order ord-1 shipped")
    message = await_agent_message(channel.id, &(&1.status == "waiting"))
    await_html(view, &String.contains?(&1, ~s(data-testid="approval")))

    view
    |> element(~s(button[phx-value-id="#{message.id}"][phx-value-decision="reject"]))
    |> render_click()

    rejected = await_agent_message(channel.id, &(&1.status == "rejected"))
    assert rejected.body == "Approval rejected."
    assert notice_lines(notices) == []
  end

  test "coordinator normalization ignores model-provided depth noise" do
    plan = %{
      "agents" => [],
      "tasks" => [
        %{"id" => "a", "input" => "one", "agent" => "Concierge", "depth" => 99},
        %{"id" => "b", "input" => "two", "agent" => "Concierge", "depth" => nil},
        %{"id" => "c", "input" => "three", "agent" => "Concierge", "depth" => "2"},
        %{"id" => "d", "input" => "four", "agent" => "Concierge"}
      ]
    }

    assert {:ok, %{agents: [], tasks: tasks}} =
             Swarms.normalize_coordinator_plan(plan, Agents.list())

    assert Enum.map(tasks, & &1.id) == ["a", "b", "c", "d"]
    assert Enum.map(tasks, & &1.depth) == [0, 0, 0, 0]
    assert {:error, :invalid_plan} = Swarms.normalize_coordinator_plan(%{}, Agents.list())

    assert {:error, :non_demo_plan} =
             Swarms.validate_demo_plan(%{agents: [], tasks: []})

    assert {:ok, plan} =
             Swarms.normalize_coordinator_plan(
               KnotraBots.Models.CoordinatorFake.plan(),
               Agents.list()
             )

    assert :ok = Swarms.validate_demo_plan(plan)
  end

  test "/swarm coordinator result shows created agents, tools, and prompts",
       %{notices: _notices, effects: _effects} do
    {:ok, view, _html} = live(build_conn(), "/swarm")

    view
    |> element(~s([data-testid="scenario-coordinator-plan"] button))
    |> render_click()

    view |> element("#swarm-form") |> render_submit()

    html = await_html(view, &String.contains?(&1, ~s(data-testid="coordinator-plan")), 10_000)

    assert html =~ "Refund Specialist"
    assert html =~ "Stock Specialist"
    assert html =~ "You review refunds"
    assert html =~ "Full prompt"
    assert html =~ "order_lookup"
    assert html =~ "swarm-refund-specialist-v1"
    assert html =~ "Escalated writes"
    assert html =~ "refund-in-policy"
    assert html =~ "Iteration"
  end

  test "a coordinator creates specialists and applies the write policy",
       %{notices: notices, effects: effects} do
    assert {:error, {:incomplete, result}} =
             Swarms.run(Agents.list(), :coordinator, "Plan the refund and restock backlog")

    assert "Refund Specialist" in result.agents
    assert "Stock Specialist" in result.agents

    refund = Enum.find(result.agent_details, &(&1.name == "Refund Specialist"))
    assert refund.created
    assert refund.prompt =~ "refund"
    assert "refund" in refund.tools
    assert refund.version == "swarm-refund-specialist-v1"

    stock = Enum.find(result.agent_details, &(&1.name == "Stock Specialist"))
    assert stock.created
    assert stock.prompt =~ "stock"
    assert "restock" in stock.tools

    concierge = Enum.find(result.agent_details, &(&1.name == "Concierge"))
    refute concierge.created

    assert length(result.escalations) == 1

    escalation = hd(result.escalations)
    assert escalation.agent == "Refund Specialist"
    assert escalation.tool == "refund"
    assert escalation.arguments == %{"order" => "ord-3", "reason" => "it arrived late"}
    assert escalation.reason == :refund_over_limit

    assert Enum.find(result.tasks, &(&1.id == "refund-in-policy")).status == :completed
    assert Enum.find(result.tasks, &(&1.id == "restock")).status == :completed
    assert Enum.find(result.tasks, &(&1.id == "notify")).status == :completed

    assert Enum.sort(effect_lines(effects)) == [
             "refund ord-5 $40.00 · it arrived late",
             "restock sku-tee-01 +24"
           ]

    assert notice_lines(notices) == ["ops"]

    Knotra.Observability.sync(KnotraBots.Instance)
    assert {:ok, swarms} = Knotra.Observability.swarms(KnotraBots.Instance)
    summary = Enum.find(swarms, &(&1.id == result.swarm_id))
    assert summary.mode == :coordinator
    assert summary.created_agents == ["Refund Specialist", "Stock Specialist"]
    assert summary.escalations == 1

    assert {:ok, detail} = Knotra.Observability.swarm(KnotraBots.Instance, result.swarm_id)
    assert detail.swarm.planner.output =~ "Refund Specialist"
    assert Enum.any?(detail.timeline, &(&1.source == "coordinator" and &1.type == :planned))
    assert Enum.any?(detail.timeline, &(&1.source == "Refund Specialist"))
    assert Enum.any?(detail.timeline, &(&1.type == :escalation))
    assert Enum.any?(detail.timeline, &(&1.type == :finished))
  end

  test "the default chat opens the seeded e-commerce storefront with a guided tour",
       %{notices: _notices} do
    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "storefront-ops"
    assert html =~ "Guided tour"
    assert html =~ "can you check order ord-3?"
    assert html =~ "@returns proposes; approve to write"
    assert html =~ "@inventory"
    assert html =~ "Swarms"
  end

  test "the order desk reads mocked orders and returns checks the policy",
       %{notices: _notices} do
    orders = Agents.get!("orders")
    returns = Agents.get!("returns")
    channel = channel_fixture([orders, returns], default: orders.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "check order ord-3")

    order_reply =
      await_agent_message(
        channel.id,
        &(&1.agent_id == orders.id and &1.status == "completed")
      )

    assert order_reply.body =~ "Order ord-3 delivered 12 days ago"
    assert order_reply.body =~ "Maya Chen"
    assert order_reply.body =~ "$68.00"

    submit_message(view, "@#{returns.handle} is ord-3 eligible for a return?")

    return_reply =
      await_agent_message(
        channel.id,
        &(&1.agent_id == returns.id and &1.status == "completed")
      )

    assert return_reply.body =~ "return-eligible"
    assert return_reply.body =~ "18 days left"
    refute return_reply.body =~ "plugin_exception"
  end

  test "the concierge routes a customer profile question to the order desk",
       %{notices: _notices} do
    concierge = Agents.get!("concierge")
    orders = Agents.get!("orders")
    channel = channel_fixture([concierge, orders], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "who is maya chen?")

    first =
      await_agent_message(
        channel.id,
        &(&1.agent_id == concierge.id and &1.status == "completed")
      )

    assert first.body =~ "@orders"

    profile =
      await_agent_message(
        channel.id,
        &(&1.agent_id == orders.id and &1.status == "completed")
      )

    assert profile.body =~ "Maya Chen"
    assert profile.body =~ "LTV $1,840.00"
    assert profile.body =~ "VIP"
  end

  test "inventory lists the low and out-of-stock SKUs", %{notices: _notices} do
    inventory = Agents.get!("inventory")
    channel = channel_fixture([inventory], default: inventory.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "what is low on stock?")

    reply =
      await_agent_message(
        channel.id,
        &(&1.agent_id == inventory.id and &1.status == "completed")
      )

    assert reply.body =~ "sku-tee-01"
    assert reply.body =~ "LOW"
    assert reply.body =~ "sku-mug-03"
    assert reply.body =~ "OUT OF STOCK"
  end

  test "approving a refund writes one effects-ledger line", %{notices: _notices, effects: effects} do
    returns = Agents.get!("returns")
    channel = channel_fixture([returns], default: returns.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "refund ord-3 because it arrived late")
    message = await_agent_message(channel.id, &(&1.status == "waiting"))
    await_html(view, &String.contains?(&1, ~s(data-testid="approval")))

    view
    |> element(~s(button[phx-value-id="#{message.id}"][phx-value-decision="approve"]))
    |> render_click()

    done = await_agent_message(channel.id, &(&1.status == "completed"))
    assert done.body =~ "Refund of $68.00 for ord-3 queued"
    assert effect_lines(effects) == ["refund ord-3 $68.00 · it arrived late"]
  end

  test "approving a restock writes one effects-ledger line", %{
    notices: _notices,
    effects: effects
  } do
    inventory = Agents.get!("inventory")
    channel = channel_fixture([inventory], default: inventory.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "restock sku-tee-01")
    message = await_agent_message(channel.id, &(&1.status == "waiting"))
    await_html(view, &String.contains?(&1, ~s(data-testid="approval")))

    view
    |> element(~s(button[phx-value-id="#{message.id}"][phx-value-decision="approve"]))
    |> render_click()

    done = await_agent_message(channel.id, &(&1.status == "completed"))
    assert done.body =~ "Restock request: sku-tee-01 Everyday Tee +24"
    assert effect_lines(effects) == ["restock sku-tee-01 +24"]
  end

  test "a refund of an ineligible order is rejected before any approval",
       %{notices: _notices, effects: effects} do
    returns = Agents.get!("returns")
    channel = channel_fixture([returns], default: returns.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "refund ord-7 because it is old")

    failed = await_agent_message(channel.id, &(&1.status in ["failed", "blocked"]))
    assert failed.status in ["failed", "blocked"]
    assert effect_lines(effects) == []
  end

  test "/swarm page loads an e-commerce scenario into the form", %{notices: _notices} do
    {:ok, view, _html} = live(build_conn(), "/swarm")

    assert render(view) =~ "Late-delivery recovery"
    assert render(view) =~ "Order backlog"

    view
    |> element(~s([data-testid="scenario-retention-debate"] button))
    |> render_click()

    form = view |> element("#swarm-form textarea") |> render()
    assert form =~ "A gold customer"
    assert form =~ "Defend one."
  end

  test "a clarification is answered inside the agent message", %{notices: _notices} do
    concierge = Agents.get!("concierge")
    channel = channel_fixture([concierge], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "please clarify the request")
    question = await_agent_message(channel.id, &(&1.status == "waiting"))

    html = await_html(view, &String.contains?(&1, ~s(data-testid="input-request")))
    assert html =~ "What details should I include?"

    view
    |> form("#answer-#{question.id}", %{"answer" => "include the order id"})
    |> render_submit()

    done = await_agent_message(channel.id, &(&1.status == "completed"))
    assert done.body =~ "include the order id"
  end

  test "a pending approval survives a Knotra instance restart", %{notices: notices} do
    concierge = Agents.get!("concierge")
    channel = channel_fixture([concierge], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")
    submit_message(view, "notify ops that order ord-1 shipped")
    message = await_agent_message(channel.id, &(&1.status == "waiting"))
    await_html(view, &String.contains?(&1, ~s(data-testid="approval")))

    :ok = KnotraBots.stop_instance()
    refute Process.whereis(KnotraBots.Instance)
    {:ok, _pid} = KnotraBots.start_instance()

    {:ok, view2, _html} = live(build_conn(), "/channels/#{channel.id}")
    await_html(view2, &String.contains?(&1, ~s(data-testid="approval")))

    view2
    |> element(~s(button[phx-value-id="#{message.id}"][phx-value-decision="approve"]))
    |> render_click()

    done = await_agent_message(channel.id, &(&1.status == "completed"))
    assert done.body =~ "notice queued: ops"
    assert notice_lines(notices) == ["ops"]
  end

  test "a handoff chain stops after one hop", %{notices: _notices} do
    alpha =
      agent_fixture(%{
        "name" => "Chain Alpha",
        "handle" => unique_handle("chain-alpha"),
        "system_prompt" => "For order questions, hand off to PLACEHOLDER."
      })

    beta =
      agent_fixture(%{
        "name" => "Chain Beta",
        "handle" => unique_handle("chain-beta"),
        "system_prompt" => "For order questions, hand off to PLACEHOLDER."
      })

    alpha =
      Agents.update!(alpha, %{
        "system_prompt" => String.replace(alpha.system_prompt, "PLACEHOLDER", "@#{beta.handle}")
      })

    beta =
      Agents.update!(beta, %{
        "system_prompt" => String.replace(beta.system_prompt, "PLACEHOLDER", "@#{alpha.handle}")
      })

    channel = channel_fixture([alpha, beta], default: alpha.id)
    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "order status please")

    await_agent_message(channel.id, &(&1.agent_id == alpha.id and &1.status == "completed"))
    await_agent_message(channel.id, &(&1.agent_id == beta.id and &1.status == "completed"))

    Process.sleep(400)

    messages = agent_messages(channel.id)
    assert length(messages) == 2
    assert Enum.map(messages, & &1.hop) == [0, 1]
  end

  test "an edit made from a stale revision is rejected", %{notices: _notices} do
    agent = agent_fixture(%{"system_prompt" => "one"})
    stale = Agents.get!(agent.id)

    assert {:ok, updated} = Agents.update(agent, %{"system_prompt" => "two"})
    assert updated.revision == agent.revision + 1

    assert {:error, :stale} = Agents.update(stale, %{"system_prompt" => "three"})
    assert Agents.get!(agent.id).system_prompt == "two"
  end

  test "a queued reply freezes its input and definition", %{notices: _notices} do
    agent = agent_fixture(%{"name" => "Frozen", "handle" => unique_handle("frozen")})
    channel = channel_fixture([agent])

    assert {:ok, _human} = Chat.post(channel.id, "hello frozen")
    [reply] = agent_messages(channel.id)

    assert reply.input =~ "Human: hello frozen"
    assert reply.definition_version =~ "r#{agent.revision}"

    assert {:ok, _agent} = Agents.update(agent, %{"system_prompt" => "changed after queueing"})

    assert Chat.messages(channel.id)
           |> Enum.find(&(&1.id == reply.id))
           |> Map.fetch!(:input) == reply.input
  end

  test "the dashboard rejects non-loopback requests without a token", %{notices: _notices} do
    conn =
      build_conn()
      |> put_req_header("accept", "text/html")
      |> Map.put(:remote_ip, {10, 0, 0, 1})

    assert %{status: 404} = get(conn, "/observability")

    Application.put_env(:knotra_bots, :dashboard_token, "dashboard-secret")
    on_exit(fn -> Application.put_env(:knotra_bots, :dashboard_token, nil) end)

    assert %{status: 200} = get(conn, "/observability?token=dashboard-secret")
    assert %{status: 404} = get(conn, "/observability?token=wrong")
  end

  test "agents can be created, edited, and deleted only when unreferenced", %{notices: _notices} do
    {:ok, view, _html} = live(build_conn(), "/agents")

    name = "Helper #{System.unique_integer([:positive])}"
    handle = unique_handle("helper")

    render_submit(
      form(view, "#new-agent", %{
        "name" => name,
        "handle" => handle,
        "model" => "fake",
        "system_prompt" => "You are terse.",
        "tools" => ["order_lookup"]
      })
    )

    assert render(view) =~ name
    agent = Agents.list() |> Enum.find(&(&1.name == name))
    assert agent.handle == handle
    assert Agents.tool_modules(agent) == [KnotraBots.Tools.OrderLookup]

    auto_name = "Auto Handle #{System.unique_integer([:positive])}"

    render_submit(
      form(view, "#new-agent", %{
        "name" => auto_name,
        "handle" => "",
        "model" => "fake",
        "system_prompt" => "",
        "tools" => []
      })
    )

    auto = Agents.list() |> Enum.find(&(&1.name == auto_name))
    assert auto.handle == KnotraBots.Agent.slug(auto_name)

    render_submit(
      form(view, "#agent-" <> agent.id, %{
        "name" => agent.name <> " v2",
        "handle" => agent.handle,
        "model" => "fake",
        "system_prompt" => "You are terse.",
        "tools" => ["order_lookup"]
      })
    )

    edited = Agents.get!(agent.id)
    assert edited.name == agent.name <> " v2"
    assert edited.revision == agent.revision + 1

    _channel = channel_fixture([edited])

    render_click(view, "delete", %{"id" => edited.id})
    assert render(view) =~ "a channel references it"
    assert Agents.get(edited.id)

    lone = agent_fixture(%{})
    render_click(view, "delete", %{"id" => lone.id})
    assert Agents.get(lone.id) == nil
  end

  test "a channel can be created with a selected agent", %{notices: _notices} do
    agent = agent_fixture(%{})
    name = "Team #{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(build_conn(), "/channels")

    render_submit(
      form(view, "#new-channel", %{
        "name" => name,
        "topic" => "talk",
        "agent_ids" => [agent.id]
      })
    )

    channel = Channels.list() |> Enum.find(&(&1.name == name))
    assert channel
    assert Enum.map(Channels.agents(channel.id), & &1.id) == [agent.id]
    assert channel.default_agent_id == agent.id
  end

  test "an agent whose model has no key fails visibly instead of starting", %{notices: _notices} do
    previous_google = System.get_env("GOOGLE_API_KEY")
    previous_gemini = System.get_env("GEMINI_API_KEY")

    on_exit(fn ->
      restore_env("GOOGLE_API_KEY", previous_google)
      restore_env("GEMINI_API_KEY", previous_gemini)
    end)

    System.delete_env("GOOGLE_API_KEY")
    System.delete_env("GEMINI_API_KEY")

    agent =
      agent_fixture(%{
        "name" => "No Key",
        "handle" => unique_handle("no-key"),
        "model" => "google:gemini-2.5-flash"
      })

    channel = channel_fixture([agent])
    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "hello")

    failed = await_agent_message(channel.id, &(&1.status == "failed"))
    assert failed.body =~ "Model not ready"
  end

  test "Gemini 2.5 options reserve the output budget for text" do
    opts = KnotraBots.model_options("google:gemini-2.5-flash", "be brief")

    assert opts[:max_tokens] == 2048
    assert opts[:google_thinking_budget] == 0

    refute Keyword.has_key?(
             KnotraBots.model_options("openai:gpt-4o-mini", ""),
             :google_thinking_budget
           )
  end

  defp agent_fixture(attrs) do
    n = System.unique_integer([:positive])

    defaults = %{
      "name" => "Agent #{n}",
      "handle" => "agent-#{n}",
      "model" => "fake",
      "tools" => "",
      "system_prompt" => ""
    }

    Agents.create!(Map.merge(defaults, attrs))
  end

  defp channel_fixture(agents, opts \\ []) do
    n = System.unique_integer([:positive])
    default = Keyword.get(opts, :default) || hd(agents).id

    {:ok, channel} =
      Channels.create(%{
        "name" => "Channel #{n}",
        "topic" => "test channel",
        "agent_ids" => Enum.map(agents, & &1.id),
        "default_agent_id" => default
      })

    channel
  end

  defp unique_handle(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp submit_message(view, text) do
    view |> form("#composer", %{"message" => text}) |> render_submit()
  end

  defp agent_messages(channel_id) do
    Chat.messages(channel_id)
    |> Enum.filter(&(&1.author_type == "agent"))
  end

  defp await_note(channel_id, fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_note(channel_id, fun, deadline)
  end

  defp do_await_note(channel_id, fun, deadline) do
    match =
      Enum.find(Chat.messages(channel_id), fn message ->
        message.author_type == "system" and fun.(message)
      end)

    cond do
      match ->
        match

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for a swarm note in #{channel_id}")

      true ->
        Process.sleep(25)
        do_await_note(channel_id, fun, deadline)
    end
  end

  defp await_agent_message(channel_id, fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_agent_message(channel_id, fun, deadline)
  end

  defp do_await_agent_message(channel_id, fun, deadline) do
    case Enum.find(agent_messages(channel_id), fun) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for an agent message in #{channel_id}")
        else
          Process.sleep(25)
          do_await_agent_message(channel_id, fun, deadline)
        end

      message ->
        message
    end
  end

  defp await_html(view, fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_html(view, fun, deadline)
  end

  defp do_await_html(view, fun, deadline) do
    html = render(view)

    cond do
      fun.(html) ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out; last render:\n#{html}")

      true ->
        Process.sleep(25)
        do_await_html(view, fun, deadline)
    end
  end

  defp effect_lines(path) do
    if File.exists?(path), do: File.read!(path) |> String.split("\n", trim: true), else: []
  end

  defp notice_lines(path) do
    if File.exists?(path), do: File.read!(path) |> String.split("\n", trim: true), else: []
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
