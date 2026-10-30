defmodule Knotra.Bench.Swarm do
  @moduledoc false
  # 100 concurrent agents, one BEAM process each, under a fixed 300 MB ceiling.

  Code.require_file("swarm_support.ex", __DIR__)

  alias Knotra.Bench.SwarmSupport
  alias Knotra.Swarm.Spec

  @agents 100
  @ceiling_mb 300
  @hold_ms 250
  @rounds 3

  def run do
    os_pid = SwarmSupport.os_pid()
    instance = :knotra_swarm_bench
    SwarmSupport.start_instance!(instance, @agents)

    base_os = SwarmSupport.os_rss_mb(os_pid)
    base_vm = SwarmSupport.vm_memory_mb()

    results = for _ <- 1..@rounds, do: measure(instance, os_pid)
    peak_os = results |> Enum.map(& &1.peak_os) |> Enum.max()
    peak_vm = results |> Enum.map(& &1.peak_vm) |> Enum.max()
    peak_processes = results |> Enum.map(& &1.peak_processes) |> Enum.max()
    elapsed = results |> Enum.map(& &1.elapsed_ms) |> Enum.max()

    IO.puts("METRIC agents=#{@agents}")
    IO.puts("METRIC baseline_os_rss_mb=#{Float.round(base_os, 1)}")
    IO.puts("METRIC baseline_vm_memory_mb=#{Float.round(base_vm, 1)}")
    IO.puts("METRIC peak_os_rss_mb=#{Float.round(peak_os, 1)}")
    IO.puts("METRIC peak_vm_memory_mb=#{Float.round(peak_vm, 1)}")
    IO.puts("METRIC peak_beam_processes=#{peak_processes}")
    IO.puts("METRIC swarm_elapsed_ms=#{elapsed}")

    if peak_os >= @ceiling_mb or peak_vm >= @ceiling_mb do
      raise "swarm exceeded #{@ceiling_mb} MB: os=#{peak_os} MB vm=#{peak_vm} MB"
    end

    :ok
  end

  defp measure(instance, os_pid) do
    sampler = start_sampler(os_pid)

    agents =
      for n <- 1..@agents do
        SwarmSupport.agent("agent-#{n}", fn request -> "answer for #{request.input}" end,
          hold_ms: @hold_ms
        )
      end

    spec = %Spec{
      mode: :debate,
      goal: "benchmark the swarm",
      agents: agents,
      max_concurrency: @agents,
      timeout: 60_000
    }

    started = System.monotonic_time(:millisecond)
    {:ok, result} = Knotra.Swarm.run(instance, spec, await_timeout: 60_000)
    elapsed = System.monotonic_time(:millisecond) - started

    unless result.status == :completed and length(result.tasks) == @agents do
      raise "benchmark swarm did not complete: #{inspect(result.status)}"
    end

    peaks = stop_sampler(sampler)
    children = DynamicSupervisor.which_children({:via, Registry, {instance, :executions}})

    unless children == [] do
      raise "benchmark leaked executions: #{inspect(children)}"
    end

    Map.put(peaks, :elapsed_ms, elapsed)
  end

  defp start_sampler(os_pid) do
    parent = self()
    spawn_link(fn -> sample(os_pid, parent, %{os: 0.0, vm: 0.0, processes: 0}) end)
  end

  defp sample(os_pid, parent, peaks) do
    receive do
      :stop -> send(parent, {:peaks, peaks})
    after
      10 ->
        peaks = %{
          os: max(peaks.os, SwarmSupport.os_rss_mb(os_pid)),
          vm: max(peaks.vm, SwarmSupport.vm_memory_mb()),
          processes: max(peaks.processes, :erlang.system_info(:process_count))
        }

        sample(os_pid, parent, peaks)
    end
  end

  defp stop_sampler(sampler) do
    send(sampler, :stop)

    receive do
      {:peaks, peaks} ->
        %{
          peak_os: peaks.os,
          peak_vm: peaks.vm,
          peak_processes: peaks.processes
        }
    end
  end
end

Knotra.Bench.Swarm.run()
