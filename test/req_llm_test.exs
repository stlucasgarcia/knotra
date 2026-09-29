defmodule Knotra.Models.ReqLLMTest do
  use ExUnit.Case, async: true
  alias Knotra.Models.ReqLLM, as: Adapter

  defmodule OfflineHTTP do
    def run(request) do
      send(self(), {:http_request, request})

      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "id" => "resp_offline",
           "object" => "response",
           "model" => "gpt-4o-mini",
           "status" => "completed",
           "output" => [
             %{
               "id" => "msg_offline",
               "type" => "message",
               "role" => "assistant",
               "status" => "completed",
               "content" => [
                 %{"type" => "output_text", "text" => "Proposed reply", "annotations" => []}
               ]
             }
           ],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 3, "total_tokens" => 13}
         }
       )}
    end
  end

  defp tool do
    ReqLLM.Tool.new!(
      name: "receipt",
      description: "Read a receipt",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"],
        "additionalProperties" => false
      },
      callback: fn _ -> flunk("adapter must not execute tools") end
    )
  end

  test "canonical tool exchange preserves the assistant message and usage" do
    call = ReqLLM.ToolCall.new("c1", "receipt", ~s({"id":"r1"}))
    message = ReqLLM.Context.assistant("", tool_calls: [call])

    response = %ReqLLM.Response{
      message: message,
      finish_reason: :tool_calls,
      id: "test",
      model: "fake",
      context: ReqLLM.Context.new(),
      usage: %{input_tokens: 10}
    }

    assert {:ok, reply} = Adapter.decode(response, [tool()])
    assert reply.calls == [%{id: "c1", name: "receipt", arguments: %{"id" => "r1"}}]
    assert reply.usage == %{input_tokens: 10}
    assert reply.continuation == message

    request = %{
      input: "Find receipt r1",
      exchanges: [%{reply: reply, results: [%{call: hd(reply.calls), output: "USD 12.00 paid"}]}]
    }

    assert {:ok, context} = Adapter.context(request)
    assert Enum.map(context.messages, & &1.role) == [:user, :assistant, :tool]
    assert Enum.at(context.messages, 1) == message
  end

  test "incomplete, invalid and provider-owned calls are never dispatched" do
    for call <- [
          ReqLLM.ToolCall.new("c1", "receipt", "not json"),
          ReqLLM.ToolCall.new("c1", "unknown", "{}"),
          ReqLLM.ToolCall.new_builtin("c1", "web_search", "{}")
        ] do
      response = %ReqLLM.Response{
        message: ReqLLM.Context.assistant("", tool_calls: [call]),
        finish_reason: :tool_calls,
        id: "test",
        model: "fake",
        context: ReqLLM.Context.new(),
        usage: %{input_tokens: 10}
      }

      assert {:error, :unsupported_tool_call} = Adapter.decode(response, [tool()])
    end

    truncated = %ReqLLM.Response{
      message: ReqLLM.Context.assistant("partial"),
      finish_reason: :length,
      id: "test",
      model: "fake",
      context: ReqLLM.Context.new()
    }

    assert {:error, :incomplete_response} = Adapter.decode(truncated, [])
  end

  test "one actual ReqLLM interaction preserves provider options without HTTP or tool execution" do
    assert {:ok, %Knotra.Reply{text: "Proposed reply"}} =
             Adapter.call(%{input: "Sanitized email", exchanges: [], tools: []},
               model: "openai:gpt-4o-mini",
               options: [
                 api_key: "fake-test-key",
                 max_tokens: 42,
                 req_http_options: [adapter: OfflineHTTP, retry: true]
               ]
             )

    assert_receive {:http_request, request}
    assert Map.fetch!(Map.fetch!(request, :options), :max_retries) == 0

    assert %{"max_output_tokens" => 42} =
             JSON.decode!(IO.iodata_to_binary(Map.fetch!(request, :body)))
  end

  test "final text does not invent usage" do
    response = %ReqLLM.Response{
      message: ReqLLM.Context.assistant("Proposed reply"),
      finish_reason: :stop,
      id: "test",
      model: "fake",
      context: ReqLLM.Context.new()
    }

    assert {:ok, %Knotra.Reply{text: "Proposed reply", calls: [], usage: nil}} =
             Adapter.decode(response, [])
  end
end
