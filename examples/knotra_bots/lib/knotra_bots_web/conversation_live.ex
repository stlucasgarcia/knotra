defmodule KnotraBotsWeb.ConversationLive do
  @moduledoc """
  Live view of one bot-to-bot conversation: status, turns and their durable
  execution ids, plus Stop/Resume controls.

  Conversation turns are tool-free, so no human approval gates them; Stop lets an
  in-flight turn finish and then halts before the next one.
  """
  use Phoenix.LiveView

  alias KnotraBots.{Bots, Conversations}

  @refresh_ms 1_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Conversations.get(id) do
      nil ->
        {:ok, assign(socket, :conversation, nil)}

      conversation ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(KnotraBots.PubSub, Conversations.topic(id))
          schedule_refresh()
        end

        {:ok,
         socket
         |> assign(:conversation, conversation)
         |> assign(:action_error, nil)
         |> assign(:bot_names, Bots.names())
         |> assign_turns()}
    end
  end

  @impl true
  def handle_event("stop", _params, socket) do
    {:noreply, reload(socket, Conversations.stop(socket.assigns.conversation.id))}
  end

  def handle_event("resume", _params, socket) do
    {:noreply, reload(socket, Conversations.resume(socket.assigns.conversation.id))}
  end

  @impl true
  def handle_info({:conversation, _id}, socket), do: {:noreply, reload(socket, :ok)}

  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, reload(socket, :ok)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(%{assigns: %{conversation: nil}} = socket, _result), do: socket

  defp reload(socket, result) do
    socket =
      case result do
        {:error, reason} -> assign(socket, :action_error, "Action failed: #{inspect(reason)}")
        _ -> assign(socket, :action_error, nil)
      end

    socket
    |> assign(:conversation, Conversations.get!(socket.assigns.conversation.id))
    |> assign(:bot_names, Bots.names())
    |> assign_turns()
  end

  defp assign_turns(socket) do
    id = socket.assigns.conversation.id

    socket
    |> assign(:turns, Conversations.turns(id))
    |> assign(:completed, Conversations.completed_count(id))
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <p :if={@conversation == nil} class="empty">That conversation no longer exists.</p>

      <div :if={@conversation} class="conversation">
        <header class="top">
          <h1>{@conversation.topic}</h1>
          <p>
            {@bot_names[@conversation.bot_a_id]} → {@bot_names[@conversation.bot_b_id]} ·
            status <span class={"badge badge-" <> @conversation.status}>{@conversation.status}</span>
            · {@completed}/{@conversation.rounds} turns
          </p>
        </header>

        <p class="note">
          Conversation turns are tool-free in this cut: every durable tool call needs a
          human approval, so a relay with tools would stall on the gate. Tools on a bot
          row still apply to single dashboard runs.
        </p>

        <div class="toolbar">
          <p :if={@action_error} class="error" data-testid="action-error">{@action_error}</p>
          <button
            :if={@conversation.status == "running"}
            phx-click="stop"
            data-testid="stop"
          >
            Stop
          </button>
          <button
            :if={Conversations.resumable?(@conversation, @completed)}
            phx-click="resume"
            data-testid="resume"
          >
            Resume
          </button>
        </div>

        <ol class="turns">
          <li :for={turn <- @turns} class="turn" data-turn-index={turn.index}>
            <span class="seq">{turn.index}</span>
            <span class="bot">{@bot_names[turn.bot_id]}</span>
            <span class={"badge badge-" <> turn.status}>{turn.status}</span>
            <span :if={turn.output} class="output">{turn.output}</span>
            <a
              :if={turn.execution_id}
              class="exec-link"
              href={"/#execution-" <> turn.execution_id}
              title={turn.execution_id}
            >
              {String.slice(turn.execution_id, 0, 8)}
            </a>
          </li>
        </ol>
      </div>
    </div>
    """
  end
end
