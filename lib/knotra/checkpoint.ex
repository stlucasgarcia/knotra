defmodule Knotra.Checkpoint do
  @moduledoc false
  @max_bytes 2_000_000
  @structs [Knotra.Reply, ReqLLM.Message, ReqLLM.Message.ContentPart, ReqLLM.ToolCall]

  # Only inert data, never functions, processes, ports or references. Do not decode
  # arbitrary Erlang terms, create atoms, or serialize the execution process state.
  def encode(value) do
    if data?(value) do
      bytes = :erlang.term_to_binary(value)
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: {:error, :checkpoint_too_large}
    else
      {:error, :unsupported_checkpoint}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    Enum.each(@structs ++ [Knotra.Execution, Knotra.Loops.Default], &Code.ensure_loaded/1)

    try do
      value = :erlang.binary_to_term(bytes, [:safe])
      if data?(value), do: {:ok, value}, else: {:error, :unsupported_checkpoint}
    rescue
      ArgumentError -> {:error, :unsupported_checkpoint}
    end
  end

  def decode(_), do: {:error, :unsupported_checkpoint}

  defp data?(value) when is_binary(value) or is_atom(value) or is_number(value), do: true
  defp data?([]), do: true
  defp data?([head | tail]), do: data?(head) and list?(tail)
  defp data?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.all?(&data?/1)

  defp data?(%{__struct__: module} = value) when module in @structs,
    do: value |> Map.from_struct() |> data?()

  defp data?(%{__struct__: _}), do: false

  defp data?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> data?(key) and data?(item) end)

  defp data?(_), do: false
  defp list?([]), do: true
  defp list?([head | tail]), do: data?(head) and list?(tail)
  defp list?(_), do: false
end
