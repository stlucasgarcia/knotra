defmodule Knotra.Swarm.Observer do
  @moduledoc false
  # Relays a swarm child's terminal snapshot to the process that started it and
  # forwards every snapshot to the definition's own observer, so wrapping a child
  # never hides the host's records. Callbacks must return promptly; a failure here
  # would fail the execution, so both branches are contained.

  @behaviour Knotra.Observer

  @terminal [:completed, :failed, :cancelled, :blocked]

  @impl true
  def record(snapshot, %{notify: pid, tag: tag} = opts) do
    if snapshot[:status] in @terminal, do: send(pid, {:knotra_swarm_child, tag, snapshot})
    delegate(Map.get(opts, :delegate), snapshot)
    :ok
  end

  def record(snapshot, opts) when is_list(opts) do
    record(snapshot, Map.new(opts))
  end

  defp delegate({module, delegate_opts}, snapshot) when is_atom(module) do
    module.record(snapshot, delegate_opts)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp delegate(_other, _snapshot), do: :ok
end
