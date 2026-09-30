defmodule Knotra do
  @moduledoc """
  Non-durable, embedded background executions with replaceable plugins.

  Add `{Knotra, name: MyApp.Agents, max_executions: 20}` to the host supervisor.
  `start/5` returns a process handle, not a durable acceptance acknowledgment.
  Inspect or cancel that handle; release it when its in-memory record is no longer
  needed. Instance capacity includes retained terminal handles. There is no queue,
  deduplication or restart recovery on this path.

  `submit/6` is a separate opt-in Ecto path for durable acceptance and pending
  approvals. See `docs/durable-approvals.md`. Neither path provides cross-node
  ownership. `answer/5` can reject a request or approve one explicitly allowlisted
  demonstration tool; this is not production consequential-operation support.
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

    unless is_atom(name) and is_integer(capacity) and capacity > 0 do
      raise ArgumentError
    end

    Supervisor.init(
      [
        {Registry, [keys: :unique, name: name, meta: [durable: Keyword.get(opts, :durable)]]},
        {Task.Supervisor, [name: via(name, :tasks)]},
        {DynamicSupervisor,
         [name: via(name, :executions), strategy: :one_for_one, max_children: capacity]}
      ],
      strategy: :one_for_all
    )
  end

  @doc "Starts an isolated execution. Host context is never derived from model arguments."
  def start(instance, %Knotra.Definition{} = definition, input, context, opts \\ []) do
    DynamicSupervisor.start_child(
      via(instance, :executions),
      {Knotra.Execution, {via(instance, :tasks), definition, input, context, opts}}
    )
  end

  @doc "Returns the in-memory public record; excludes credentials and plugin options."
  def snapshot(execution), do: GenServer.call(execution, :snapshot)

  @doc "Stops future steps and kills the local task; cannot undo remote effects."
  def cancel(execution), do: GenServer.call(execution, :cancel)

  @doc "Releases a terminal handle and its record. Cancel running work first."
  def release(execution) do
    with {:ok, supervisor} <- GenServer.call(execution, :release) do
      DynamicSupervisor.terminate_child(supervisor, execution)
    end
  end

  @doc "Durably accepts a request. Requires the opt-in Ecto persistence integration."
  def submit(instance, definition, input, context, key, opts \\ []) do
    durable_call(:submit, [instance, definition, input, context, key, opts])
  end

  @doc "Host-authorized durable public record lookup, independent of a worker PID."
  def snapshot(instance, id, context) do
    durable_call(:snapshot, [instance, id, context])
  end

  @doc "Host-authorized private checkpoint lookup; stronger permission than inspection."
  def checkpoint(instance, id, context) do
    durable_call(:checkpoint, [instance, id, context])
  end

  @doc "Recovers accepted work or a committed tool-result continuation; never invents an answer or retries an uncertain effect."
  def recover(instance, id, definition, context) do
    durable_call(:recover, [instance, id, definition, context])
  end

  @doc "Answers one versioned approval; host context and the unchanged operation are required."
  def answer(instance, id, definition, context, answer) do
    durable_call(:answer, [instance, id, definition, context, answer])
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
