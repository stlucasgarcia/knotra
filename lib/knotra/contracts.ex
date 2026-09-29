defmodule Knotra.Reply do
  @moduledoc """
  One model result. `continuation` is adapter-owned state for the next call;
  it is not exposed in execution records. Usage is unknown unless reported.
  """
  defstruct text: "", calls: [], usage: nil, continuation: nil

  @type t :: %__MODULE__{
          text: String.t(),
          calls: [map()],
          usage: map() | nil,
          continuation: term()
        }
end

defmodule Knotra.Loop do
  @moduledoc """
  A strategy requests operations; it never receives host authorization or credentials.
  `next/2` returns an operation and its next private state, or a final output.
  Each callback runs in a supervised task under the execution deadline.
  """
  @callback init(keyword()) :: term()
  @callback next(map(), term()) ::
              {:model, term()} | {:tool, map(), term()} | {:done, String.t()}
end

defmodule Knotra.Model do
  @moduledoc """
  One model interaction. The request contains input, completed exchanges and tool
  definitions, but no host authorization context. Return `{:retry, atom}` only
  for a transient failure that may safely repeat; the runtime bounds retries.
  """
  @callback call(map(), keyword()) ::
              {:ok, Knotra.Reply.t()} | {:error, atom()} | {:retry, atom()}
end

defmodule Knotra.Tool do
  @moduledoc """
  Trusted host tool. Definitions require name, description, JSON-schema parameters,
  and `read_only: true`. `validate/1` must validate untrusted arguments before
  authorization. JSON schema describes the tool to the provider; it is not a
  substitute for host-side validation (ReqLLM does not enforce map schemas).
  Implementations must be repeatable reads. Declaring read-only is not a sandbox.
  Results are strings so their representation is explicit at the model boundary.
  """
  @callback definition() :: map()
  @callback validate(map()) :: {:ok, map()} | {:error, atom()}
  @callback authorize(map(), term()) :: :ok | {:error, atom()}
  @callback call(map(), term()) :: {:ok, String.t()} | {:error, atom()} | {:retry, atom()}
end

defmodule Knotra.ToolRuntime do
  @moduledoc "Replaceable authorized execution boundary for host tools."
  @callback execute(map(), [module()], term(), keyword()) ::
              {:ok, String.t()} | {:error, atom()} | {:retry, atom()}
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
  This prototype does not persist or resume compositions.
  """
  @enforce_keys [:version, :model]
  defstruct version: nil,
            model: nil,
            loop: {Knotra.Loops.Default, []},
            tool_runtime: {Knotra.ToolRuntimes.Default, []},
            tools: [],
            observer: {Knotra.Observers.Send, nil}
end
