defmodule KnotraBots.Models.ChatFake do
  @moduledoc """
  Offline deterministic chat model.

  It exercises the chat contract without a provider: a `hand off to @handle`
  instruction in the system prompt produces an agent-to-agent mention, an order id
  becomes a `lookup` call, a notice request becomes a `notify` call, and
  `clarify` asks for a detail. Tool and answer continuations complete with their
  result, so the whole durable lifecycle runs offline.
  """
  @behaviour Knotra.Model

  @impl true
  def checkpoint_version, do: 1

  @impl true
  def call(%{exchanges: exchanges, input: input, tools: tools}, opts) do
    name = Keyword.get(opts, :name, "Agent")
    prompt = Keyword.get(opts, :system_prompt, "")

    case List.last(exchanges) do
      %{results: [%{output: output}]} ->
        {:ok, %Knotra.Reply{text: "Done. The result was: #{output}"}}

      %{answer: answer} ->
        {:ok, %Knotra.Reply{text: "#{name} received: #{answer}"}}

      nil ->
        first_turn(input, tools, prompt, name)

      _ ->
        {:ok, %Knotra.Reply{text: "#{name} is ready for the next step."}}
    end
  end

  defp first_turn(input, tools, prompt, name) do
    line = last_human_line(input)
    handle = handoff(line, prompt)
    order = order_id(line)

    cond do
      clarify?(line) ->
        question("What details should I include?")

      notify?(line, tools) ->
        proposal("notify", %{"to" => "ops", "message" => line})

      handle != nil ->
        {:ok, %Knotra.Reply{text: "Handing this to @#{handle}."}}

      order != nil ->
        proposal("lookup", %{"query" => order})

      Enum.any?(tools, &(&1.name == "lookup")) and lookup_question?(line) ->
        question("Which order should I look up?")

      true ->
        {:ok, %Knotra.Reply{text: "#{name} received: #{line}"}}
    end
  end

  defp clarify?(line), do: Regex.match?(~r/\b(clarify|clarification|ambiguous|details?)\b/i, line)

  defp notify?(line, tools) do
    line != "" and Enum.any?(tools, &(&1.name == "notify")) and
      Regex.match?(~r/\b(notify|send|notice|ping)\b/i, line)
  end

  defp lookup_question?(line),
    do: Regex.match?(~r/\b(lookup|look up|order|status)\b/i, line)

  defp order_question?(line),
    do: Regex.match?(~r/\b(order|shipment|shipping|status|tracking)\b/i, line)

  defp handoff(line, prompt) do
    with true <- order_question?(line),
         [_, handle] <-
           Regex.run(~r/hand off[^@\n]*@([a-z0-9][a-z0-9_-]*)/i, prompt) do
      handle
    else
      _ -> nil
    end
  end

  defp order_id(line) do
    case Regex.run(~r/\bord-\d+\b/i, line) do
      [id | _] -> id
      _ -> nil
    end
  end

  defp question(prompt) do
    {:ok, %Knotra.Reply{text: prompt, input_request: %{prompt: prompt}}}
  end

  defp proposal(name, arguments) do
    {:ok, %Knotra.Reply{calls: [%{id: "#{name}-1", name: name, arguments: arguments}]}}
  end

  # The latest human turn, so a handoff still sees the request that started it.
  defp last_human_line(input) do
    input
    |> String.split("\n\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "Human: "))
    |> List.last()
    |> case do
      nil -> ""
      line -> String.replace_prefix(line, "Human: ", "")
    end
  end
end
