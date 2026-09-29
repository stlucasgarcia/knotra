defmodule Knotra do
  @moduledoc """
  Non-durable, embedded background executions with replaceable plugins.

  Add `{Knotra, name: MyApp.Agents, max_executions: 20}` to the host supervisor.
  `start/5` returns a process handle, not a durable acceptance acknowledgment.
  Inspect or cancel that handle; release it when its in-memory record is no longer
  needed. Instance capacity includes retained terminal handles. There is no queue,
  deduplication, restart recovery, or cross-node ownership in this milestone.
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
    # ponytail: retained terminal handles consume capacity; separate storage/eviction later.
    capacity = Keyword.get(opts, :max_executions, 20)
    unless is_atom(name) and is_integer(capacity) and capacity > 0, do: raise(ArgumentError)

    Supervisor.init(
      [
        {Registry, keys: :unique, name: name},
        {Task.Supervisor, name: via(name, :tasks)},
        {DynamicSupervisor,
         name: via(name, :executions), strategy: :one_for_one, max_children: capacity}
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
  def release(execution), do: GenServer.call(execution, :release)

  defp via(instance, key), do: {:via, Registry, {instance, key}}
end
