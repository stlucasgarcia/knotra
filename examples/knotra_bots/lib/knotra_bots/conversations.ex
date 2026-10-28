defmodule KnotraBots.Conversations do
  @moduledoc """
  Bot-to-bot conversations backed by durable Knotra executions.

  Each turn is one `Knotra.submit/6` with the deterministic key
  `"conv-<id>-turn-<index>"`, so a retry or resume reuses the accepted execution
  instead of starting a duplicate. The runner is a supervised task; this module
  monitors it and marks the conversation `interrupted` when it dies unexpectedly.

  Conversation definitions are deliberately **tool-free**. Every durable tool call
  requires a human approval, so a relay with tools would stall on the human gate.
  Tools on a bot row still apply to single dashboard runs.
  """

  use GenServer

  import Ecto.Query
  require Logger

  alias KnotraBots.{Bot, Conversation, ConversationTurn, Repo}

  @registry KnotraBots.ConversationRegistry
  @task_supervisor KnotraBots.TaskSupervisor
  @poll_ms 100
  @turn_deadline_ms 150_000
  @turn_timeout_ms 120_000

  # --- Public API -------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Starts the relay for a freshly created conversation."
  def start(id), do: GenServer.call(__MODULE__, {:start, id})

  @doc """
  Requests a stop. The runner stops before the next turn; an in-flight turn
  finishes, because Knotra does not expose cancellation of running work by durable id.
  """
  def stop(id), do: GenServer.call(__MODULE__, {:stop, id})

  @doc "Resumes an `interrupted`/`stopped` conversation when turns remain."
  def resume(id), do: GenServer.call(__MODULE__, {:resume, id})

  @doc "The runner pid registered for a conversation, or nil."
  def runner_pid(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def get(id), do: Repo.get(Conversation, id)
  def get!(id), do: Repo.get!(Conversation, id)

  def list, do: Repo.all(from(c in Conversation, order_by: [desc: c.inserted_at]))

  def turns(conversation_id) do
    Repo.all(
      from(t in ConversationTurn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.index]
      )
    )
  end

  def completed_count(conversation_id) do
    Repo.aggregate(
      from(t in ConversationTurn,
        where: t.conversation_id == ^conversation_id and t.status == "completed"
      ),
      :count
    )
  end

  def broadcast(id),
    do: Phoenix.PubSub.broadcast(KnotraBots.PubSub, topic(id), {:conversation, id})

  def topic(id), do: "conversation:" <> id

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(:ok) do
    sweep_stale()
    {:ok, %{runners: %{}}}
  end

  @impl true
  def handle_call({:start, id}, _from, state) do
    with {:ok, conversation} <- fetch(id),
         :ok <- startable(conversation) do
      start_runner(state, id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, id}, _from, state) do
    with {:ok, conversation} <- fetch(id) do
      if conversation.status == "running", do: set_status(id, "stopping")
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resume, id}, _from, state) do
    with {:ok, conversation} <- fetch(id),
         :ok <- resumable(conversation) do
      set_status(id, "running")
      start_runner(state, id)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.runners, fn {_id, {_pid, runner_ref}} -> runner_ref == ref end) do
      {id, _} ->
        unless reason == :normal, do: interrupt(id)
        {:noreply, %{state | runners: Map.delete(state.runners, id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_runner(state, id) do
    cond do
      Map.has_key?(state.runners, id) ->
        {:reply, {:error, :already_running}, state}

      runner_pid(id) != nil ->
        # The GenServer restarted while a runner task survived; do not double-run.
        {:reply, {:error, :already_running}, state}

      true ->
        {:ok, pid} = Task.Supervisor.start_child(@task_supervisor, fn -> run(id) end)
        ref = Process.monitor(pid)
        {:reply, :ok, %{state | runners: Map.put(state.runners, id, {pid, ref})}}
    end
  end

  defp fetch(id) do
    case get(id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp startable(conversation) do
    if conversation.status == "running" and turns_remaining?(conversation),
      do: :ok,
      else: {:error, :not_startable}
  end

  defp resumable(conversation) do
    if resumable?(conversation, completed_count(conversation.id)),
      do: :ok,
      else: {:error, :not_resumable}
  end

  @doc "Whether a conversation with `completed` turns done can be resumed."
  def resumable?(%Conversation{} = conversation, completed) do
    conversation.status in ["interrupted", "stopped"] and completed < conversation.rounds
  end

  defp turns_remaining?(conversation),
    do: completed_count(conversation.id) < conversation.rounds

  # No runner survives a host restart. Rows still running/stopping without a
  # registered runner are stale; make them resumable instead of leaving them stuck.
  defp sweep_stale do
    conversations =
      Repo.all(from(c in Conversation, where: c.status in ["running", "stopping"]))

    for conversation <- conversations, runner_pid(conversation.id) == nil do
      status = if conversation.status == "stopping", do: "stopped", else: "interrupted"
      set_status(conversation.id, status)
    end
  rescue
    # The host migrates out-of-band; a boot before migration has nothing to sweep.
    _ -> :ok
  end

  defp set_status(id, status) do
    get!(id) |> Ecto.Changeset.change(status: status) |> Repo.update!()
    broadcast(id)
  end

  defp interrupt(id) do
    case get(id) do
      %{status: "stopping"} -> set_status(id, "stopped")
      %{status: "running"} -> set_status(id, "interrupted")
      _ -> :ok
    end
  end

  # --- The runner -------------------------------------------------------------

  defp run(id) do
    case Registry.register(@registry, id, nil) do
      {:ok, _} ->
        do_run(id)

      {:error, {:already_registered, _pid}} ->
        # Another runner already owns this conversation.
        :ok
    end
  end

  defp do_run(id) do
    try do
      relay(id)
    rescue
      error ->
        Logger.error(
          "conversation runner failed: " <> Exception.format(:error, error, __STACKTRACE__)
        )

        interrupt(id)
    catch
      kind, reason ->
        Logger.error(
          "conversation runner exited: " <> Exception.format(kind, reason, __STACKTRACE__)
        )

        interrupt(id)
    end
  end

  defp relay(id) do
    conversation = get!(id)
    bot_a = KnotraBots.Bots.get!(conversation.bot_a_id)
    bot_b = KnotraBots.Bots.get!(conversation.bot_b_id)
    names = %{bot_a.id => bot_a.name, bot_b.id => bot_b.name}

    outcome =
      Enum.reduce_while(0..(conversation.rounds - 1), :ok, fn index, :ok ->
        case get!(id).status do
          status when status in ["stopping", "stopped"] ->
            {:halt, :stopped}

          status when status in ["interrupted", "completed"] ->
            {:halt, :halted}

          _ ->
            bot = if rem(index, 2) == 0, do: bot_a, else: bot_b

            case turn(conversation, index, bot, names) do
              :completed -> {:cont, :ok}
              :interrupted -> {:halt, :interrupted}
            end
        end
      end)

    case {outcome, get!(id).status} do
      {:ok, "running"} -> set_status(id, "completed")
      {:stopped, status} when status in ["stopping", "running"] -> set_status(id, "stopped")
      _ -> :ok
    end
  end

  defp turn(conversation, index, bot, names) do
    case Repo.get_by(ConversationTurn, conversation_id: conversation.id, index: index) do
      %{status: "completed"} ->
        :completed

      existing ->
        input = transcript(conversation, index, names)
        definition = definition(conversation, index, bot)
        previous_id = existing && existing.execution_id

        # Reuse the deterministic key only for an accepted-but-unpolled turn so a
        # resume is idempotent. A failed/blocked turn gets a fresh attempt key,
        # otherwise the dedupe would rebind to the same failed execution forever.
        key =
          case existing && existing.status do
            nil -> submission_key(conversation.id, index)
            "running" -> submission_key(conversation.id, index)
            _attempted -> submission_key(conversation.id, index) <> "-retry-#{new_id()}"
          end

        case Knotra.submit(KnotraBots.Instance, definition, input, KnotraBots.scope(), key,
               timeout: @turn_timeout_ms
             ) do
          {:ok, execution_id} ->
            record_turn(conversation, index, bot, execution_id, input, "running", nil)
            broadcast(conversation.id)
            poll(conversation, index, bot, execution_id, input, deadline())

          {:error, reason} ->
            Logger.error(
              "conversation #{conversation.id} turn #{index} submit failed: #{inspect(reason)}"
            )

            record_turn(conversation, index, bot, previous_id, input, "failed", nil)
            interrupt(conversation.id)
            :interrupted
        end
    end
  end

  defp poll(conversation, index, bot, execution_id, input, deadline) do
    case Knotra.snapshot(KnotraBots.Instance, execution_id, KnotraBots.scope()) do
      {:ok, %{status: :completed} = snapshot} ->
        record_turn(conversation, index, bot, execution_id, input, "completed", snapshot.output)
        broadcast(conversation.id)
        :completed

      {:ok, %{status: :waiting}} ->
        # A tool-free turn can only wait for clarification; there is no auto-answer here.
        record_turn(conversation, index, bot, execution_id, input, "blocked", nil)
        interrupt(conversation.id)
        :interrupted

      {:ok, %{status: status}}
      when status in [:failed, :blocked, :rejected, :cancelled, :expired] ->
        record_turn(conversation, index, bot, execution_id, input, "failed", nil)
        interrupt(conversation.id)
        :interrupted

      {:ok, _running} ->
        if System.monotonic_time(:millisecond) >= deadline do
          record_turn(conversation, index, bot, execution_id, input, "failed", nil)
          interrupt(conversation.id)
          :interrupted
        else
          Process.sleep(@poll_ms)
          poll(conversation, index, bot, execution_id, input, deadline)
        end

      {:error, reason} ->
        Logger.error(
          "conversation #{conversation.id} turn #{index} snapshot failed: #{inspect(reason)}"
        )

        record_turn(conversation, index, bot, execution_id, input, "failed", nil)
        interrupt(conversation.id)
        :interrupted
    end
  end

  defp transcript(conversation, index, names) do
    turns =
      Repo.all(
        from(t in ConversationTurn,
          where:
            t.conversation_id == ^conversation.id and t.index < ^index and t.status == "completed",
          order_by: [asc: t.index]
        )
      )

    case turns do
      [] ->
        "Topic: #{conversation.topic}"

      turns ->
        lines = Enum.map_join(turns, "\n", fn turn -> "#{names[turn.bot_id]}: #{turn.output}" end)
        "Topic: #{conversation.topic}\n\n" <> lines
    end
  end

  defp definition(conversation, index, bot) do
    %Knotra.Definition{
      # The bot id/revision participate in the pinned version because `model/2`
      # depends on the bot's model and system prompt. Editing a bot after
      # submission must surface as `:incompatible_checkpoint`, not silently resume
      # with the new prompt.
      version: "conv-#{conversation.id}-turn-#{index}-#{bot.id}-r#{bot.revision}",
      model: model(bot, index),
      # Tool-free by design: durable tools need a human approval, so a relay with
      # tools would stall on the gate. See the module doc and the conversation page.
      tools: [],
      observer: {Knotra.Observers.Send, nil}
    }
  end

  defp model(%Bot{model: "fake"} = bot, index) do
    {KnotraBots.Models.ConversationFake,
     [name: bot.name, round: index + 1, system_prompt: bot.system_prompt]}
  end

  defp model(%Bot{} = bot, _index), do: KnotraBots.req_llm_plugin(bot)

  defp record_turn(conversation, index, bot, execution_id, input, status, output) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    %ConversationTurn{
      id: "#{conversation.id}-t#{index}",
      conversation_id: conversation.id,
      index: index,
      bot_id: bot.id,
      execution_id: execution_id,
      input: input,
      output: output,
      status: status,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!(
      on_conflict: {:replace, [:execution_id, :input, :output, :status, :updated_at]},
      conflict_target: [:conversation_id, :index]
    )
  end

  defp submission_key(conversation_id, index), do: "conv-#{conversation_id}-turn-#{index}"

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(4), padding: false)

  defp deadline, do: System.monotonic_time(:millisecond) + @turn_deadline_ms
end
