defmodule Knotra.Models.ReqLLM do
  @moduledoc """
  One buffered ReqLLM call. Configure `model:` and optional `options:` containing
  ReqLLM provider options. Tools always come from the host registry, not options.
  Raw provider errors are deliberately not copied into public execution records.
  Continuations retain canonical messages, including provider reasoning metadata.
  """
  @behaviour Knotra.Model

  @impl true
  def call(request, opts) do
    with {:ok, context} <- context(request),
         {:ok, tools} <- tools(request.tools),
         {:ok, response} <-
           ReqLLM.generate_text(
             Keyword.fetch!(opts, :model),
             context,
             options(opts, tools)
           ) do
      decode(response, tools)
    else
      _ -> {:error, :model_error}
    end
  end

  @doc false
  def context(%{input: input, exchanges: exchanges}) do
    with {:ok, context} <- ReqLLM.Context.normalize(input) do
      Enum.reduce_while(exchanges, {:ok, context}, fn exchange, {:ok, context} ->
        results =
          Enum.map(exchange.results, fn %{call: call, output: output} ->
            ReqLLM.Context.tool_result(call.id, call.name, output)
          end)

        case ReqLLM.Context.append_tool_exchange(context, exchange.reply.continuation, results) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc false
  def decode(response, tools) do
    outcome = ReqLLM.Response.classify(response)

    resolutions =
      Enum.map(ReqLLM.Response.tool_calls(response), &ReqLLM.ToolCall.resolve(&1, tools))

    cond do
      outcome.finish_reason in [:length, :content_filter, :error] ->
        {:error, :incomplete_response}

      Enum.any?(resolutions, &(&1.state != :valid)) ->
        {:error, :unsupported_tool_call}

      outcome.type == :tool_calls and resolutions == [] ->
        {:error, :incomplete_response}

      true ->
        calls =
          Enum.map(resolutions, fn resolved ->
            %{id: resolved.id, name: resolved.name, arguments: resolved.arguments}
          end)

        {:ok,
         %Knotra.Reply{
           text: outcome.text,
           calls: calls,
           usage: ReqLLM.Response.usage(response),
           continuation: response.message
         }}
    end
  end

  defp options(opts, tools) do
    opts
    |> Keyword.get(:options, [])
    |> Keyword.put(:tools, tools)
    |> Keyword.put(:max_retries, 0)
    |> Keyword.update(:req_http_options, [max_retries: 0], &Keyword.put(&1, :max_retries, 0))
  end

  defp tools(definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, tools} ->
      case Knotra.ToolRuntimes.Default.schema(definition) do
        {:ok, tool} -> {:cont, {:ok, tools ++ [tool]}}
        error -> {:halt, error}
      end
    end)
  end
end
