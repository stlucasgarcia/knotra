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

  alias KnotraBots.{Agents, Channels, Chat}

  @endpoint KnotraBotsWeb.Endpoint

  setup do
    notices =
      Path.expand(
        "../_build/notices-#{System.unique_integer([:positive, :monotonic])}.log",
        __DIR__
      )

    File.rm(notices)
    Application.put_env(:knotra_bots, :notices_path, notices)

    on_exit(fn ->
      File.rm(notices)

      Application.put_env(
        :knotra_bots,
        :notices_path,
        Path.expand("../_build/notices.log", __DIR__)
      )
    end)

    %{notices: notices}
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
    refute Enum.any?(executions, &is_integer(&1.id))

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
  end

  test "a concierge handoff becomes a researcher lookup that runs without a human gate",
       %{notices: _notices} do
    concierge = Agents.get!("concierge")
    researcher = Agents.get!("researcher")
    channel = channel_fixture([concierge, researcher], default: concierge.id)

    {:ok, view, _html} = live(build_conn(), "/channels/#{channel.id}")

    submit_message(view, "can you check order ord-1?")

    first =
      await_agent_message(
        channel.id,
        &(&1.agent_id == concierge.id and &1.status == "completed")
      )

    assert first.body =~ "@researcher"

    research = await_agent_message(channel.id, &(&1.agent_id == researcher.id))
    assert research.hop == 1

    done =
      await_agent_message(
        channel.id,
        &(&1.agent_id == researcher.id and &1.status == "completed")
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
             edge.from == "Concierge" and edge.to == "Researcher"
           end)

    assert Enum.any?(graph.conversations, fn conversation ->
             Enum.map(conversation.executions, & &1.agent) == ["Concierge", "Researcher"]
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

  test "a clarification is answered inside the agent message", %{notices: _notices} do
    assistant = Agents.get!("assistant")
    channel = channel_fixture([assistant], default: assistant.id)

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
        "tools" => ["lookup"]
      })
    )

    assert render(view) =~ name
    agent = Agents.list() |> Enum.find(&(&1.name == name))
    assert agent.handle == handle
    assert Agents.tool_modules(agent) == [KnotraBots.Tools.Lookup]

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
        "tools" => ["lookup"]
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

  defp notice_lines(path) do
    if File.exists?(path), do: File.read!(path) |> String.split("\n", trim: true), else: []
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
