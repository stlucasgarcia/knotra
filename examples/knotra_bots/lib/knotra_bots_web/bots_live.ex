defmodule KnotraBotsWeb.BotsLive do
  @moduledoc """
  Create, edit and delete the host-owned bots used by single runs and conversations.

  Editing bumps a bot's revision, which changes its durable definition version.
  Deleting is refused while a conversation references the bot.
  """
  use Phoenix.LiveView

  alias KnotraBots.Bots

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:models, models())
     |> assign(:tool_names, Bots.tool_names())
     |> assign(:error, nil)
     |> assign_bots()}
  end

  @impl true
  def handle_event("create", params, socket) do
    case Bots.create(bot_attrs(params)) do
      {:ok, _bot} -> {:noreply, socket |> assign(:error, nil) |> assign_bots()}
      {:error, changeset} -> {:noreply, assign(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("update", %{"bot_id" => id} = params, socket) do
    case Bots.get(id) do
      nil ->
        {:noreply, assign(socket, :error, "That bot no longer exists.")}

      bot ->
        case Bots.update(bot, bot_attrs(params)) do
          {:ok, _bot} -> {:noreply, socket |> assign(:error, nil) |> assign_bots()}
          {:error, changeset} -> {:noreply, assign(socket, :error, error_message(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Bots.get(id) do
      nil ->
        {:noreply, assign(socket, :error, "That bot no longer exists.")}

      bot ->
        case Bots.delete(bot) do
          {:ok, _bot} ->
            {:noreply, socket |> assign(:error, nil) |> assign_bots()}

          {:error, :referenced} ->
            {:noreply,
             assign(socket, :error, "Cannot delete #{bot.name}: a conversation references it.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :error, error_message(changeset))}
        end
    end
  end

  defp assign_bots(socket), do: assign(socket, :bots, Bots.list())

  defp bot_attrs(params) do
    %{
      "name" => params["name"],
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

  defp error_message(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, {message, _}} -> "#{field} #{message}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <header class="top">
        <h1>Bots</h1>
        <p>Host-owned rows. Editing a bot bumps its revision and changes its definition version.</p>
      </header>

      <form id="new-bot" phx-submit="create" class="card form">
        <h2>New bot</h2>
        <.bot_fields bot={nil} models={@models} tool_names={@tool_names} />
        <button type="submit">Create</button>
      </form>

      <p :if={@error} class="error" data-testid="bot-error">{@error}</p>

      <section class="bots">
        <article :for={bot <- @bots} class="card" data-bot-id={bot.id}>
          <header class="row">
            <strong>{bot.name}</strong>
            <span class="badge">{bot.model}</span>
            <span class="version">r{bot.revision}</span>
          </header>
          <p class="muted">
            tools: {tools_label(bot)} · {model_label(bot.model)}
          </p>
          <form id={"bot-" <> bot.id} phx-submit="update" class="form">
            <input type="hidden" name="bot_id" value={bot.id} />
            <.bot_fields bot={bot} models={@models} tool_names={@tool_names} />
            <button type="submit">Save</button>
            <button type="button" phx-click="delete" phx-value-id={bot.id}>Delete</button>
          </form>
        </article>
      </section>
    </div>
    """
  end

  defp bot_fields(assigns) do
    ~H"""
    <label>
      Name <input type="text" name="name" value={@bot && @bot.name} required />
    </label>
    <label>
      System prompt <textarea name="system_prompt" rows="3">{@bot && @bot.system_prompt}</textarea>
    </label>
    <label>
      Model
      <select name="model">
        <option :for={{model, label} <- @models} value={model} selected={@bot && @bot.model == model}>
          {model} — {label}
        </option>
      </select>
    </label>
    <fieldset class="tools">
      <legend>Tools (single runs)</legend>
      <label :for={name <- @tool_names}>
        <input
          type="checkbox"
          name="tools[]"
          value={name}
          checked={@bot && name in tools_of(@bot)}
        /> {name}
      </label>
    </fieldset>
    """
  end

  defp tools_of(bot) do
    bot.tools |> String.split(",", trim: true) |> Enum.uniq()
  end

  defp tools_label(bot) do
    case tools_of(bot) do
      [] -> "none"
      names -> Enum.join(names, ", ")
    end
  end
end
