defmodule KnotraBotsWeb.DashboardLive do
  @moduledoc """
  Live view over the tenant's durable executions.

  Run details come exclusively from `Knotra.list/3`, the library's tenant-scoped
  public query. The host keeps its own identity table instead of reaching into
  Knotra's persistence schema.

  Submitted runs use this LiveView as their observer, so progress arrives as
  `{:knotra, snapshot}` messages. A bounded periodic refresh covers runs submitted
  by another session or resumed after a restart, when delivery points at a stale
  observer.
  """
  use Phoenix.LiveView

  alias KnotraBots.Bots

  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    bots = Bots.list()

    default =
      if Enum.any?(bots, &(&1.id == "concierge")), do: "concierge", else: default_bot_id(bots)

    {:ok,
     socket
     |> assign(:tenant, KnotraBots.tenant())
     |> assign(:bots, bots)
     |> assign(:bot, default)
     |> assign(:message, "")
     |> assign(:submit_error, nil)
     |> assign(:answer_error, nil)
     |> assign(:storage_error, nil)
     |> assign_executions()}
  end

  @impl true
  def handle_event("submit", %{"bot" => bot_id, "message" => message}, socket) do
    message = String.trim(message)

    case Bots.get(bot_id) do
      nil ->
        {:noreply, assign(socket, :submit_error, "Unknown bot.")}

      bot ->
        case KnotraBots.model_status(bot.model) do
          :ok ->
            submit(socket, bot, message)

          {:error, reason} ->
            {:noreply, assign(socket, :submit_error, "Model not ready: " <> reason)}
        end
    end
  end

  def handle_event("answer_input", %{"run_id" => id, "answer" => answer}, socket) do
    case find_execution(socket, id) do
      %{input_request: %{id: request, version: version}} = run ->
        answer = %{request_id: request, version: version, answer: String.trim(answer)}
        answer(socket, id, run, answer)

      _ ->
        {:noreply, assign(socket, :answer_error, "That question is no longer pending.")}
    end
  end

  def handle_event("answer_approval", %{"id" => id, "decision" => decision}, socket) do
    case find_execution(socket, id) do
      %{approval: %{id: request, version: version, name: name, arguments: arguments}} = run ->
        answer = %{
          request_id: request,
          version: version,
          name: name,
          arguments: arguments,
          decision: decision(decision)
        }

        answer(socket, id, run, answer)

      _ ->
        {:noreply, assign(socket, :answer_error, "That approval is no longer pending.")}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, assign_executions(socket)}

  defp submit(socket, bot, message) do
    definition = Bots.definition(bot, self())

    case Knotra.submit(KnotraBots.Instance, definition, message, scope(), submission_key()) do
      {:ok, _id} ->
        {:noreply,
         socket |> assign(:message, "") |> assign(:submit_error, nil) |> assign_executions()}

      {:error, reason} ->
        {:noreply, assign(socket, :submit_error, error_message(reason))}
    end
  end

  @impl true
  def handle_info({:knotra, %{id: id} = snapshot}, socket) do
    executions =
      Enum.map(socket.assigns.executions, fn
        {:ok, %{id: ^id}} -> {:ok, snapshot}
        other -> other
      end)

    {:noreply, assign(socket, :executions, executions)}
  end

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_executions(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp answer(socket, id, run, answer) do
    case definition_for(run) do
      nil ->
        {:noreply,
         assign(
           socket,
           :answer_error,
           "The bot for this run was deleted; this pending interaction can no longer be answered."
         )}

      definition ->
        case Knotra.answer(KnotraBots.Instance, id, definition, scope(), answer) do
          {:ok, _snapshot} ->
            {:noreply, socket |> assign(:answer_error, nil) |> assign_executions()}

          {:error, reason} ->
            {:noreply, assign(socket, :answer_error, error_message(reason))}
        end
    end
  end

  defp definition_for(%{definition_version: version}) do
    with id when is_binary(id) <- Bots.bot_id_for_version(version),
         %{} = bot <- Bots.get(id) do
      Bots.definition(bot, self())
    else
      _ -> nil
    end
  end

  defp find_execution(socket, id) do
    Enum.find_value(socket.assigns.executions, fn
      {:ok, %{id: ^id} = snapshot} -> snapshot
      _ -> nil
    end)
  end

  defp assign_executions(socket) do
    case list_executions() do
      {:ok, executions} ->
        socket |> assign(:executions, executions) |> assign(:storage_error, nil)

      {:error, reason} ->
        socket |> assign(:executions, []) |> assign(:storage_error, reason)
    end
  end

  defp list_executions do
    case Knotra.list(KnotraBots.Instance, scope(), limit: 100) do
      {:ok, snapshots} -> {:ok, Enum.map(snapshots, &{:ok, &1})}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :storage_unavailable}
  end

  defp scope, do: %{tenant: KnotraBots.tenant(), permissions: KnotraBots.permissions()}

  defp default_bot_id([]), do: ""
  defp default_bot_id([bot | _]), do: bot.id

  defp decision("approve"), do: :approve
  defp decision(_reject_or_other), do: :reject

  defp submission_key, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp error_message(reason), do: inspect(reason)

  defp short_id(id), do: String.slice(id, 0, 8)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <header class="top">
        <h1>KnotraBots</h1>
        <p>Durable bot executions for tenant <code>{@tenant}</code>.</p>
      </header>

      <form id="new-run" phx-submit="submit" class="new-run">
        <label>
          Bot
          <select name="bot">
            <option :for={bot <- @bots} value={bot.id} selected={@bot == bot.id}>
              {bot.name}
            </option>
          </select>
        </label>
        <label>
          Message <input type="text" name="message" value={@message} placeholder="ord-1" required />
        </label>
        <button type="submit">Run</button>
      </form>

      <p :if={@submit_error} class="error" data-testid="submit-error">
        Submit failed: {@submit_error}
      </p>
      <p :if={@answer_error} class="error" data-testid="answer-error">
        Answer failed: {@answer_error}
      </p>

      <div class="toolbar">
        <h2>Executions</h2>
        <button phx-click="refresh">Refresh</button>
      </div>

      <p :if={@storage_error} class="error" data-testid="storage-error">
        Storage unavailable ({to_string(@storage_error)}); the list may be incomplete.
      </p>

      <p :if={@executions == [] and is_nil(@storage_error)} class="empty">
        No executions yet. Submit one above.
      </p>

      <section class="executions">
        <.execution_card :for={execution <- @executions} execution={execution} />
      </section>
    </div>
    """
  end

  defp execution_card(%{execution: {:ok, snapshot}} = assigns) do
    assigns = assign(assigns, :snapshot, snapshot)

    ~H"""
    <article class="execution" data-execution-id={@snapshot.id} id={"execution-" <> @snapshot.id}>
      <header class="execution-header">
        <span class="execution-id" title={@snapshot.id}>{short_id(@snapshot.id)}</span>
        <span class={"badge badge-" <> to_string(@snapshot.status)}>
          {to_string(@snapshot.status)}
        </span>
        <span class="version">{@snapshot.definition_version}</span>
      </header>

      <dl class="counts">
        <dt>turns</dt>
        <dd>{@snapshot.counts.turns}</dd>
        <dt>tools</dt>
        <dd>{@snapshot.counts.tools}</dd>
        <dt>retries</dt>
        <dd>{@snapshot.counts.retries}</dd>
        <dt>steps</dt>
        <dd>{@snapshot.counts.steps}</dd>
      </dl>

      <p :if={@snapshot.output} class="output"><strong>Output:</strong> {@snapshot.output}</p>
      <p :if={@snapshot.error} class="error">
        <strong>Error:</strong> {to_string(@snapshot.error)}
      </p>

      <ol class="timeline">
        <li :for={event <- @snapshot.events}>
          <span class="seq">{event.sequence}</span>
          <span class="type">{to_string(event.type)}</span>
          <span class="elapsed">{event.elapsed_ms} ms</span>
        </li>
      </ol>

      <.interaction snapshot={@snapshot} />
    </article>
    """
  end

  defp execution_card(%{execution: {:error, id, status, reason}} = assigns) do
    assigns = assign(assigns, id: id, status: status, reason: reason)

    ~H"""
    <article class="execution execution-error" data-execution-id={@id} id={"execution-" <> @id}>
      <header class="execution-header">
        <span class="execution-id" title={@id}>{short_id(@id)}</span>
        <span class="badge badge-error">error</span>
        <span class="version">{@status}</span>
      </header>
      <p class="error">Unavailable: {to_string(@reason)}</p>
    </article>
    """
  end

  defp interaction(
         %{snapshot: %{status: :waiting, input_request: %{disposition: :pending} = request}} =
           assigns
       ) do
    assigns = assign(assigns, :request, request)

    ~H"""
    <div class="interaction" data-testid="input-request">
      <h3>Clarification</h3>
      <p class="prompt">{@request.prompt}</p>
      <form id={"answer-" <> @snapshot.id} phx-submit="answer_input">
        <input type="hidden" name="run_id" value={@snapshot.id} />
        <input type="text" name="answer" placeholder="your answer" required />
        <button type="submit">Answer</button>
      </form>
    </div>
    """
  end

  defp interaction(
         %{snapshot: %{status: :waiting, approval: %{disposition: :pending} = approval}} = assigns
       ) do
    assigns = assign(assigns, :approval, approval)

    ~H"""
    <div class="interaction" data-testid="approval">
      <h3>Approval required</h3>
      <p>Operation <code>{@approval.name}</code></p>
      <pre>{inspect(@approval.arguments)}</pre>
      <button phx-click="answer_approval" phx-value-id={@snapshot.id} phx-value-decision="approve">
        Approve
      </button>
      <button phx-click="answer_approval" phx-value-id={@snapshot.id} phx-value-decision="reject">
        Reject
      </button>
    </div>
    """
  end

  defp interaction(%{snapshot: _} = assigns), do: ~H""
end
