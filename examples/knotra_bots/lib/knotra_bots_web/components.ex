defmodule KnotraBotsWeb.Components do
  @moduledoc false
  use Phoenix.Component

  attr :channels, :list, required: true
  attr :active, :any, default: nil
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="app">
      <aside class="sidebar">
        <a class="brand" href="/">
          <span class="brand-mark">K</span>
          <span>Knotra<span class="brand-sub">chat</span></span>
        </a>

        <nav class="chan-nav" data-testid="channels">
          <p class="side-label">Channels</p>
          <a
            :for={channel <- @channels}
            href={"/channels/#{channel.id}"}
            class={"chan-link" <> active_class(@active, channel.id)}
          >
            <span class="hash">#</span>{channel.name}
          </a>
          <a class="chan-link new" href="/channels"><span class="hash">+</span>New channel</a>
        </nav>

        <a class="side-agents" href="/agents">
          <span class="side-label">Agents</span>
          <span>Manage teammates →</span>
        </a>

        <a class="side-agents" href="/observability">
          <span class="side-label">Observability</span>
          <span>Live execution traces →</span>
        </a>

        <div class="side-foot">
          <span class="dot"></span>tenant <code>{KnotraBots.tenant()}</code>
        </div>
      </aside>

      <main class="main">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :size, :string, default: "md"

  def avatar(assigns) do
    assigns = assign(assigns, :color, rem(:erlang.phash2(assigns.agent.handle), 6) + 1)

    ~H"""
    <span class={"avatar avatar-#{@color} avatar-#{@size}"} title={@agent.name}>
      {initials(@agent.name)}
    </span>
    """
  end

  attr :status, :string, required: true

  def status_badge(assigns) do
    assigns = assign(assigns, :label, status_label(assigns.status))

    ~H"""
    <span class={"status status-#{@status}"}>
      <span class="status-dot"></span>{@label}
    </span>
    """
  end

  attr :text, :string, required: true

  def message_body(assigns) do
    assigns = assign(assigns, :segments, segments(assigns.text))

    ~H"""
    <p class="message-body">
      <span :for={{text, mention?} <- @segments} class={if mention?, do: "mention"}>{text}</span>
    </p>
    """
  end

  attr :at, :any, required: true

  def timestamp(assigns) do
    assigns = assign(assigns, :label, Calendar.strftime(assigns.at, "%H:%M"))

    ~H"""
    <time>{@label}</time>
    """
  end

  defp active_class(active, id) when active == id, do: " active"
  defp active_class(_active, _id), do: ""

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp status_label("queued"), do: "queued"
  defp status_label("running"), do: "working"
  defp status_label("waiting"), do: "needs you"
  defp status_label("completed"), do: "done"
  defp status_label("failed"), do: "failed"
  defp status_label("blocked"), do: "blocked"
  defp status_label("rejected"), do: "rejected"
  defp status_label("cancelled"), do: "cancelled"
  defp status_label("expired"), do: "expired"
  defp status_label(status), do: status

  defp segments(text) do
    ~r/(@[a-z0-9][a-z0-9_-]*)/i
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.map(fn part -> {part, String.starts_with?(part, "@")} end)
  end
end
