defmodule KnotraBots.Models.ConversationFake do
  @moduledoc """
  Offline deterministic model for bot-to-bot conversations.

  Tool-free: it echoes the last non-empty transcript line, so a later turn's output
  proves it saw the earlier turns. `name` and `round` come from the per-turn model
  options; the model is otherwise stateless and needs no key or network.
  """
  @behaviour Knotra.Model

  @impl true
  def checkpoint_version, do: 1

  @impl true
  def call(%{input: input}, opts) do
    name = Keyword.get(opts, :name, "bot")
    round = Keyword.get(opts, :round, 1)

    {:ok, %Knotra.Reply{text: "[#{name}] round #{round}: acknowledged #{last_line(input)}"}}
  end

  defp last_line(input) do
    case input |> String.split("\n", trim: true) |> List.last() do
      nil -> "the topic"
      line -> line
    end
  end
end
