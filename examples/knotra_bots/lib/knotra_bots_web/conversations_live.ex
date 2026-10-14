defmodule KnotraBotsWeb.ConversationsLive do
  @moduledoc """
  Lists bot-to-bot conversations and starts new ones.

  Starting refuses with a readable error when either bot's model is not configured,
  using the same per-model preflight as the single-run dashboard.
  """
  use Phoenix.LiveView

  alias KnotraBots.{Bots, Conversation, Repo}
  alias KnotraBots.Conversations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:error, nil)
     |> assign(:bots, Bots.list())
     |> assign(:bot_names, bot_names())
     |> assign_conversations()}
  end

  @impl true
  def handle_event("create", params, socket) do
    bot_a = Bots.get(params["bot_a_id"])
    bot_b = Bots.get(params["bot_b_id"])
    topic = String.trim(params["topic"] || "")
    rounds = parse_rounds(params["rounds"])

    cond do
      is_nil(bot_a) or is_nil(bot_b) ->
        {:noreply, assign(socket, :error, "Choose two bots.")}

      topic == "" ->
        {:noreply, assign(socket, :error, "A topic is required.")}

      is_nil(rounds) ->
        {:noreply, assign(socket, :error, "Rounds must be between 2 and 8.")}

      true ->
        start_conversation(socket, bot_a, bot_b, topic, rounds)
    end
  end

  defp start_conversation(socket, bot_a, bot_b, topic, rounds) do
    with :ok <- preflight(bot_a),
         :ok <- preflight(bot_b) do
      conversation =
        %Conversation{
          id: "conv-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false),
          bot_a_id: bot_a.id,
          bot_b_id: bot_b.id,
          topic: topic,
          rounds: rounds,
          status: "running"
        }
        |> Repo.insert!()

      case Conversations.start(conversation.id) do
        :ok ->
          {:noreply, push_navigate(socket, to: "/conversations/#{conversation.id}")}

        {:error, reason} ->
          {:noreply, assign(socket, :error, "Could not start: #{inspect(reason)}")}
      end
    else
      {:error, reason} -> {:noreply, assign(socket, :error, "Model not ready: " <> reason)}
    end
  end

  defp preflight(bot), do: KnotraBots.model_status(bot.model)

  defp parse_rounds(value) do
    case Integer.parse(value || "") do
      {rounds, ""} when rounds in 2..8 -> rounds
      _ -> nil
    end
  end

  defp assign_conversations(socket), do: assign(socket, :conversations, Conversations.list())

  defp bot_names, do: Bots.names()

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <header class="top">
        <h1>Conversations</h1>
        <p>Two bots talk for a fixed number of turns; every turn is one durable execution.</p>
      </header>

      <form :if={@bots != []} id="new-conversation" phx-submit="create" class="card form">
        <h2>New conversation</h2>
        <label>
          Bot A
          <select name="bot_a_id">
            <option :for={bot <- @bots} value={bot.id}>{bot.name}</option>
          </select>
        </label>
        <label>
          Bot B
          <select name="bot_b_id">
            <option :for={bot <- @bots} value={bot.id} selected={select_second(bot, @bots)}>
              {bot.name}
            </option>
          </select>
        </label>
        <label>
          Topic <input type="text" name="topic" placeholder="Shipping delays" required />
        </label>
        <label>
          Rounds <input type="number" name="rounds" value="4" min="2" max="8" />
        </label>
        <button type="submit">Start</button>
      </form>

      <p :if={@bots == []} class="empty">Create a bot first.</p>
      <p :if={@error} class="error" data-testid="conversation-error">{@error}</p>

      <section class="conversations">
        <article
          :for={conversation <- @conversations}
          class="card"
          data-conversation-id={conversation.id}
        >
          <header class="row">
            <a href={"/conversations/#{conversation.id}"} class="topic">{conversation.topic}</a>
            <span class={"badge badge-" <> conversation.status}>{conversation.status}</span>
            <span class="version">
              {Conversations.completed_count(conversation.id)}/{conversation.rounds}
            </span>
          </header>
          <p class="muted">
            {@bot_names[conversation.bot_a_id]} → {@bot_names[conversation.bot_b_id]}
          </p>
        </article>
      </section>
    </div>
    """
  end

  defp select_second(bot, [first | _]), do: bot.id != first.id
end
