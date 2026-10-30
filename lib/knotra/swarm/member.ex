defmodule Knotra.Swarm.Member do
  @moduledoc false
  # One board-mode member process. It claims tasks until the board is empty and
  # runs one execution at a time, so a member is both a BEAM process and the
  # unit of board self-selection. Claimed rows and outcome rows are the
  # authoritative state; the member owns nothing the coordinator must trust.

  alias Knotra.Swarm.{Board, Observer}

  @retry_ms 10

  def run(args) do
    loop(args)
    send(args.coordinator, {:knotra_swarm_member_done, self()})
    :ok
  end

  defp loop(args) do
    if expired?(args) do
      :ok
    else
      case Board.claim(args.board, args.agent.name, args.task_ids) do
        :empty ->
          :ok

        {:ok, id, input} ->
          work(args, id, input)
          loop(args)
      end
    end
  end

  defp work(args, id, input) do
    tag = make_ref()
    definition = with_observer(args.agent.definition, tag)
    opts = Keyword.put(args.execution_opts, :trace, child_trace(args, id))
    started_at = now()

    case start(args, definition, input, opts) do
      {:ok, pid} ->
        send(args.coordinator, {:knotra_swarm_child_started, pid})
        result = await(tag, args)
        elapsed = now() - started_at
        release(pid)
        send(args.coordinator, {:knotra_swarm_child_finished, pid})
        meta = %{elapsed_ms: elapsed, counts: counts(result)}

        case result do
          {:ok, %{status: :completed, output: output}} when is_binary(output) ->
            Board.complete(args.board, id, args.agent.name, output, meta)

          {:ok, snapshot} ->
            Board.fail(args.board, id, args.agent.name, error(snapshot), meta)

          :timeout ->
            Knotra.cancel(pid)
            Board.fail(args.board, id, args.agent.name, :deadline_exceeded, meta)
        end

      {:error, reason} ->
        Board.fail(args.board, id, args.agent.name, reason)
    end
  end

  defp child_trace(args, part) do
    %{
      agent: args.agent.name,
      conversation_id: args.swarm_id,
      labels: %{"mode" => mode_label(args.mode), "part" => to_string(part)}
    }
  end

  defp mode_label(:fan_out), do: "fanout"
  defp mode_label(mode), do: Atom.to_string(mode)

  defp counts({:ok, snapshot}), do: snapshot[:counts]
  defp counts(_result), do: nil

  defp now, do: System.monotonic_time(:millisecond)

  defp with_observer(definition, tag) do
    %{
      definition
      | observer: {Observer, %{notify: self(), tag: tag, delegate: definition.observer}}
    }
  end

  # Capacity is shared with the host instance, so a member waits for a slot
  # instead of failing the task it has already claimed.
  defp start(args, definition, input, opts) do
    case Knotra.start(args.instance, definition, input, args.context, opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :max_children} ->
        if expired?(args) do
          {:error, :max_children}
        else
          Process.sleep(@retry_ms)
          start(args, definition, input, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await(tag, args) do
    receive do
      {:knotra_swarm_child, ^tag, snapshot} -> {:ok, snapshot}
    after
      remaining(args) -> :timeout
    end
  end

  defp error(snapshot) do
    case snapshot[:error] do
      error when is_atom(error) -> error
      _ -> :failed
    end
  end

  defp expired?(args), do: remaining(args) <= 0
  defp remaining(args), do: max(args.deadline_at - System.monotonic_time(:millisecond), 0)

  defp release(pid) do
    Knotra.release(pid)
  catch
    :exit, _ -> :ok
  end
end
