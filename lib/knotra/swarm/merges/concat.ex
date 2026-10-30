defmodule Knotra.Swarm.Merges.Concat do
  @moduledoc """
  Default fan-out and board merge: completed parts in task order, labelled by id.

  Failed parts keep their slot out of the text rather than writing an error into
  the result; the swarm status reports the failure separately.
  """

  @doc false
  def merge(_goal, parts) do
    text =
      parts
      |> Enum.filter(&(&1.status == :completed))
      |> Enum.map_join("\n\n", fn part -> "#{part.id}: #{String.trim(part.output)}" end)

    {:ok, text}
  end
end
