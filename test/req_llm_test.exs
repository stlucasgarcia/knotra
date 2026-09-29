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

  defmodule FixtureHTTP do
    def run(request) do
      {owner, responses} = Req.Request.get_private(request, :fixture)
      send(owner, {:fixture_request, request})
      body = Agent.get_and_update(responses, fn [body | rest] -> {body, rest} end)

      {request,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: JSON.encode!(body)
       )}
    end
  end

  defmodule TwoTurnLoop do
    @behaviour Knotra.Loop
    @impl true
    def init(_), do: 0
    @impl true
    def next(_, turns) when turns < 2, do: {:model, turns + 1}
    def next(%{last: {:model, %{text: text}}}, 2), do: {:done, text}
  end

  defp fixture_options(responses) do
    store = start_supervised!({Agent, fn -> responses end}, id: make_ref())
    owner = self()

    [
      api_key: "fake-test-key",
      req_http_options: [
        adapter: FixtureHTTP,
        plugins: [fn request -> Req.Request.put_private(request, :fixture, {owner, store}) end]
      ]
    ]
  end

  defp response(text) do
    %{
      "id" => "resp_fixture",
      "object" => "response",
      "model" => "gpt-4o-mini",
      "status" => "completed",
      "output" => [
        %{
          "id" => "msg_fixture",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 3, "total_tokens" => 13}
    }
  end

  defp wire_call(body, model \\ "openai:gpt-4o-mini") do
    Adapter.call(%{input: "Sanitized email", exchanges: [], tools: []},
      model: model,
      options: fixture_options([body])
    )
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

  test "wire refusals, empty responses, and unfinished Anthropic turns fail closed" do
    refused =
      put_in(response("unused")["output"], [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "refusal", "refusal" => "Cannot comply"}]
        }
      ])

    for body <- [refused, Map.put(response("unused"), "output", []), response("  ")] do
      assert {:error, :empty_response} = wire_call(body)
    end

    paused = %{
      "id" => "msg_pause",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-sonnet-4-20250514",
      "content" => [%{"type" => "text", "text" => "Unfinished draft"}],
      "stop_reason" => "pause_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 3}
    }

    assert {:error, :incomplete_response} =
             wire_call(paused, "anthropic:claude-sonnet-4-20250514")
  end

  test "unknown finish states do not become successful answers" do
    for finish <- [:incomplete, :cancelled, :other, nil] do
      reply = %ReqLLM.Response{
        id: "test",
        model: "fake",
        context: ReqLLM.Context.new(),
        message: ReqLLM.Context.assistant("partial"),
        finish_reason: finish
      }

      assert {:error, :incomplete_response} = Adapter.decode(reply, [])
    end
  end

  test "missing wire usage remains unknown while explicitly reported zeros remain zero" do
    for body <- [
          Map.delete(response("OK"), "usage"),
          Map.put(response("OK"), "usage", nil),
          Map.put(response("OK"), "usage", %{})
        ] do
      assert {:ok, %Knotra.Reply{text: "OK", usage: nil}} = wire_call(body)
    end

    zero =
      Map.put(response("OK"), "usage", %{
        "input_tokens" => 0,
        "output_tokens" => 0,
        "total_tokens" => 0
      })

    assert {:ok, %Knotra.Reply{usage: %{input_tokens: 0, output_tokens: 0}}} = wire_call(zero)

    assert {:ok, %Knotra.Reply{usage: %{input_tokens: 10, output_tokens: 3}}} =
             wire_call(response("OK"))
  end

  test "finite provider timeout preserves usage across the HTTP task boundary" do
    fixtures = [
      {response("OK"), %{input_tokens: 10, output_tokens: 3}},
      {Map.put(response("OK"), "usage", %{"input_tokens" => 0, "output_tokens" => 0}),
       %{input_tokens: 0, output_tokens: 0}},
      {Map.delete(response("OK"), "usage"), nil}
    ]

    for {body, expected} <- fixtures do
      options = fixture_options([body]) |> Keyword.put(:total_timeout, 1_000)

      assert {:ok, reply} =
               Adapter.call(%{input: "Email", exchanges: [], tools: []},
                 model: "openai:gpt-4o-mini",
                 options: options
               )

      assert if(reply.usage, do: Map.take(reply.usage, [:input_tokens, :output_tokens])) ==
               expected
    end

    refute_receive {Knotra.Models.ReqLLM, _ref, _marker}
  end

  test "Google wire usage is distinguished from absent usage" do
    body = %{
      "candidates" => [
        %{
          "content" => %{"role" => "model", "parts" => [%{"text" => "OK"}]},
          "finishReason" => "STOP",
          "index" => 0
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 10,
        "candidatesTokenCount" => 3,
        "totalTokenCount" => 13
      }
    }

    assert {:ok, %Knotra.Reply{usage: %{input_tokens: 10, output_tokens: 3}}} =
             wire_call(body, "google:gemini-2.5-flash")

    assert {:ok, %Knotra.Reply{usage: nil}} =
             wire_call(Map.delete(body, "usageMetadata"), "google:gemini-2.5-flash")
  end

  test "replacement loop can make a second model turn after a text-only response" do
    start_supervised!({Knotra, name: __MODULE__})

    definition = %Knotra.Definition{
      version: "two-turns",
      loop: {TwoTurnLoop, []},
      model:
        {Adapter,
         model: "openai:gpt-4o-mini",
         options: fixture_options([response("Draft"), response("Revised")])},
      observer: {Knotra.Observers.Send, self()}
    }

    {:ok, execution} = Knotra.start(__MODULE__, definition, "Sanitized email", %{})
    assert_receive {:knotra, %{status: :completed, output: "Revised", counts: %{turns: 2}}}, 5_000
    assert_receive {:fixture_request, _first}
    assert_receive {:fixture_request, second}
    body = JSON.decode!(IO.iodata_to_binary(second.body))
    assert Enum.any?(body["input"], &(&1["role"] == "assistant"))
    :ok = Knotra.release(execution)
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
