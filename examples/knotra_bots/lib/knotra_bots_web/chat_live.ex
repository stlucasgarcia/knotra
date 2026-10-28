defmodule KnotraBotsWeb.ChatLive do
  @moduledoc """
  A channel timeline where humans and agents are peers.

  Agent entries are backed by durable Knotra executions. A pending clarification
  or approval renders inside the agent's message; the public execution trace is
  one disclosure below it. A bounded refresh covers snapshots produced elsewhere,
  and PubSub carries the relay's own transitions.
  """
  use Phoenix.LiveView

  import KnotraBotsWeb.Components

  alias KnotraBots.{Channels, Chat}

  @refresh_ms 1_000

  @impl true
  def mount(params, _session, socket) do
    channels = Channels.list()

    channel =
      case socket.assigns.live_action do
        :show -> Channels.get(params["id"])
        :index -> landing_channel(channels)
      end

    if connected?(socket) do
      if channel, do: Phoenix.PubSub.subscribe(KnotraBots.PubSub, Chat.topic(channel.id))
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:channels, channels)
     |> assign(:channel, channel)
     |> assign(:agents, [])
     |> assign(:messages, [])
     |> assign(:draft, "")
     |> assign(:error, nil)
     |> load_messages()}
  end

  @impl true
  def handle_event("draft", %{"message" => text}, socket) do
    {:noreply, assign(socket, :draft, text)}
  end

  def handle_event("send", _params, %{assigns: %{channel: nil}} = socket) do
    {:noreply, assign(socket, :error, "Create a channel first.")}
  end

  def handle_event("send", %{"message" => text}, socket) do
    case Chat.post(socket.assigns.channel.id, text) do
      {:ok, _human} ->
        {:noreply, socket |> assign(:draft, "") |> assign(:error, nil) |> load_messages()}

      {:error, reason} ->
        {:noreply, assign(socket, :error, error_message(reason))}
    end
  end

  def handle_event("answer_input", %{"message_id" => id, "answer" => answer}, socket) do
    with %{message: message, snapshot: %{input_request: request}} <- find(socket, id),
         %{disposition: :pending, id: request_id, version: version} <- request,
         {:ok, _snapshot} <-
           Chat.answer(message, %{
             request_id: request_id,
             version: version,
             answer: String.trim(answer)
           }) do
      {:noreply, socket |> assign(:error, nil) |> load_messages()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, "Answer failed: #{inspect(reason)}")}

      _ ->
        {:noreply, assign(socket, :error, "That question is no longer pending.")}
    end
  end

  def handle_event("answer_approval", %{"id" => id, "decision" => decision}, socket) do
    with %{message: message, snapshot: %{approval: approval}} <- find(socket, id),
         %{
           disposition: :pending,
           id: request_id,
           version: version,
           name: name,
           arguments: arguments
         } <- approval,
         {:ok, _snapshot} <-
           Chat.answer(message, %{
             request_id: request_id,
             version: version,
             name: name,
             arguments: arguments,
             decision: decision(decision)
           }) do
      {:noreply, socket |> assign(:error, nil) |> load_messages()}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :error, "Approval failed: #{inspect(reason)}")}

      _ ->
        {:noreply, assign(socket, :error, "That approval is no longer pending.")}
    end
  end

  @impl true
  def handle_info({:chat, channel_id}, %{assigns: %{channel: %{id: channel_id}}} = socket) do
    {:noreply, load_messages(socket)}
  end

  def handle_info({:chat, _channel_id}, socket), do: {:noreply, socket}

  def handle_info(:refresh, socket) do
    schedule_refresh()

    socket =
      socket
      |> assign(:channels, Channels.list())
      |> refresh_channel()

    {:noreply, load_messages(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh_channel(%{assigns: %{channel: nil}} = socket), do: socket

  defp refresh_channel(socket) do
    assign(socket, :channel, Channels.get(socket.assigns.channel.id) || socket.assigns.channel)
  end

  defp load_messages(%{assigns: %{channel: nil}} = socket), do: assign(socket, messages: [])

  defp load_messages(socket) do
    channel = socket.assigns.channel

    socket
    |> assign(:agents, Channels.agents(channel.id))
    |> assign(:messages, Chat.with_snapshots(channel.id))
  end

  defp find(socket, id), do: Enum.find(socket.assigns.messages, &(&1.message.id == id))

  defp decision("approve"), do: :approve
  defp decision(_reject_or_other), do: :reject

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp error_message(:empty_message), do: "Write a message first."
  defp error_message(:message_too_long), do: "Keep messages under 4,000 characters."
  defp error_message(:no_agents), do: "That channel has no agents. Add one from the Agents page."
  defp error_message(reason), do: "Could not send: #{inspect(reason)}"

  @impl true
  def render(%{channel: nil} = assigns) do
    ~H"""
    <.shell channels={@channels} active={nil}>
      <div class="empty">
        <h1>No channel selected</h1>
        <p :if={@channels == []}>
          Create a channel and add agents. Then everyone, humans and agents, shares one thread.
        </p>
        <p :if={@channels != []}>Open a channel from the sidebar.</p>
        <p><a class="button" href="/channels">Create a channel</a></p>
      </div>
    </.shell>
    """
  end

  def render(assigns) do
    ~H"""
    <.shell channels={@channels} active={@channel.id}>
      <header class="chat-header">
        <div>
          <h1><span class="hash">#</span>{@channel.name}</h1>
          <p :if={@channel.topic != ""}>{@channel.topic}</p>
        </div>
        <div class="members">
          <span :for={agent <- @agents} class="member">
            <.avatar agent={agent} size="sm" />
            <span>@{agent.handle}</span>
          </span>
          <span :if={@agents == []} class="muted">No agents yet</span>
        </div>
      </header>

      <section class="messages" id="messages" phx-hook="ChatScroll">
        <.message_entry :for={entry <- @messages} entry={entry} agents={@agents} />
        <p :if={@messages == []} class="empty-chat">
          No messages yet. Say hello or mention an agent.
        </p>
      </section>

      <p :if={@error} class="error chat-error" data-testid="chat-error">{@error}</p>

      <form id="composer" class="composer" phx-submit="send" phx-change="draft">
        <textarea
          id="composer-input"
          name="message"
          rows="2"
          placeholder={placeholder(@channel)}
          required
          phx-hook="Composer"
        >{@draft}</textarea>
        <button type="submit">Send</button>
      </form>

      <p class="hint">
        Mention an agent with <code>@handle</code>. Without a mention,
        <strong>{default_responder(@channel, @agents)}</strong>
        answers.
      </p>
    </.shell>
    """
  end

  defp message_entry(%{entry: %{message: %{author_type: "system"}}} = assigns) do
    ~H"""
    <div class="system-note">{@entry.message.body}</div>
    """
  end

  defp message_entry(%{entry: %{message: %{author_type: "human"}} = entry} = assigns) do
    assigns = assign(assigns, :entry, entry)

    ~H"""
    <article
      class="message human"
      id={"message-" <> @entry.message.id}
      data-message-id={@entry.message.id}
      data-author="human"
      data-status={@entry.message.status}
    >
      <div class="stack">
        <div class="message-meta">
          <span>You</span>
          <.timestamp at={@entry.message.inserted_at} />
        </div>
        <div class="bubble">
          <.message_body text={@entry.message.body} />
        </div>
      </div>
    </article>
    """
  end

  defp message_entry(%{entry: %{message: %{author_type: "agent"}} = entry} = assigns) do
    agent =
      Enum.find(assigns.agents, &(&1.id == entry.message.agent_id)) ||
        %{name: "Unknown agent", handle: "unknown", model: "unknown"}

    assigns =
      assigns
      |> assign(:entry, entry)
      |> assign(:agent, agent)

    ~H"""
    <article
      class="message agent"
      id={"message-" <> @entry.message.id}
      data-message-id={@entry.message.id}
      data-author="agent"
      data-status={@entry.message.status}
    >
      <.avatar agent={@agent} />
      <div class="stack">
        <div class="message-meta">
          <strong>{@agent.name}</strong>
          <span class="handle">@{@agent.handle}</span>
          <.status_badge status={@entry.message.status} />
          <span class="model">{@agent.model}</span>
          <.timestamp at={@entry.message.inserted_at} />
        </div>

        <div class="bubble">
          <.message_body :if={@entry.message.body != ""} text={@entry.message.body} />

          <div :if={working?(@entry)} class="typing">
            <span>working</span>
            <span class="dots"><i></i><i></i><i></i></span>
          </div>

          <.gate entry={@entry} />
          <.trace entry={@entry} />
        </div>
      </div>
    </article>
    """
  end

  defp gate(%{entry: entry} = assigns) do
    cond do
      pending_input?(entry) ->
        ~H"""
        <div class="gate" data-testid="input-request">
          <p class="gate-title">Needs a detail</p>
          <p>{@entry.snapshot.input_request.prompt}</p>
          <form id={"answer-" <> @entry.message.id} phx-submit="answer_input" class="gate-form">
            <input type="hidden" name="message_id" value={@entry.message.id} />
            <input type="text" name="answer" placeholder="Your answer" required />
            <button type="submit">Answer</button>
          </form>
        </div>
        """

      pending_approval?(entry) ->
        ~H"""
        <div class="gate approval" data-testid="approval">
          <p class="gate-title">Approval required</p>
          <p>Run <code>{@entry.snapshot.approval.name}</code> with</p>
          <pre>{inspect(@entry.snapshot.approval.arguments, pretty: true, limit: :infinity)}</pre>
          <div class="gate-actions">
            <button
              phx-click="answer_approval"
              phx-value-id={@entry.message.id}
              phx-value-decision="approve"
            >
              Approve
            </button>
            <button
              class="ghost"
              phx-click="answer_approval"
              phx-value-id={@entry.message.id}
              phx-value-decision="reject"
            >
              Reject
            </button>
          </div>
        </div>
        """

      true ->
        ~H""
    end
  end

  defp trace(%{entry: %{snapshot: nil}} = assigns), do: ~H""

  defp trace(%{entry: entry} = assigns) do
    assigns = assign(assigns, :snapshot, entry.snapshot)

    ~H"""
    <details class="trace">
      <summary>
        {counts_label(@snapshot.counts)} · {elapsed(@snapshot.events)} ms
      </summary>
      <ol class="timeline">
        <li :for={event <- @snapshot.events}>
          <span class="seq">{event.sequence}</span>
          <span class="type">{to_string(event.type)}</span>
          <span class="elapsed">{event.elapsed_ms} ms</span>
        </li>
      </ol>
      <p class="trace-version">{@snapshot.definition_version}</p>
    </details>
    """
  end

  defp working?(%{message: %{status: status}, snapshot: snapshot}) do
    status in ["queued", "running"] or
      (status == "waiting" and not pending_input?(%{snapshot: snapshot}) and
         not pending_approval?(%{snapshot: snapshot}))
  end

  defp pending_input?(%{snapshot: %{input_request: %{disposition: :pending}}}), do: true
  defp pending_input?(_entry), do: false

  defp pending_approval?(%{snapshot: %{approval: %{disposition: :pending}}}), do: true
  defp pending_approval?(_entry), do: false

  defp counts_label(counts) do
    "#{count(counts.turns, "turn", "turns")} · #{count(counts.tools, "tool", "tools")} · #{count(counts.retries, "retry", "retries")}"
  end

  defp count(1, singular, _plural), do: "1 #{singular}"
  defp count(n, _singular, plural), do: "#{n} #{plural}"

  defp elapsed([]), do: 0
  defp elapsed(events), do: List.last(events).elapsed_ms

  # Prefer the channel with most agents on `/`: the seeded multi-agent Ops room.
  defp landing_channel([]), do: nil
  defp landing_channel(channels), do: Enum.max_by(channels, &length(Channels.agents(&1.id)))

  defp placeholder(%{name: name}), do: "Message ##{name}…"

  defp default_responder(channel, agents) do
    agent =
      Enum.find(agents, &(&1.id == channel.default_agent_id)) || List.first(agents)

    case agent do
      nil -> "no agent"
      agent -> "@" <> agent.handle
    end
  end
end
