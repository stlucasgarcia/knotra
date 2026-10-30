defmodule Knotra.Swarm.Selectors.Longest do
  @moduledoc """
  Default debate selection: the longest completed attempt, lowest index on a tie.

  Length is a deterministic stand-in, not a quality judgment; hosts that need one
  supply their own `:select` function, for example a model-backed judge.
  """

  @doc false
  def select(_goal, attempts) do
    case Enum.filter(attempts, &(&1.status == :completed)) do
      [] ->
        {:error, :no_attempts}

      completed ->
        # max_by keeps the first of equal keys, so the earliest attempt wins a tie.
        {:pick, completed |> Enum.max_by(&byte_size(&1.output)) |> Map.fetch!(:id)}
    end
  end
end
