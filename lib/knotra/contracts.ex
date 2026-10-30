defmodule Knotra.Reply do
  @moduledoc """
  One model result. `continuation` is adapter-owned state for the next call;
  it is not exposed in execution records. Usage is unknown unless reported.
  `input_request` is an optional strictly one-key `%{prompt: binary}` map: a
  non-empty question the execution needs before it can continue. It may accompany
  only a reply with no tool calls, and it asks for information, never permission
  to act.
  """
  defstruct text: "", calls: [], usage: nil, continuation: nil, input_request: nil

  @type t :: %__MODULE__{
          text: String.t(),
          calls: [map()],
          usage: map() | nil,
          continuation: term(),
          input_request: %{prompt: String.t()} | nil
        }
end

defmodule Knotra.Loop do
  @moduledoc """
  A strategy requests operations; it never receives host authorization or credentials.
  `next/2` returns an operation and its next private state, or a final output.
  Each callback runs in a supervised task under the execution deadline. Returning
  `{:input, request, next_state}` asks the execution for information: the default
  loop does it for a zero-call model reply carrying an `input_request`, and a
  non-durable execution fails closed with `:input_not_supported` rather than
  continuing.
  """
  @callback init(keyword()) :: term()
  @callback next(map(), term()) ::
              {:model, term()}
              | {:tool, map(), term()}
              | {:input, map(), term()}
              | {:done, String.t()}
end

defmodule Knotra.Model do
  @moduledoc """
  One model interaction. The request contains input, completed exchanges and tool
  definitions, but no host authorization context. Return `{:retry, atom}` only
  for a transient failure that may safely repeat; the runtime bounds retries.
  An exchange may carry an extra `:answer` binary, set when a durable input request
  is answered; the `Knotra.Models.ReqLLM` adapter renders it as the human turn after
  the assistant reply it answers.
  """
  @callback call(map(), keyword()) ::
              {:ok, Knotra.Reply.t()} | {:error, atom()} | {:retry, atom()}

  @doc """
  Optional opt-in hook that converts the neutral tool definitions into a
  provider-specific representation once per execution. Executions cache the result
  and pass it back as `:prepared_tools` on every request, so adapters do not repeat
  schema compilation per turn. The value is never checkpointed.
  """
  @callback prepare_tools([map()]) :: {:ok, term()} | {:error, atom()}

  @doc "Opt-in version of inert reply/continuation data; runtime options are never checkpointed."
  @callback checkpoint_version() :: pos_integer()
  @optional_callbacks checkpoint_version: 0, prepare_tools: 1
end

defmodule Knotra.Tool do
  @moduledoc """
  Trusted host tool. Definitions require name, description, JSON-schema parameters,
  and `read_only: true`. `validate/1` must validate untrusted arguments before
  authorization. JSON schema describes the tool to the provider; it is not a
  substitute for host-side validation (ReqLLM does not enforce map schemas).
  Implementations used by `start/5` must be repeatable reads. The opt-in durable
  path also accepts `read_only: false` definitions for proposals. Only an explicitly
  allowlisted demonstration tool may execute after a bound approval and fresh
  authorization. Its map context includes `:knotra_operation_id` for the stable
  operation identity. Automatic effect retries remain blocked, even if `call/2`
  requests one. A definition may explicitly declare `idempotency: :operation_id`
  only if the host service durably binds that identity to the unchanged arguments
  and original outcome: duplicate concurrent/restarted calls must return that
  outcome without another effect. Explicit `recover/4` may then make a budgeted
  attempt with the same identity after rechecking current authorization. Best-effort
  deduplication or a caller-supplied key alone is insufficient. This declaration is
  a trusted host contract, not containment or proof of the service's implementation.
  Declaring read-only or allowlisting a module is not a sandbox.
  Results are strings so their representation is explicit at the model boundary.
  In durable mode, validated arguments are checkpointed as inert data: use
  binaries, numbers, booleans, `nil`, lists, and maps with string keys. Atoms that
  are not part of the checkpoint vocabulary make the proposal fail closed with
  `:unsupported_arguments` instead of being persisted.
  """
  @callback definition() :: map()
  @callback validate(map()) :: {:ok, map()} | {:error, atom()}
  @callback authorize(map(), term()) :: :ok | {:error, atom()}
  @callback call(map(), term()) :: {:ok, String.t()} | {:error, atom()} | {:retry, atom()}
end

defmodule Knotra.ToolRuntime do
  @moduledoc """
  Replaceable authorized execution boundary for host tools. Returning
  `{:ok, validated_arguments, result}` records the arguments the boundary actually
  passed to `call/2`; the two-element form keeps the model-requested arguments.
  """
  @callback execute(map(), [module()], term(), keyword()) ::
              {:ok, String.t()}
              | {:ok, map(), String.t()}
              | {:error, atom()}
              | {:retry, atom()}

  @doc """
  Whether this runtime enforces its own policy for declared write tools.

  Only a runtime that implements this and returns `true` may execute a
  `read_only: false` tool on the non-durable path. The runtime is then
  responsible for validating, authorizing and either executing the call or
  returning a failure before any effect.
  """
  @callback supports_writes?() :: boolean()

  @optional_callbacks supports_writes?: 0
end

defmodule Knotra.Observer do
  @moduledoc """
  Observes public execution snapshots. No credentials or private plugin state are
  included. Inputs and tool results can still be sensitive; access is host-owned.
  Callbacks must return promptly. They run in a bounded task, never the coordinator.
  Observer failure fails this prototype execution rather than silently losing records.
  """
  @callback record(map(), term()) :: :ok
end

defmodule Knotra.Definition do
  @moduledoc """
  Trusted, code-defined composition. Supply an explicit version to identify it.
  Options and authorization are runtime-only and never included in public snapshots.
  Durable submissions pin this version, module identities, tool definitions and
  the model checkpoint version. Change `version` whenever semantic runtime options
  or code change: private options/credentials are not hashed or persisted.
  Only the default loop and tool runtime support durable approval checkpoints.
  """
  @enforce_keys [:version, :model]
  defstruct version: nil,
            model: nil,
            loop: {Knotra.Loops.Default, []},
            tool_runtime: {Knotra.ToolRuntimes.Default, []},
            tools: [],
            observer: {Knotra.Observers.Send, nil}

  @type plugin :: {module(), keyword() | term()}

  @type t :: %__MODULE__{
          version: String.t(),
          model: plugin(),
          loop: plugin(),
          tool_runtime: plugin(),
          tools: [module()],
          observer: plugin()
        }
end
