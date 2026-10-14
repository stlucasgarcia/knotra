defmodule KnotraBotsTest do
  @moduledoc """
  Offline end-to-end tests through the LiveViews. The fake model is configured for
  the test environment, so no provider key or network access is needed.

  Assertions are scoped to the run/card under test: the shared Repo keeps history
  across tests, so other cards must not satisfy a wait.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias KnotraBots.{Bots, Conversation, Conversations}

  @endpoint KnotraBotsWeb.Endpoint
  @prompt "Which order should I look up?"

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

  test "concierge clarifies, approves a notify and completes with one notice", %{notices: notices} do
    {:ok, view, _html} = live(build_conn(), "/")
    id = submit(view, "concierge")
    answer(view, id)

    await(view, id, &String.contains?(&1, ~s(data-testid="approval")))
    assert card(view, id) =~ "notify"

    view |> element("#execution-#{id} button[phx-value-decision=approve]") |> render_click()

    completed = await(view, id, &String.contains?(&1, "badge-completed"))
    assert completed =~ "Done. The result was: notice queued: ops"
    assert completed =~ "input_answered"
    refute completed =~ @prompt
    assert_counts(completed, turns: 3, tools: 1, retries: 0, steps: 5)

    assert notice_lines(notices) == ["ops"]
  end

  test "assistant approves a read-only lookup and writes no notice", %{notices: notices} do
    {:ok, view, _html} = live(build_conn(), "/")
    id = submit(view, "assistant")
    answer(view, id)

    approval = await(view, id, &String.contains?(&1, ~s(data-testid="approval")))
    assert approval =~ "lookup"
    refute approval =~ "notify"

    view |> element("#execution-#{id} button[phx-value-decision=approve]") |> render_click()

    completed = await(view, id, &String.contains?(&1, "badge-completed"))
    assert completed =~ "Done. The result was: Order ord-1 shipped"
    assert notice_lines(notices) == []
  end

  test "pending clarification survives an instance restart", %{notices: notices} do
    {:ok, view, _html} = live(build_conn(), "/")
    id = submit(view, "concierge")

    # Stop while the run waits for clarification, before answering it.
    :ok = KnotraBots.stop_instance()
    refute Process.whereis(KnotraBots.Instance)
    {:ok, _pid} = KnotraBots.start_instance()

    {:ok, view2, _html} = live(build_conn(), "/")
    restored = await(view2, id, &String.contains?(&1, ~s(data-testid="input-request")))
    assert restored =~ @prompt

    answer(view2, id)
    await(view2, id, &String.contains?(&1, ~s(data-testid="approval")))

    view2 |> element("#execution-#{id} button[phx-value-decision=approve]") |> render_click()

    completed = await(view2, id, &String.contains?(&1, "badge-completed"))
    assert completed =~ "Done. The result was: notice queued: ops"
    # The question is answered exactly once and never re-asked.
    assert completed =~ "input_answered"
    refute completed =~ @prompt
    # Counters accrued before the restart are preserved.
    assert_counts(completed, turns: 3, tools: 1, retries: 0, steps: 5)
    assert notice_lines(notices) == ["ops"]
  end

  test "rejecting an approval records rejection and writes no notice", %{notices: notices} do
    {:ok, view, _html} = live(build_conn(), "/")
    id = submit(view, "concierge")
    answer(view, id)

    await(view, id, &String.contains?(&1, ~s(data-testid="approval")))
    view |> element("#execution-#{id} button[phx-value-decision=reject]") |> render_click()

    rejected = await(view, id, &String.contains?(&1, "badge-rejected"))
    assert rejected =~ "approval_rejected"
    assert notice_lines(notices) == []
  end

  test "GEMINI_API_KEY is forwarded when GOOGLE_API_KEY is empty", %{notices: _notices} do
    previous_model = Application.get_env(:knotra_bots, :model)
    previous_google = System.get_env("GOOGLE_API_KEY")
    previous_gemini = System.get_env("GEMINI_API_KEY")

    on_exit(fn ->
      Application.put_env(:knotra_bots, :model, previous_model)
      restore_env("GOOGLE_API_KEY", previous_google)
      restore_env("GEMINI_API_KEY", previous_gemini)
    end)

    Application.put_env(:knotra_bots, :model, "google:gemini-2.5-flash")
    System.put_env("GOOGLE_API_KEY", "")
    System.put_env("GEMINI_API_KEY", "gemini-test-key")

    assert {KnotraBots.Models.Logged, opts} = KnotraBots.model()
    assert {Knotra.Models.ReqLLM, inner} = Keyword.fetch!(opts, :plugin)
    assert inner[:model] == "google:gemini-2.5-flash"
    assert inner[:options][:api_key] == "gemini-test-key"
    # The preflight must use the same key resolution, or the selector would hide
    # a model that would actually succeed.
    assert KnotraBots.model_status("google:gemini-2.5-flash") == :ok
  end

  test "the logged wrapper contains plugin exceptions", %{notices: _notices} do
    request = %{input: "hi", exchanges: [], tools: []}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :model_error} =
                 KnotraBots.Models.Logged.call(request,
                   plugin: {Knotra.Models.ReqLLM, model: nil, options: []}
                 )
      end)

    assert log =~ "model plugin raised"
  end

  test "submit refuses a bot whose model has no resolvable key", %{notices: _notices} do
    previous_google = System.get_env("GOOGLE_API_KEY")
    previous_gemini = System.get_env("GEMINI_API_KEY")

    on_exit(fn ->
      restore_env("GOOGLE_API_KEY", previous_google)
      restore_env("GEMINI_API_KEY", previous_gemini)
    end)

    System.delete_env("GOOGLE_API_KEY")
    System.delete_env("GEMINI_API_KEY")

    bot = bot_fixture(%{"model" => "google:gemini-2.5-flash", "tools" => "lookup"})

    {:ok, view, _html} = live(build_conn(), "/")
    view |> form("#new-run", %{"bot" => bot.id, "message" => "ord-1"}) |> render_submit()
    assert render(view) =~ "Model not ready"
  end

  test "a bot created through the UI is listed and selectable for a single run", %{
    notices: notices
  } do
    name = "Helper #{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(build_conn(), "/bots")
    render_submit(form(view, "#new-bot", new_bot_params(name, "fake", ["lookup"])))
    assert render(view) =~ name

    bot = Bots.list() |> Enum.find(&(&1.name == name))
    assert bot.model == "fake"
    assert bot.tools == "lookup"
    assert Bots.tool_modules(bot) == [KnotraBots.Tools.Lookup]

    {:ok, dash, _html} = live(build_conn(), "/")
    assert render(dash) =~ name

    id = submit(dash, bot.id)
    answer(dash, id)

    approval = await(dash, id, &String.contains?(&1, ~s(data-testid="approval")))
    assert approval =~ "lookup"
    refute approval =~ "notify"

    dash |> element("#execution-#{id} button[phx-value-decision=approve]") |> render_click()

    completed = await(dash, id, &String.contains?(&1, "badge-completed"))
    assert completed =~ "Done. The result was: Order ord-1 shipped"
    assert notice_lines(notices) == []
  end

  test "editing a bot bumps its revision and changes its definition version", %{notices: _notices} do
    bot = bot_fixture(%{})
    version_before = Bots.definition(bot, self()).version

    {:ok, view, _html} = live(build_conn(), "/bots")
    render_submit(form(view, "#bot-" <> bot.id, %{"name" => bot.name <> " v2"}))

    edited = Bots.get!(bot.id)
    assert edited.revision == bot.revision + 1
    assert edited.name == bot.name <> " v2"

    version_after = Bots.definition(edited, self()).version
    assert version_before != version_after
    assert String.ends_with?(version_after, "-r#{edited.revision}")
  end

  test "delete removes an unreferenced bot and refuses a referenced one", %{notices: _notices} do
    lone = bot_fixture(%{})
    {:ok, view, _html} = live(build_conn(), "/bots")

    render_click(view, "delete", %{"id" => lone.id})
    assert Bots.get(lone.id) == nil

    referenced = bot_fixture(%{})
    other = bot_fixture(%{})
    _conversation = insert_conversation!(referenced, other, unique_topic("Keep"), 2)

    render_click(view, "delete", %{"id" => referenced.id})
    assert Bots.get(referenced.id) != nil
    assert render(view) =~ "a conversation references it"
  end

  test "two fake bots complete an alternating conversation that echoes the transcript", %{
    notices: _notices
  } do
    bot_a = bot_fixture(%{})
    bot_b = bot_fixture(%{})
    topic = "Shipping delays #{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(build_conn(), "/conversations")

    render_submit(
      form(view, "#new-conversation", %{
        "bot_a_id" => bot_a.id,
        "bot_b_id" => bot_b.id,
        "topic" => topic,
        "rounds" => "4"
      })
    )

    conversation = find_conversation!(topic)
    assert await_conversation(conversation.id, &(&1.status == "completed")).status == "completed"

    turns = Conversations.turns(conversation.id)
    assert Enum.map(turns, & &1.index) == [0, 1, 2, 3]
    assert Enum.map(turns, & &1.bot_id) == [bot_a.id, bot_b.id, bot_a.id, bot_b.id]
    assert Enum.all?(turns, &(&1.status == "completed"))
    assert Enum.all?(turns, &(&1.execution_id && &1.output not in [nil, ""]))
    assert output(turns, 1) =~ output(turns, 0)
    assert output(turns, 3) =~ output(turns, 2)
  end

  test "a killed conversation runner interrupts and resume completes without duplicating turns",
       %{notices: _notices} do
    bot_a = bot_fixture(%{})
    bot_b = bot_fixture(%{})
    conversation = new_conversation!(bot_a, bot_b, unique_topic("Budget planning"), 4)

    await_until(fn -> Conversations.completed_count(conversation.id) >= 1 end)

    runner = Conversations.runner_pid(conversation.id)
    assert is_pid(runner)
    Process.exit(runner, :kill)

    assert await_conversation(conversation.id, &(&1.status == "interrupted")).status ==
             "interrupted"

    before = Conversations.turns(conversation.id)
    existing = Map.new(before, &{&1.index, &1.execution_id})

    assert :ok = Conversations.resume(conversation.id)
    assert await_conversation(conversation.id, &(&1.status == "completed")).status == "completed"

    turns = Conversations.turns(conversation.id)
    assert Enum.map(turns, & &1.index) == [0, 1, 2, 3]
    assert Enum.all?(turns, &(&1.status == "completed"))

    for turn <- turns, id = existing[turn.index], id != nil do
      assert turn.execution_id == id
    end
  end

  test "resume retries a failed turn with a fresh execution instead of rebinding it",
       %{notices: _notices} do
    previous_google = System.get_env("GOOGLE_API_KEY")
    previous_gemini = System.get_env("GEMINI_API_KEY")

    on_exit(fn ->
      restore_env("GOOGLE_API_KEY", previous_google)
      restore_env("GEMINI_API_KEY", previous_gemini)
    end)

    System.delete_env("GOOGLE_API_KEY")
    System.delete_env("GEMINI_API_KEY")

    bot_a = bot_fixture(%{"model" => "google:gemini-2.5-flash"})
    bot_b = bot_fixture(%{})
    conversation = new_conversation!(bot_a, bot_b, unique_topic("Retry"), 2)

    assert await_conversation(conversation.id, &(&1.status == "interrupted")).status ==
             "interrupted"

    [failed] = Conversations.turns(conversation.id)
    assert failed.status == "failed"
    failed_execution = failed.execution_id

    # Fix the model and resume: the retry must use a fresh execution, not the
    # deterministic key of the failed attempt.
    assert {:ok, _} = Bots.update(Bots.get!(bot_a.id), %{"model" => "fake"})

    assert :ok = Conversations.resume(conversation.id)
    assert await_conversation(conversation.id, &(&1.status == "completed")).status == "completed"

    turns = Conversations.turns(conversation.id)
    assert Enum.map(turns, & &1.index) == [0, 1]
    assert Enum.all?(turns, &(&1.status == "completed"))
    refute Enum.any?(turns, &(&1.execution_id == failed_execution))
  end

  test "a boot sweep makes runner-less conversations resumable", %{notices: _notices} do
    bot_a = bot_fixture(%{})
    bot_b = bot_fixture(%{})
    stale_running = insert_conversation!(bot_a, bot_b, unique_topic("Sweep"), 2)
    stale_stopping = insert_conversation!(bot_a, bot_b, unique_topic("Was stopping"), 2)
    KnotraBots.Repo.update!(Ecto.Changeset.change(stale_stopping, status: "stopping"))

    # Simulate the host restart: no runner survives, the rows are stale.
    :ok = Supervisor.terminate_child(KnotraBots.Supervisor, KnotraBots.Conversations)
    {:ok, _pid} = Supervisor.restart_child(KnotraBots.Supervisor, KnotraBots.Conversations)

    assert Conversations.get(stale_running.id).status == "interrupted"
    assert Conversations.get(stale_stopping.id).status == "stopped"

    assert :ok = Conversations.resume(stale_running.id)

    assert await_conversation(stale_running.id, &(&1.status == "completed")).status ==
             "completed"
  end

  test "stop halts before the next turn and leaves no further turns", %{notices: _notices} do
    bot_a = bot_fixture(%{})
    bot_b = bot_fixture(%{})
    conversation = new_conversation!(bot_a, bot_b, unique_topic("Weather"), 4)

    assert :ok = Conversations.stop(conversation.id)
    assert await_conversation(conversation.id, &(&1.status == "stopped")).status == "stopped"

    completed = Conversations.completed_count(conversation.id)
    assert completed < 4

    Process.sleep(400)
    assert Conversations.completed_count(conversation.id) == completed
    assert Conversations.get(conversation.id).status == "stopped"
  end

  test "conversation start refuses an unconfigured model and the bot form rejects an unknown model",
       %{notices: _notices} do
    previous_openai = System.get_env("OPENAI_API_KEY")
    previous_config = Application.get_env(:req_llm, :openai_api_key)

    on_exit(fn ->
      restore_env("OPENAI_API_KEY", previous_openai)
      restore_config(:req_llm, :openai_api_key, previous_config)
    end)

    System.delete_env("OPENAI_API_KEY")
    Application.delete_env(:req_llm, :openai_api_key)

    assistant = Bots.get!("assistant")
    unconfigured = bot_fixture(%{"model" => "openai:gpt-4o-mini"})
    assert {:error, _reason} = KnotraBots.model_status("openai:gpt-4o-mini")

    topic = unique_topic("Nope")

    {:ok, view, _html} = live(build_conn(), "/conversations")

    render_submit(
      form(view, "#new-conversation", %{
        "bot_a_id" => assistant.id,
        "bot_b_id" => unconfigured.id,
        "topic" => topic,
        "rounds" => "2"
      })
    )

    assert render(view) =~ "Model not ready"
    refute Enum.any?(Conversations.list(), &(&1.topic == topic))

    {:ok, bots_view, _html} = live(build_conn(), "/bots")

    render_submit(bots_view, "create", %{
      "name" => "Bad #{System.unique_integer([:positive])}",
      "model" => "not-a-model",
      "system_prompt" => "",
      "tools" => ["lookup"]
    })

    assert render(bots_view) =~ "is not in the model catalog"
  end

  defp new_bot_params(name, model, tools) do
    %{"name" => name, "system_prompt" => "You are terse.", "model" => model, "tools" => tools}
  end

  defp bot_fixture(attrs) do
    defaults = %{
      "name" => "Bot #{System.unique_integer([:positive])}",
      "model" => "fake",
      "tools" => "",
      "system_prompt" => ""
    }

    Bots.create!(Map.merge(defaults, attrs))
  end

  defp insert_conversation!(bot_a, bot_b, topic, rounds) do
    %Conversation{
      id: "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
      bot_a_id: bot_a.id,
      bot_b_id: bot_b.id,
      topic: topic,
      rounds: rounds,
      status: "running"
    }
    |> KnotraBots.Repo.insert!()
  end

  defp new_conversation!(bot_a, bot_b, topic, rounds) do
    conversation = insert_conversation!(bot_a, bot_b, topic, rounds)
    :ok = Conversations.start(conversation.id)
    conversation
  end

  defp find_conversation!(topic) do
    Conversations.list() |> Enum.find(&(&1.topic == topic)) ||
      flunk("no conversation for #{topic}")
  end

  defp unique_topic(label), do: "#{label} #{System.unique_integer([:positive])}"

  defp output(turns, index), do: turns |> Enum.at(index) |> Map.fetch!(:output)

  defp restore_config(app, key, nil), do: Application.delete_env(app, key)
  defp restore_config(app, key, value), do: Application.put_env(app, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp submit(view, bot) do
    view |> form("#new-run", %{"bot" => bot, "message" => "ord-1"}) |> render_submit()
    html = await_html(view, &String.contains?(&1, @prompt))
    newest_execution_id(html)
  end

  defp answer(view, id) do
    render_submit(form(view, "#answer-#{id}", %{"answer" => "ord-1"}))
  end

  defp newest_execution_id(html) do
    case Regex.run(~r/data-execution-id="([^"]+)"/, html) do
      [_, id] -> id
      _ -> flunk("no run card rendered:\n#{html}")
    end
  end

  defp card(view, id), do: view |> render() |> card_html(id)

  defp card_html(html, id) do
    case Regex.run(~r/<article[^>]*id="execution-#{Regex.escape(id)}".*?<\/article>/s, html) do
      [card] -> card
      _ -> ""
    end
  end

  defp assert_counts(card, expected) do
    for {name, value} <- expected do
      assert card =~ ~r/<dt>#{name}<\/dt>\s*<dd>#{value}<\/dd>/
    end
  end

  defp notice_lines(path) do
    if File.exists?(path), do: File.read!(path) |> String.split("\n", trim: true), else: []
  end

  # Waits until the specific run card satisfies `fun`, then returns that card.
  defp await(view, id, fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(view, id, fun, deadline)
  end

  defp do_await(view, id, fun, deadline) do
    card = card(view, id)

    cond do
      fun.(card) ->
        card

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for run #{id}; last card:\n#{card}")

      true ->
        Process.sleep(25)
        do_await(view, id, fun, deadline)
    end
  end

  defp await_html(view, fun, timeout \\ 3_000) do
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

  defp await_conversation(id, fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_conversation(id, fun, deadline)
  end

  defp do_await_conversation(id, fun, deadline) do
    conversation = Conversations.get(id)

    cond do
      conversation && fun.(conversation) ->
        conversation

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for conversation #{id}; last: #{inspect(conversation)}")

      true ->
        Process.sleep(25)
        do_await_conversation(id, fun, deadline)
    end
  end

  defp await_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_until(fun, deadline)
  end

  defp do_await_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for condition")

      true ->
        Process.sleep(25)
        do_await_until(fun, deadline)
    end
  end
end
