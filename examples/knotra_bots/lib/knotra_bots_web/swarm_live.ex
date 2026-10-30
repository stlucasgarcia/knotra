defmodule KnotraBotsWeb.SwarmLive do
  @moduledoc """
  Runs one swarm over a channel's agents and shows the merged or selected result.

  Members are non-durable executions with declared read-only tools, so this page
  never performs a consequential operation; durable chat replies keep the
  human approval gate. A run executes in a supervised task and reports back as a
  message, so the LiveView stays responsive while the swarm works.
  """
  use Phoenix.LiveView

  import KnotraBotsWeb.Components

  alias KnotraBots.{Channels, Swarms}

  @impl true
  def mount(_params, _session, socket) do
    channels = Channels.list()
    channel = List.first(channels)

    {:ok,
     socket
     |> assign(:channels, channels)
     |> assign(:channel, channel)
     |> assign(:agents, agents(channel))
     |> assign(:modes, Swarms.modes())
     |> assign(:scenarios, Swarms.scenarios())
     |> assign(:mode, :debate)
     |> assign(:goal, "")
     |> assign(:running, false)
     |> assign(:result, nil)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_event("use_scenario", %{"id" => id}, socket) do
    case Swarms.scenario(id) do
      nil ->
        {:noreply, socket}

      scenario ->
        channel =
          find_channel_by_name(socket.assigns.channels, scenario.channel) ||
            socket.assigns.channel

        {:noreply,
         socket
         |> assign(:channel, channel)
         |> assign(:agents, agents(channel))
         |> assign(:mode, scenario.mode)
         |> assign(:goal, scenario.goal)
         |> assign(:result, nil)
         |> assign(:error, nil)}
    end
  end

  def handle_event("change", params, socket) do
    channel = find_channel(socket.assigns.channels, params["channel_id"])
    mode = mode(params["mode"], socket.assigns.mode)

    {:noreply,
     socket
     |> assign(:channel, channel)
     |> assign(:agents, agents(channel))
     |> assign(:mode, mode)
     |> assign(:goal, params["goal"] || "")}
  end

  def handle_event("run", _params, %{assigns: %{running: true}} = socket), do: {:noreply, socket}

  def handle_event("run", _params, socket) do
    case {socket.assigns.channel, String.trim(socket.assigns.goal)} do
      {nil, _goal} ->
        {:noreply, assign(socket, :error, "Create a channel first.")}

      {_channel, ""} ->
        {:noreply, assign(socket, :error, "Write a goal for the swarm.")}

      {_channel, goal} ->
        start(socket, goal)
    end
  end

  @impl true
  def handle_info({:swarm_result, {:ok, result}}, socket) do
    {:noreply, socket |> assign(:running, false) |> assign(:result, result)}
  end

  def handle_info({:swarm_result, {:error, {:incomplete, result}}}, socket) do
    {:noreply, socket |> assign(:running, false) |> assign(:result, result)}
  end

  def handle_info({:swarm_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:error, "Swarm failed: #{inspect(reason)}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp start(socket, goal) do
    parent = self()
    agents = socket.assigns.agents
    mode = socket.assigns.mode

    case Task.Supervisor.start_child(KnotraBots.TaskSupervisor, fn ->
           send(parent, {:swarm_result, Swarms.run(agents, mode, goal)})
         end) do
      {:ok, _pid} ->
        {:noreply,
         socket
         |> assign(:running, true)
         |> assign(:result, nil)
         |> assign(:error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not start the swarm: #{inspect(reason)}")}
    end
  end

  defp agents(nil), do: []
  defp agents(channel), do: Channels.agents(channel.id)

  defp find_channel(channels, id), do: Enum.find(channels, &(&1.id == id))
  defp find_channel_by_name(channels, name), do: Enum.find(channels, &(&1.name == name))

  defp mode_title(modes, mode),
    do: Enum.find_value(modes, fn option -> option.mode == mode && option.title end)

  defp swarm_error(:no_attempts),
    do: "no attempt completed — see the per-part errors below"

  defp swarm_error(other), do: inspect(other)

  defp part_error(error), do: Swarms.error_label(error)

  defp tools_label([]), do: "none"
  defp tools_label(tools), do: Enum.join(tools, ", ")

  defp prompt_preview(prompt) do
    if String.length(prompt) > 180,
      do: String.slice(prompt, 0, 180) <> "…",
      else: prompt
  end

  defp selected_label(tasks, selected) do
    case Enum.find(tasks, &(&1.id == selected)) do
      nil -> to_string(selected)
      part -> "#{part_label(part.id)} by #{part.agent || "unassigned"}"
    end
  end

  defp mode(label, fallback) do
    case Swarms.fetch_mode(label) do
      {:ok, mode} -> mode
      {:error, _reason} -> fallback
    end
  end

  defp part_label(id) when is_binary(id), do: id
  defp part_label(index), do: "attempt-#{index + 1}"

  defp count(nil, _key), do: "—"
  defp count(counts, key), do: counts |> Map.get(key, 0) |> to_string()

  defp elapsed_label(nil), do: "—"
  defp elapsed_label(ms), do: "#{ms} ms"

  defp selected_class(mode, mode), do: " mode-option-selected"
  defp selected_class(_selected, _mode), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <.shell channels={@channels} active={nil}>
      <div class="page">
        <header class="top">
          <h1>Swarms</h1>
          <p>
            One goal, several agents, three coordination shapes. Load a scenario or write your own.
          </p>
        </header>

        <section :if={@scenarios != []} class="scenarios">
          <h2>Try a scenario</h2>
          <div class="scenario-grid">
            <article
              :for={scenario <- @scenarios}
              class="scenario-card"
              data-testid={"scenario-" <> scenario.id}
            >
              <div class="row">
                <span class="badge">{mode_title(@modes, scenario.mode)}</span>
                <strong>{scenario.title}</strong>
              </div>
              <p>{scenario.why}</p>
              <p class="scenario-goal">{scenario.goal}</p>
              <button
                type="button"
                class="ghost"
                phx-click="use_scenario"
                phx-value-id={scenario.id}
              >
                Load scenario
              </button>
            </article>
          </div>
        </section>

        <form id="swarm-form" phx-change="change" phx-submit="run" class="card form">
          <label>
            Channel
            <select name="channel_id">
              <option
                :for={channel <- @channels}
                value={channel.id}
                selected={@channel && channel.id == @channel.id}
              >
                #{channel.name}
              </option>
            </select>
          </label>

          <fieldset class="mode-options">
            <legend>Mode</legend>

            <label
              :for={option <- @modes}
              class={"mode-option" <> selected_class(@mode, option.mode)}
            >
              <input
                type="radio"
                name="mode"
                value={option.label}
                checked={option.mode == @mode}
              />
              <span class="mode-title">{option.title}</span>
              <span class="mode-desc">{option.description}</span>
              <span class="mode-use">Use for: {option.use_case}</span>
            </label>
          </fieldset>

          <label>
            Goal <textarea
              name="goal"
              rows="3"
              placeholder="Audit the hoodie launch, or choose the best retention offer"
              required
            >{@goal}</textarea>
          </label>

          <button type="submit" disabled={@running or @channel == nil}>
            {if @running, do: "Running…", else: "Run swarm"}
          </button>
        </form>

        <p :if={@error} class="error">{@error}</p>

        <section :if={@result} class="card swarm-result" data-testid="swarm-result">
          <h2>
            Swarm {@result.status} · {Swarms.label(@result.mode)} · {@result.elapsed_ms} ms
          </h2>

          <p :if={@result.status == :failed and @result.error} class="error">
            Swarm error: {swarm_error(@result.error)}
          </p>

          <p class="swarm-meta">
            Conversation <code>{@result.swarm_id}</code>
            — each part is traced under it in <a href="/observability">Observability</a>.
          </p>

          <section
            :if={@result.mode == :coordinator}
            class="coordinator-plan"
            data-testid="coordinator-plan"
          >
            <h3>Coordinator plan</h3>
            <p class="coordinator-meta">
              {length(@result.created_agents)} created agents · {length(@result.agent_details)} members
            </p>

            <div class="agent-grid">
              <article
                :for={agent <- @result.agent_details}
                class={["agent-card", agent.created && "agent-card-created"]}
                data-testid={"agent-detail-" <> agent.name}
              >
                <header class="row">
                  <strong>{agent.name}</strong>
                  <span class="badge">{if agent.created, do: "created", else: "existing"}</span>
                </header>
                <p class="muted">tools: {tools_label(agent.tools)}</p>
                <p :if={agent.prompt not in [nil, ""]} class="agent-prompt-preview">
                  {prompt_preview(agent.prompt)}
                </p>
                <details :if={agent.prompt not in [nil, ""]} class="agent-prompt">
                  <summary>Full prompt</summary>
                  <pre>{agent.prompt}</pre>
                </details>
                <code class="agent-version">{agent.version}</code>
              </article>
            </div>
          </section>

          <p :if={@result.selected != nil} class="swarm-selected">
            Selected: <strong>{selected_label(@result.tasks, @result.selected)}</strong>
          </p>

          <div
            :if={@result.escalations != []}
            class="swarm-escalations"
            data-testid="swarm-escalations"
          >
            <h3>Escalated writes</h3>
            <ul>
              <li :for={escalation <- @result.escalations}>
                <code>{escalation.tool}</code> by <strong>{escalation.agent}</strong>
                <span>{inspect(escalation.arguments)}</span>
                <span class="muted">→ {inspect(escalation.reason)}</span>
              </li>
            </ul>
          </div>

          <pre class="swarm-output">{@result.output}</pre>

          <table class="swarm-tasks">
            <thead>
              <tr>
                <th>Part</th><th>Agent</th><th :if={@result.mode == :coordinator}>Iteration</th><th>
                  Status
                </th><th>Turns</th><th>Tools</th><th>Elapsed</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={part <- @result.tasks}>
                <td>{part_label(part.id)}</td>
                <td>{part.agent || "unassigned"}</td>
                <td :if={@result.mode == :coordinator}>{part.iteration}</td>
                <td>
                  {if part.status == :completed, do: "ok", else: part_error(part.error)}
                </td>
                <td>{count(part.counts, :turns)}</td>
                <td>{count(part.counts, :tools)}</td>
                <td>{elapsed_label(part.elapsed_ms)}</td>
              </tr>
            </tbody>
          </table>

          <div :if={@result.tasks != []} class="swarm-parts">
            <details :for={part <- @result.tasks} class="swarm-part">
              <summary>
                {part_label(part.id)} · {part.agent || "unassigned"} · {if part.status == :completed,
                  do: "ok",
                  else: "failed"}
              </summary>
              <pre>{part.output || "—"}</pre>
              <p :if={part.error} class="error">{part_error(part.error)}</p>
            </details>
          </div>
        </section>
      </div>
    </.shell>
    """
  end
end
