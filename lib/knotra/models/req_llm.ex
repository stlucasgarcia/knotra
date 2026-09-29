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
    usage_key = :erlang.alias()

    try do
      with {:ok, context} <- context(request),
           {:ok, tools} <- tools(request.tools),
           {:ok, response} <-
             ReqLLM.generate_text(
               Keyword.fetch!(opts, :model),
               context,
               options(opts, tools, usage_key)
             ) do
        response = if usage_reported?(usage_key), do: response, else: %{response | usage: nil}
        decode(response, tools)
      else
        _ -> {:error, :model_error}
      end
    after
      :erlang.unalias(usage_key)
      usage_reported?(usage_key)
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

        case append_exchange(context, exchange.reply, results) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp append_exchange(
         context,
         %Knotra.Reply{calls: [], continuation: %ReqLLM.Message{role: :assistant} = message},
         []
       ) do
    {:ok, ReqLLM.Context.append(context, message)}
  end

  defp append_exchange(context, reply, results) do
    ReqLLM.Context.append_tool_exchange(context, reply.continuation, results)
  end

  @doc false
  def decode(response, tools) do
    outcome = ReqLLM.Response.classify(response)

    resolutions =
      Enum.map(ReqLLM.Response.tool_calls(response), &ReqLLM.ToolCall.resolve(&1, tools))

    cond do
      outcome.finish_reason not in [:stop, :tool_calls] ->
        {:error, :incomplete_response}

      Enum.any?(resolutions, &(&1.state != :valid)) ->
        {:error, :unsupported_tool_call}

      outcome.type == :tool_calls and resolutions == [] ->
        {:error, :incomplete_response}

      resolutions == [] and String.trim(outcome.text) == "" ->
        {:error, :empty_response}

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

  defp usage_reported?(ref, reported \\ false) do
    receive do
      {__MODULE__, ^ref, flag} -> usage_reported?(ref, flag)
    after
      0 -> reported
    end
  end

  defp options(opts, tools, usage_key) do
    # ReqLLM may run HTTP hooks in its timeout task. A per-call alias carries only
    # presence back to the caller; unalias drops late sends after errors/timeouts.
    # Capture before ReqLLM 1.24 normalizes absent wire usage to zeros.
    capture_usage = fn request ->
      Req.Request.append_response_steps(request,
        knotra_usage: fn {request, response} ->
          send(usage_key, {__MODULE__, usage_key, wire_usage?(response.body)})
          {request, response}
        end
      )
    end

    opts
    |> Keyword.get(:options, [])
    |> Keyword.put(:tools, tools)
    |> Keyword.put(:max_retries, 0)
    |> Keyword.update(:req_http_options, [max_retries: 0, plugins: [capture_usage]], fn http ->
      http
      |> Keyword.put(:max_retries, 0)
      |> Keyword.update(:plugins, [capture_usage], &(&1 ++ [capture_usage]))
    end)
  end

  defp wire_usage?(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> wire_usage?(decoded)
      _ -> false
    end
  end

  defp wire_usage?(body) when is_map(body) do
    Enum.any?(["usage", "usageMetadata", "usage_metadata", "token_usage"], fn key ->
      case body[key] do
        usage when is_map(usage) and map_size(usage) > 0 -> true
        _ -> false
      end
    end)
  end

  defp wire_usage?(_), do: false

  defp tools(definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, tools} ->
      case Knotra.ToolRuntimes.Default.schema(definition) do
        {:ok, tool} -> {:cont, {:ok, tools ++ [tool]}}
        error -> {:halt, error}
      end
    end)
  end
end
