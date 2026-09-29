defmodule Knotra.Loops.Default do
  @moduledoc "Sequential model → authorized tools → model strategy."
  @behaviour Knotra.Loop

  @impl true
  def init(_opts), do: :model

  @impl true
  def next(_view, :model), do: {:model, :reply}

  def next(%{last: {:model, %{calls: [], text: text}}}, :reply), do: {:done, text}
  def next(%{last: {:model, %{calls: calls}}}, :reply), do: next(%{}, {:tools, calls})
  def next(_view, {:tools, []}), do: {:model, :reply}
  def next(_view, {:tools, [call | rest]}), do: {:tool, call, {:tools, rest}}
end
