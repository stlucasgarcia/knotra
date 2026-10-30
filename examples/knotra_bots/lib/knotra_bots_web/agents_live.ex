defmodule KnotraBotsWeb.AgentsLive do
  @moduledoc """
  Create, edit and delete the host-owned agents used in channels.

  Editing bumps an agent's revision, which changes its durable definition version.
  Deleting is refused while a channel lists the agent.
  """
  use Phoenix.LiveView

  import KnotraBotsWeb.Components

  alias KnotraBots.{Agents, Channels}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:channels, Channels.list())
     |> assign(:models, models())
     |> assign(:tool_names, Agents.tool_names())
     |> assign(:error, nil)
     |> assign_agents()}
  end

  @impl true
  def handle_event("create", params, socket) do
    case Agents.create(agent_attrs(params)) do
      {:ok, _agent} -> {:noreply, socket |> assign(:error, nil) |> assign_agents()}
      {:error, changeset} -> {:noreply, assign(socket, :error, changeset_message(changeset))}
    end
  end

  def handle_event("update", %{"agent_id" => id} = params, socket) do
    case Agents.get(id) do
      nil ->
        {:noreply, assign(socket, :error, "That agent no longer exists.")}

      %{revision: revision} = agent ->
        if to_string(revision) == params["revision"] do
          case Agents.update(agent, agent_attrs(params)) do
            {:ok, _agent} ->
              {:noreply, socket |> assign(:error, nil) |> assign_agents()}

            {:error, :stale} ->
              {:noreply, assign(socket, :error, stale_message())}

            {:error, changeset} ->
              {:noreply, assign(socket, :error, changeset_message(changeset))}
          end
        else
          {:noreply, assign(socket, :error, stale_message())}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Agents.get(id) do
      nil ->
        {:noreply, assign(socket, :error, "That agent no longer exists.")}

      agent ->
        case Agents.delete(agent) do
          {:ok, _agent} ->
            {:noreply, socket |> assign(:error, nil) |> assign_agents()}

          {:error, :referenced} ->
            {:noreply,
             assign(socket, :error, "Cannot delete #{agent.name}: a channel references it.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :error, changeset_message(changeset))}
        end
    end
  end

  defp assign_agents(socket), do: assign(socket, :agents, Agents.list())

  defp agent_attrs(params) do
    %{
      "name" => params["name"],
      "handle" => params["handle"] || "",
      "system_prompt" => params["system_prompt"] || "",
      "model" => params["model"],
      "tools" => params |> Map.get("tools", []) |> List.wrap() |> Enum.join(",")
    }
  end

  defp models do
    Enum.map(KnotraBots.catalog(), fn model -> {model, model_label(model)} end)
  end

  defp model_label("fake"), do: "offline"

  defp model_label(model) do
    case KnotraBots.model_status(model) do
      :ok -> "key ok"
      {:error, _} -> "key missing"
    end
  end

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _opts}} ->
      "#{field} #{message}"
    end)
  end

  defp stale_message,
    do: "This agent changed in another tab. Reload the page and try again."

  @impl true
  def render(assigns) do
    ~H"""
    <.shell channels={@channels} active={nil}>
      <div class="page">
        <header class="top">
          <h1>Agents</h1>
          <p>
            Teammates with a handle, a prompt, a model and tools. Mention them in a
            channel as <code>@handle</code>.
          </p>
        </header>

        <form id="new-agent" phx-submit="create" class="card form">
          <h2>New agent</h2>
          <.agent_fields agent={nil} models={@models} tool_names={@tool_names} />
          <button type="submit">Create</button>
        </form>

        <p :if={@error} class="error" data-testid="agent-error">{@error}</p>

        <section class="agents">
          <article :for={agent <- @agents} class="card" data-agent-id={agent.id}>
            <header class="row">
              <.avatar agent={agent} size="sm" />
              <strong>{agent.name}</strong>
              <code>@{agent.handle}</code>
              <span class="badge">{agent.model}</span>
              <span class="version">r{agent.revision}</span>
            </header>
            <p class="muted">
              tools: {tools_label(agent)} · {model_label(agent.model)}
            </p>

            <form id={"agent-" <> agent.id} phx-submit="update" class="form">
              <input type="hidden" name="agent_id" value={agent.id} />
              <input type="hidden" name="revision" value={agent.revision} />
              <.agent_fields agent={agent} models={@models} tool_names={@tool_names} />
              <div class="row">
                <button type="submit">Save</button>
                <button
                  type="button"
                  class="ghost"
                  phx-click="delete"
                  phx-value-id={agent.id}
                >
                  Delete
                </button>
              </div>
            </form>
          </article>
        </section>
      </div>
    </.shell>
    """
  end

  defp agent_fields(assigns) do
    ~H"""
    <label>
      Name <input type="text" name="name" value={@agent && @agent.name} required maxlength="80" />
    </label>
    <label>
      Handle
      <input
        type="text"
        name="handle"
        value={@agent && @agent.handle}
        placeholder="auto from name"
        maxlength="32"
      />
    </label>
    <label>
      System prompt <textarea name="system_prompt" rows="3">{@agent && @agent.system_prompt}</textarea>
    </label>
    <label>
      Model
      <select name="model">
        <option
          :for={{model, label} <- @models}
          value={model}
          selected={@agent && @agent.model == model}
        >
          {model} — {label}
        </option>
      </select>
    </label>
    <fieldset class="tools">
      <legend>Tools (chat runs)</legend>
      <label :for={name <- @tool_names}>
        <input
          type="checkbox"
          name="tools[]"
          value={name}
          checked={@agent && name in tools_of(@agent)}
        /> {name}
      </label>
    </fieldset>
    """
  end

  defp tools_of(bot) do
    bot.tools |> String.split(",", trim: true) |> Enum.uniq()
  end

  defp tools_label(agent) do
    case tools_of(agent) do
      [] -> "none"
      names -> Enum.join(names, ", ")
    end
  end
end
