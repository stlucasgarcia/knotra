defmodule Knotra.Swarm.Board do
  @moduledoc false
  # Swarm-scoped shared board: a public ETS table so concurrent members read and
  # write it without a broker process. A task is claimed with one atomic
  # `select_replace/2` per candidate, so two members can never own the same task.
  # Ownership and completion are authoritative rows, never inferred from messages.

  @doc false
  def new do
    :ets.new(__MODULE__, [
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])
  end

  @doc false
  def seed(tid, tasks) do
    Enum.each(tasks, fn task -> :ets.insert(tid, {{:task, task.id}, task.input, :pending}) end)
    :ok
  end

  @doc false
  def claim(tid, agent, ids) do
    Enum.find_value(ids, :empty, fn id ->
      case :ets.lookup(tid, {:task, id}) do
        [{_, input, :pending}] -> if take(tid, id, agent), do: {:ok, id, input}
        _ -> nil
      end
    end)
  end

  defp take(tid, id, agent) do
    # A constant nested key is not a valid replacement body, so the key is bound
    # through a guard and reused from the head variables.
    head = {:"$1", :"$2", :pending}
    guard = [{:==, :"$1", {:const, {:task, id}}}]
    body = [{{:"$1", :"$2", {:const, {:claimed, agent}}}}]

    :ets.select_replace(tid, [{head, guard, body}]) == 1
  end

  @doc false
  def complete(tid, id, agent, output, meta \\ %{}) when is_binary(output) do
    record(tid, id, agent, :completed, output, nil, meta)
  end

  @doc false
  def fail(tid, id, agent, reason, meta \\ %{}) when is_atom(reason) do
    record(tid, id, agent, :failed, nil, reason, meta)
  end

  defp record(tid, id, agent, status, output, error, meta) do
    :ets.insert(tid, {
      {:outcome, id},
      agent,
      status,
      output,
      error,
      Map.get(meta, :elapsed_ms),
      Map.get(meta, :counts)
    })

    case :ets.lookup(tid, {:task, id}) do
      [{key, input, _}] -> :ets.insert(tid, {key, input, :done})
      [] -> :ok
    end

    :ok
  end

  @doc false
  def outcomes(tid) do
    :ets.select(tid, [
      {{{:outcome, :"$1"}, :"$2", :"$3", :"$4", :"$5", :"$6", :"$7"}, [],
       [
         %{
           id: :"$1",
           agent: :"$2",
           status: :"$3",
           output: :"$4",
           error: :"$5",
           elapsed_ms: :"$6",
           counts: :"$7"
         }
       ]}
    ])
  end

  @doc false
  def close(tid) do
    :ets.delete(tid)
    :ok
  end
end
