defmodule Knotra.Bench.SwarmSupport do
  @moduledoc false
  # Deterministic offline model and agent builders shared by the swarm benchmark
  # and the showcase script. Nothing here contacts a provider.

  defmodule Model do
    @behaviour Knotra.Model

    @impl true
    def call(request, opts) do
      hold_ms = Keyword.get(opts, :hold_ms, 0)
      if hold_ms > 0, do: Process.sleep(hold_ms)
      {:ok, %Knotra.Reply{text: Keyword.fetch!(opts, :respond).(request)}}
    end
  end

  def agent(name, respond, opts \\ []) do
    hold_ms = Keyword.get(opts, :hold_ms, 0)

    %Knotra.Swarm.Agent{
      name: name,
      definition: %Knotra.Definition{
        version: "bench-v1",
        model: {Model, respond: respond, hold_ms: hold_ms}
      }
    }
  end

  def start_instance!(name, max_executions) do
    {:ok, supervisor} = Knotra.start_link(name: name, max_executions: max_executions)
    supervisor
  end

  def os_pid, do: :os.getpid() |> List.to_string()

  @doc "Peak OS resident set size of this VM in MB, sampled by `ps`."
  def peak_os_rss_mb(os_pid, interval_ms \\ 10) do
    parent = self()
    spawn_link(fn -> sample(os_pid, interval_ms, parent, 0.0) end)

    receive do
      {:rss_peaks, peak} -> peak
    end
  end

  defp sample(os_pid, interval_ms, parent, peak) do
    receive do
      :stop ->
        send(parent, {:rss_peaks, peak})
    after
      interval_ms ->
        sample(os_pid, interval_ms, parent, max(peak, os_rss_mb(os_pid)))
    end
  end

  def os_rss_mb(os_pid) do
    {out, 0} = System.cmd("ps", ["-o", "rss=", "-p", os_pid])
    {kb, _} = Float.parse(String.trim(out))
    kb / 1024
  end

  def vm_memory_mb do
    :erlang.memory(:total) / (1024 * 1024)
  end
end
