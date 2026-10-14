defmodule KnotraBots.Bots do
  @moduledoc """
  Host-owned bot rows and the durable single-run definitions built from them.

  Change a bot's fields through `update/2`: it bumps `revision`, so the definition
  version (`bot-<id>-r<revision>`) changes whenever prompts, tools or model options
  do. Durable submissions pin that version and composition for compatibility checks.
  """

  import Ecto.Query

  alias KnotraBots.{Bot, Conversation, Repo}
  alias KnotraBots.Tools

  @tools %{"lookup" => Tools.Lookup, "notify" => Tools.Notify}

  @assistant_prompt "You are a helpful assistant. Answer concisely."
  @concierge_prompt """
  You are a concierge. When a request asks to send a notice or message, propose the
  notify operation with a recipient and a short message. Otherwise answer concisely.
  """

  @doc "Host tool names a bot may offer; only the single-run path uses them."
  def tool_names, do: Map.keys(@tools)

  def list, do: Repo.all(from(b in Bot, order_by: [asc: b.name]))
  def get(id), do: Repo.get(Bot, id)
  def get!(id), do: Repo.get!(Bot, id)

  @doc """
  Builds the durable definition for a single dashboard run of `bot`.

  `"fake"` selects the offline model used by the dashboard tests and demos; a real
  model goes through `KnotraBots.Models.Logged` with its system prompt as a model
  option.
  """
  def definition(bot, owner) do
    %Knotra.Definition{
      version: "bot-#{bot.id}-r#{bot.revision}",
      model: model(bot),
      tools: tool_modules(bot),
      observer: {Knotra.Observers.Send, owner}
    }
  end

  @doc "Recovers a bot id from a single-run definition version, or nil."
  def bot_id_for_version(version) do
    case Regex.run(~r/^bot-(.+)-r\d+$/, version) do
      [_, id] -> id
      _ -> nil
    end
  end

  @doc "The tool modules a bot offers for single runs."
  def tool_modules(%Bot{tools: tools}), do: Enum.map(split(tools), &Map.fetch!(@tools, &1))

  @doc "Bot id → name map for the LiveViews."
  def names, do: Map.new(list(), &{&1.id, &1.name})

  def create(attrs) do
    %Bot{id: new_id()}
    |> Bot.changeset(attrs)
    |> Repo.insert()
  end

  def create!(attrs) do
    case create(attrs) do
      {:ok, bot} ->
        bot

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  def update(%Bot{} = bot, attrs) do
    bot
    |> Bot.changeset(attrs)
    |> Ecto.Changeset.change(revision: bot.revision + 1)
    |> Repo.update()
  end

  @doc "Deletes a bot unless a conversation references it."
  def delete(%Bot{} = bot) do
    referenced? =
      Repo.exists?(from(c in Conversation, where: c.bot_a_id == ^bot.id or c.bot_b_id == ^bot.id))

    if referenced?, do: {:error, :referenced}, else: Repo.delete(bot)
  end

  @doc """
  Seeds the two default bots when the table is empty.

  The model is the app's configured model, so a `KNOTRA_BOTS_MODEL=fake` (or test)
  run seeds two offline bots while the default run seeds two Gemini bots.
  """
  def seed! do
    if Repo.aggregate(Bot, :count) == 0 do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      model = KnotraBots.configured_model()

      Repo.insert_all(Bot, [
        %{
          id: "assistant",
          name: "Assistant",
          system_prompt: @assistant_prompt,
          model: model,
          tools: "lookup",
          revision: 1,
          inserted_at: now,
          updated_at: now
        },
        %{
          id: "concierge",
          name: "Concierge",
          system_prompt: @concierge_prompt,
          model: model,
          tools: "lookup,notify",
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      ])
    end

    :ok
  end

  defp model(%Bot{model: "fake"}) do
    # The dashboard fake drives clarify → approve; conversations use ConversationFake.
    {KnotraBots.Models.Fake, []}
  end

  defp model(%Bot{} = bot), do: KnotraBots.req_llm_plugin(bot)

  defp split(""), do: []
  defp split(names), do: names |> String.split(",", trim: true) |> Enum.uniq()

  defp new_id, do: "bot-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
end
