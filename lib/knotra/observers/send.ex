defmodule Knotra.Observers.Send do
  @moduledoc "Optional delivery of snapshots to a host-owned process; no delivery guarantee."
  @behaviour Knotra.Observer

  @impl true
  def record(_snapshot, nil), do: :ok

  def record(snapshot, pid) when is_pid(pid) do
    send(pid, {:knotra, snapshot})
    :ok
  end
end
