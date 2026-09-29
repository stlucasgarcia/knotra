# Knotra

An embedded, plugin-driven Elixir agent harness for background work.

**Milestone 1 is an in-memory prototype, not a durable or production-ready runtime.**
ReqLLM is the only direct third-party dependency. No Phoenix or database is required.

## Embed in your application

```elixir
# In your application's supervision tree:
{Knotra, name: MyApp.Agents, max_executions: 20}
```

```elixir
definition = %Knotra.Definition{
  version: "email-v1",
  model: {Knotra.Models.ReqLLM,
    model: "openai:gpt-4o-mini",
    options: [max_tokens: 1024]},
  tools: [MyApp.ReceiptLookup],
  observer: {Knotra.Observers.Send, self()}
}

{:ok, execution} = Knotra.start(
  MyApp.Agents,
  definition,
  "Draft a reply confirming receipt r1. Do not send it.",
  host_authorization_context,
  max_turns: 8,
  max_tool_calls: 16,
  max_retries: 0,
  max_steps: 64,
  timeout: 30_000
)

Knotra.snapshot(execution)
# Optional: Knotra.cancel(execution)
# After completion/cancellation: Knotra.release(execution)
```

Set provider credentials through ReqLLM's supported configuration. Do not put them
in prompts. `start/5` returns a local process handle, **not durable acceptance**.
The observer optionally sends `{:knotra, snapshot}` messages to the supplied PID.
A terminal snapshot has status `:completed`, `:failed`, or `:cancelled`.

Capacity includes retained terminal handles: explicitly release them to free a
slot. Over-capacity requests return `{:error, :max_children}`; there is no queue.
Snapshots disappear when their execution process or host stops. IDs are unique
only within the current BEAM instance, not durable global identifiers.

## Host tools: validation before authorization before execution

Tools implement `Knotra.Tool`:

```elixir
defmodule MyApp.ReceiptLookup do
  @behaviour Knotra.Tool

  def definition do
    %{
      name: "receipt",
      description: "Read an authorized receipt",
      read_only: true,
      parameters: %{
        "type" => "object",
        "properties" => %{"id" => %{"type" => "string"}},
        "required" => ["id"],
        "additionalProperties" => false
      }
    }
  end

  def validate(%{"id" => id} = args) when is_binary(id) and map_size(args) == 1,
    do: {:ok, args}

  def validate(_), do: {:error, :invalid_arguments}

  # Implement these with your host's authorization/data layer:
  def authorize(args, scope), do: MyApp.Receipts.authorize_read(scope, args["id"])
  def call(args, scope), do: MyApp.Receipts.read_as_text(scope, args["id"])
end
```

`authorize/2` returns `:ok` or `{:error, atom}`. `call/2` returns `{:ok, string}`,
`{:error, atom}`, or explicitly retryable `{:retry, atom}`. Lookup and authorization
must use the host-supplied scope; tenant identity never comes from model arguments.
Repeatable reads only. A `read_only` declaration is a contract, not enforcement
against malicious or incorrectly implemented Elixir modules.

**JSON schema is provider metadata, not local validation.** ReqLLM 1.24 does not
validate map-schema tool arguments locally. The required `validate/1` callback
must reject invalid data before authorization or execution.

## Replaceable capabilities

`Knotra.Definition` selects these trusted plugins:

| Field | Contract | Default |
|---|---|---|
| `loop` | `Knotra.Loop` | Sequential model → tools → model |
| `model` | `Knotra.Model` | Explicitly supplied; ReqLLM adapter included |
| `tool_runtime` | `Knotra.ToolRuntime` | `Knotra.ToolRuntimes.Default`: host validation + authorization + execution |
| `observer` | `Knotra.Observer` | Optional PID snapshot delivery |

Each field is `{module, options}`. No runtime discovery or code loading. The core
validates the composition, controls operation dispatch, rejects invented or
repeated tool calls, and enforces lifecycle, counters, and deadlines regardless
of loop strategy. Plugins are trusted in-VM code, not sandboxed extensions.

A loop implements `init/1` and `next/2`. The view contains input, the latest public
model/tool result, and counters. Return `{:model, next_state}`,
`{:tool, pending_call, next_state}`, or `{:done, text}`. Outstanding model-requested
tools must be resolved before another model call or completion. A model receives
input, prior exchanges, and tool definitions; it returns a `Knotra.Reply`. Its
opaque continuation preserves provider messages without exposing them in public
records. Tests include an alternate loop that completes without a model call.

Persistence/admission/recovery plugins are **not implemented yet**. The test-only
`MemoryRecorder` demonstrates replacing the observer with an in-memory snapshot
store; it is not a durable persistence adapter.

## Limits, cancellation, and records

- Supervised tasks run plugin callbacks; coordinators remain responsive.
- Turn/tool counters count attempts, including retries. `max_retries` is shared
  across the execution; defaults to zero. The ReqLLM adapter disables transport
  retries and conservatively returns non-retryable `:model_error` on failure.
- `max_steps` also bounds strategy callbacks. `timeout` is an absolute monotonic
  deadline checked when consuming results, before dispatch, and on callback entry;
  terminal observer delivery gets at most one additional second.
- Cancellation kills the current local task and prevents future operations. It
  cannot undo a remote request or work spawned independently by a host tool.
- Unexpected plugin failures produce stable failure codes, not raw exception
  messages that might contain credentials. OTP status/crash formatting redacts
  private state, messages, and reasons. Terminal observer failures are visible
  through `snapshot/1` as `observation_error`; delivery is not guaranteed.
- Public snapshots include inputs, model text, requested tools, results, usage
  when supplied, counters, event sequence, and elapsed milliseconds. They exclude
  authorization context, plugin options, and private model continuations.
  Missing wire usage stays `nil`, not zero. The ReqLLM adapter recognizes standard
  `usage`, `usageMetadata`, `usage_metadata`, and `token_usage` envelopes; unfamiliar
  shapes remain unknown. Explicitly reported zero usage is preserved.
- Inputs and outputs may still contain confidential data. Hosts own access to
  handles and observer recipients, redaction, and record lifetime. Releasing a
  handle drops Knotra's copy, not copies already delivered to observers.

No deduplication, deployment continuity, cross-node ownership, exactly-once effects,
financial writes, hard monetary cap, answer cache, or durable audit guarantee.
Provider-option semantics remain ReqLLM/provider-specific; full provider parity
has not been verified. Unsupported or incomplete local tool calls fail closed.

## Verification and evaluation

```sh
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test --warnings-as-errors
```

Tests need no provider keys and make no model-network calls. They cover the
sanitized email/receipt scenario, plugin replacement, forbidden/malformed tool
requests, limits, retries, cancellation, process death, and record isolation.
The ReqLLM adapter is also exercised through offline HTTP fixtures for OpenAI,
Anthropic, and Gemini, including refusal/incomplete responses, absent usage, and
text-only multi-turn continuations. Timer-ordering and credential-redaction
regressions run without provider access.

For fresh-model evaluation, submit sanitized inputs with a real model plugin and
a fixture-only tool runtime, then assess facts, permitted tool use, output shape,
and budgets. Never reuse production tool implementations or credentials for
isolated scenario evaluation. A general evaluation runner and replay product are
not included; see the executable scenario in `test/knotra_test.exs`.

See [the agreed design](docs/design.md) and
[the alternatives research](docs/research/elixir-agent-alternatives.md).
