defmodule KnotraBotsTest do
  @moduledoc """
  Offline end-to-end tests through the LiveView. The fake model is configured for
  the test environment, so no provider key or network access is needed.

  Assertions are scoped to the run card under test: the shared Repo keeps history
  across tests, so other cards must not satisfy a wait.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

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

  test "submit refuses a model with no resolvable key", %{notices: _notices} do
    previous_model = Application.get_env(:knotra_bots, :model)
    previous_google = System.get_env("GOOGLE_API_KEY")
    previous_gemini = System.get_env("GEMINI_API_KEY")

    on_exit(fn ->
      Application.put_env(:knotra_bots, :model, previous_model)
      restore_env("GOOGLE_API_KEY", previous_google)
      restore_env("GEMINI_API_KEY", previous_gemini)
    end)

    Application.put_env(:knotra_bots, :model, "google:gemini-2.5-flash")
    System.delete_env("GOOGLE_API_KEY")
    System.delete_env("GEMINI_API_KEY")

    {:ok, view, _html} = live(build_conn(), "/")
    view |> form("#new-run", %{"bot" => "concierge", "message" => "ord-1"}) |> render_submit()
    assert render(view) =~ "Model not ready"
  end

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
end
