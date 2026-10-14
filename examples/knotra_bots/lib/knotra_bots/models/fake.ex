defmodule KnotraBots.Models.Fake do
  @moduledoc """
  Offline deterministic model for tests and the `"fake"` mode.

  It drives one bounded durable round-trip:

  1. ask which order to look up (a clarification input request);
  2. after that answer, propose `notify` when the definition offers it, otherwise
     the read-only `lookup`;
  3. after the tool result, complete with a text mentioning the output.

  No network access. `checkpoint_version/0` opts the continuation into durable
  checkpointing.
  """

  @behaviour Knotra.Model

  @prompt "Which order should I look up?"

  @impl true
  def checkpoint_version, do: 1

  @impl true
  def call(%{tools: tools} = request, _opts) do
    case List.last(request.exchanges) do
      %{results: [%{output: output}]} ->
        {:ok, %Knotra.Reply{text: "Done. The result was: #{output}"}}

      %{answer: answer} ->
        {:ok, proposal(tools, answer)}

      nil ->
        {:ok, question()}

      _ ->
        {:error, :invalid_model_reply}
    end
  end

  defp question do
    %Knotra.Reply{
      text: @prompt,
      input_request: %{prompt: @prompt},
      continuation: ReqLLM.Context.assistant(@prompt)
    }
  end

  defp proposal(tools, answer) do
    call =
      if Enum.any?(tools, &(&1.name == "notify")) do
        %{id: "notify-1", name: "notify", arguments: %{"to" => "ops", "message" => answer}}
      else
        %{id: "lookup-1", name: "lookup", arguments: %{"query" => answer}}
      end

    %Knotra.Reply{calls: [call], continuation: continuation(call)}
  end

  defp continuation(call) do
    ReqLLM.Context.assistant("",
      tool_calls: [
        ReqLLM.ToolCall.new(call.id, call.name, JSON.encode!(call.arguments))
      ]
    )
  end
end
