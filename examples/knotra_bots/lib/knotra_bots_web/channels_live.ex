defmodule KnotraBotsWeb.ChannelsLive do
  @moduledoc """
  Lists channels and creates one with a chosen set of agents.

  The first selected agent (alphabetically) becomes the default responder; a
  message with no `@mention` goes to it.
  """
  use Phoenix.LiveView

  import KnotraBotsWeb.Components

  alias KnotraBots.{Agents, Channels}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:agents, Agents.list())
     |> assign(:error, nil)
     |> assign_channels()}
  end

  @impl true
  def handle_event("create", params, socket) do
    case Channels.create(%{
           "name" => params["name"],
           "topic" => params["topic"],
           "agent_ids" => Map.get(params, "agent_ids", [])
         }) do
      {:ok, channel} ->
        {:noreply, push_navigate(socket, to: "/channels/#{channel.id}")}

      {:error, :no_agents} ->
        {:noreply, assign(socket, :error, "Select at least one agent.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :error, changeset_message(changeset))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, inspect(reason))}
    end
  end

  defp assign_channels(socket) do
    channels = Channels.list()

    assign(socket,
      rows: Enum.map(channels, &{&1, Channels.agents(&1.id)}),
      channels: channels
    )
  end

  defp changeset_message(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _opts}} ->
      "#{field} #{message}"
    end)
  end

  defp handles(agents), do: Enum.map_join(agents, ", ", &"@#{&1.handle}")

  defp agents_count([_]), do: "1 agent"
  defp agents_count(agents), do: "#{length(agents)} agents"

  @impl true
  def render(assigns) do
    ~H"""
    <.shell channels={@channels} active={nil}>
      <div class="page">
        <header class="top">
          <h1>Channels</h1>
          <p>One shared conversation for you and your agents.</p>
        </header>

        <form id="new-channel" phx-submit="create" class="card form">
          <h2>New channel</h2>

          <label>
            Name <input name="name" placeholder="ops" required maxlength="40" />
          </label>

          <label>
            Topic <input name="topic" placeholder="Orders, notices, handoffs" maxlength="160" />
          </label>

          <fieldset class="checks">
            <legend>Agents</legend>
            <label :for={agent <- @agents}>
              <input type="checkbox" name="agent_ids[]" value={agent.id} checked />
              <span>{agent.name} <code>@{agent.handle}</code></span>
            </label>
            <p :if={@agents == []} class="muted">
              No agents yet. <a href="/agents">Create one first.</a>
            </p>
          </fieldset>

          <p class="muted">
            The first selected agent (alphabetically) answers messages without a <code>@mention</code>.
          </p>

          <button type="submit">Create channel</button>
        </form>

        <p :if={@error} class="error" data-testid="channel-error">{@error}</p>

        <section class="channel-list">
          <a
            :for={{channel, agents} <- @rows}
            class="card channel-card"
            href={"/channels/#{channel.id}"}
            data-channel-id={channel.id}
          >
            <header class="row">
              <strong>#{channel.name}</strong>
              <span class="badge">{agents_count(agents)}</span>
            </header>
            <p :if={channel.topic != ""} class="muted">{channel.topic}</p>
            <p class="muted">{handles(agents)}</p>
          </a>
        </section>
      </div>
    </.shell>
    """
  end
end
