defmodule Knotra do
  @moduledoc """
  Non-durable, embedded background executions with replaceable plugins.

  Add `{Knotra, name: MyApp.Agents, max_executions: 20}` to the host supervisor.
  `start/5` returns a process handle, not a durable acceptance acknowledgment.
  Inspect or cancel that handle; release it when its in-memory record is no longer
  needed. Instance capacity includes retained terminal handles. There is no queue,
  deduplication or restart recovery on this path.

  Every instance also owns a bounded in-memory observability store. Read it with
  `Knotra.Observability` or mount `Knotra.Dashboard.Live` in a Phoenix LiveView
  host. Configure retention with the `:observability` instance option.

  `submit/6` is a separate opt-in Ecto path for durable acceptance, pending
  approvals and pending input requests (clarification). See
  `docs/durable-approvals.md`. Neither path provides cross-node ownership.
  `answer/5` can reject an approval request or approve an explicitly allowlisted
  demonstration operation; it can also answer a pending input request, which only
  continues the same execution with information and never dispatches an operation.
  Each subsequent operation needs a fresh approval; this is not production
  consequential-operation support.
  """
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :name),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    # ponytail: non-durable terminal handles retain capacity until explicitly released.
    capacity = Keyword.get(opts, :max_executions, 20)
    durable = Keyword.get(opts, :durable)

    validate_instance!(name, capacity, durable, Keyword.get(opts, :observability, []))

    Supervisor.init(
      [
        {Registry, [keys: :unique, name: name, meta: [durable: durable]]},
        {Task.Supervisor, [name: via(name, :tasks)]},
        {Knotra.Observability.Store,
         [instance: name, opts: Keyword.get(opts, :observability, [])]},
        {DynamicSupervisor,
         [name: via(name, :executions), strategy: :one_for_one, max_children: capacity]}
      ],
      strategy: :one_for_all
    )
  end

  @observability_keys [:max_records, :max_events, :notify_ms, :message_limit]

  defp validate_observability!(opts) do
    unless is_list(opts) and Keyword.keyword?(opts) and
             Enum.all?(Keyword.keys(opts), &(&1 in @observability_keys)) do
      raise ArgumentError,
            "observability must be a keyword list with keys #{inspect(@observability_keys)}"
    end
  end

  defp validate_instance!(name, capacity, durable, observability) do
    unless is_atom(name) and is_integer(capacity) and capacity > 0 do
      raise ArgumentError,
            "expected :name to be an atom and :max_executions to be a positive integer"
    end

    validate_observability!(observability)

    case durable do
      nil ->
        :ok

      opts when is_list(opts) ->
        repo = Keyword.get(opts, :repo)
        access = Keyword.get(opts, :access)
        demo_tools = Keyword.get(opts, :demo_tools, [])
        pending = Keyword.get(opts, :max_pending, :infinity)

        unless is_atom(repo) and Code.ensure_loaded?(repo) and
                 function_exported?(repo, :get_by, 3) do
          raise ArgumentError, "durable :repo must be an Ecto repo module"
        end

        unless is_atom(access) and Code.ensure_loaded?(access) and
                 function_exported?(access, :authorize, 3) do
          raise ArgumentError,
                "durable :access must implement Knotra.Access.authorize/3"
        end

        unless is_list(demo_tools) and Enum.all?(demo_tools, &is_atom/1) do
          raise ArgumentError, "durable :demo_tools must be a list of tool modules"
        end

        unless pending == :infinity or (is_integer(pending) and pending > 0) do
          raise ArgumentError, "durable :max_pending must be a positive integer or :infinity"
        end

      _other ->
        raise ArgumentError, "durable must be a keyword list"
    end
  end

  @doc """
  Starts an isolated execution. Host context is never derived from model arguments.

  Composition and tool definitions are validated before a process starts, so
  invalid tools return `{:error, :invalid_tool_definitions}` instead of an
  asynchronous failure. Capacity errors surface as `{:error, :max_children}`.

  Options are the execution limits plus `:trace`, a map or keyword list used only
  by the observability store: `:agent`, `:conversation_id`, `:parent_id`, and
  `:labels`. Unknown trace keys return `{:error, :invalid_configuration}`.
  """
  @spec start(GenServer.server(), Knotra.Definition.t(), String.t(), term(), keyword()) ::
          {:ok, pid()} | {:error, atom()}
  def start(instance, %Knotra.Definition{} = definition, input, context, opts \\ []) do
    {trace, opts} = Keyword.pop(opts, :trace)

    case Knotra.Observability.normalize_trace(trace) do
      {:ok, trace} ->
        with :ok <- Knotra.Execution.validate(definition, input, opts) do
          opts = if trace, do: Keyword.put(opts, :trace, trace), else: opts

          DynamicSupervisor.start_child(
            via(instance, :executions),
            {Knotra.Execution, {via(instance, :tasks), definition, input, context, opts}}
          )
        end

      :error ->
        {:error, :invalid_configuration}
    end
  end

  @doc """
  Returns the in-memory public record; excludes credentials and plugin options.

  A released or already-terminated handle returns `{:error, :not_found}`.
  """
  @spec snapshot(GenServer.server()) :: map() | {:error, :not_found}
  def snapshot(execution), do: call(execution, :snapshot)

  @doc """
  Stops future steps and kills the local task; cannot undo remote effects.
  A released or already-terminated handle returns `{:error, :not_found}`.
  """
  @spec cancel(GenServer.server()) :: :ok | {:error, :not_found}
  def cancel(execution), do: call(execution, :cancel)

  @doc "Cancels a durable waiting or decided execution before dispatch admission; never rolls back an effect."
  @spec cancel(GenServer.server(), String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def cancel(instance, id, context), do: durable_call(:cancel, [instance, id, context])

  @doc """
  Releases a terminal handle and its record. Cancel running work first.
  Releasing twice returns `{:error, :not_found}`.
  """
  @spec release(GenServer.server()) :: :ok | {:error, :not_found} | {:error, :running}
  def release(execution) do
    with {:ok, supervisor} <- call(execution, :release) do
      DynamicSupervisor.terminate_child(supervisor, execution)
    end
  end

  @doc "Durably accepts a request, or returns :pending_limit at the configured outstanding-work bound."
  @spec submit(
          GenServer.server(),
          Knotra.Definition.t(),
          String.t(),
          term(),
          String.t(),
          keyword()
        ) ::
          {:ok, String.t()} | {:error, atom()}
  def submit(instance, definition, input, context, key, opts \\ []) do
    durable_call(:submit, [instance, definition, input, context, key, opts])
  end

  @doc "Host-authorized durable record lookup; conditionally persists overdue pending interaction expiry."
  @spec snapshot(GenServer.server(), String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def snapshot(instance, id, context) do
    durable_call(:snapshot, [instance, id, context])
  end

  @doc """
  Lists the tenant's durable records, newest first, using the `:inspect` host
  action. Options: `:status` (atom) and `:limit` (1..1000, default 100). Checkpoints
  and private model continuations are never returned.
  """
  @spec list(GenServer.server(), term(), keyword()) :: {:ok, [map()]} | {:error, atom()}
  def list(instance, context, opts \\ []) do
    durable_call(:list, [instance, context, opts])
  end

  @doc """
  Deletes one terminal or blocked durable record via the `:close` host action,
  releasing its capacity and pending-bound slot. Running, accepted, waiting,
  decided and ready records must be cancelled or completed first.
  """
  @spec close(GenServer.server(), String.t(), term()) :: :ok | {:error, atom()}
  def close(instance, id, context) do
    durable_call(:close, [instance, id, context])
  end

  @doc "Host-authorized private checkpoint lookup; stronger permission than inspection."
  @spec checkpoint(GenServer.server(), String.t(), term()) :: {:ok, map()} | {:error, atom()}
  def checkpoint(instance, id, context) do
    durable_call(:checkpoint, [instance, id, context])
  end

  @doc "Recovers supported safe points; uncertain effects require an explicit operation-ID idempotency contract and remaining budgets before another attempt."
  @spec recover(GenServer.server(), String.t(), Knotra.Definition.t(), term()) ::
          {:ok, map()} | {:error, atom()}
  def recover(instance, id, definition, context) do
    durable_call(:recover, [instance, id, definition, context])
  end

  @doc "Answers one versioned approval or input request; host context and the current request version are required."
  @spec answer(GenServer.server(), String.t(), Knotra.Definition.t(), term(), map()) ::
          {:ok, map()} | {:error, atom()}
  def answer(instance, id, definition, context, answer) do
    durable_call(:answer, [instance, id, definition, context, answer])
  end

  defp call(execution, message) do
    GenServer.call(execution, message)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, {:shutdown, _} -> {:error, :not_found}
    :exit, {{:shutdown, _}, _} -> {:error, :not_found}
  end

  defp durable_call(function, args) do
    if Code.ensure_loaded?(Knotra.Persistence) do
      apply(Knotra.Durable, function, args)
    else
      {:error, :persistence_unavailable}
    end
  end

  defp via(instance, key) do
    {:via, Registry, {instance, key}}
  end
end
