defmodule KnotraBots.Chat do
  @moduledoc """
  Chat relay: turns channel messages into durable Knotra executions.

  A human message is stored, then one queued agent message is inserted per
  mentioned agent (or the channel's default agent). A supervised tick submits
  queued messages with a deterministic key, polls their snapshots and records
  status and output. Agent messages may mention teammates; one follow-up hop is
  allowed, which is how a handoff becomes another agent's execution.

  The tick is restart-safe: a queued message without an execution is submitted
  with the same key again, and the durable store deduplicates it.

  Knotra's durable path records a bound approval before every tool call. This
  demo's host policy answers read-only approvals itself as soon as it observes
  them, so only write proposals wait for a human. The gate stays in the durable
  trace; the UI never asks a person for a read-only one.
  """

  use GenServer

  import Ecto.Query
  require Logger

  alias KnotraBots.{Agent, Agents, Channel, Channels, Message, Repo}

  @tick_ms 250
  @max_hops 1
  @max_message 4_000
  @execution_timeout 120_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  def topic(channel_id), do: "chat:" <> channel_id

  def broadcast(channel_id),
    do: Phoenix.PubSub.broadcast(KnotraBots.PubSub, topic(channel_id), {:chat, channel_id})

  @doc "Stores a human message and queues the agent replies it addresses."
  def post(channel_id, text) do
    text = text |> to_string() |> String.trim()

    with %Channel{} = channel <- Channels.get(channel_id) || {:error, :not_found},
         :ok <- valid_text(text),
         {:ok, agents} <- targets(channel, text) do
      now = now()

      human = %Message{
        id: new_id("msg"),
        channel_id: channel.id,
        author_type: "human",
        body: text,
        status: "sent",
        hop: 0,
        inserted_at: now,
        updated_at: now
      }

      reply_at = NaiveDateTime.add(now, 1, :microsecond)

      replies =
        Enum.map(agents, fn agent ->
          reply_message(channel, human.id, agent, reply_at, 0)
        end)

      case Repo.transaction(fn ->
             Repo.insert!(human)
             Repo.insert_all(Message, rows(replies))
             human
           end) do
        {:ok, human} ->
          broadcast(channel.id)
          send(__MODULE__, :tick)
          {:ok, human}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def messages(channel_id) do
    Repo.all(
      from(m in Message,
        where: m.channel_id == ^channel_id,
        order_by: [asc: m.inserted_at, asc: m.id]
      )
    )
  end

  def with_snapshots(channel_id) do
    Enum.map(messages(channel_id), fn message ->
      %{message: message, snapshot: snapshot(message)}
    end)
  end

  @doc "Answers a pending clarification or approval for an agent message."
  def answer(%Message{} = message, answer), do: answer(message, KnotraBots.scope(), answer)

  defp answer(
         %Message{author_type: "agent", execution_id: execution_id} = message,
         scope,
         answer
       )
       when is_binary(execution_id) do
    case Agents.get(message.agent_id) do
      nil ->
        {:error, :agent_missing}

      agent ->
        case Knotra.answer(
               KnotraBots.Instance,
               execution_id,
               Agents.definition(agent),
               scope,
               answer
             ) do
          {:ok, snapshot} ->
            broadcast(message.channel_id)
            send(__MODULE__, :tick)
            {:ok, snapshot}

          {:error, reason} ->
            {:error, reason}
        end
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp answer(_message, _scope, _answer), do: {:error, :not_pending}

  def snapshot(%Message{author_type: "agent", execution_id: execution_id})
      when is_binary(execution_id) do
    case Knotra.snapshot(KnotraBots.Instance, execution_id, KnotraBots.scope()) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  catch
    :exit, _ -> nil
  end

  def snapshot(_message), do: nil

  # --- GenServer --------------------------------------------------------------

  @impl true
  def init(:ok) do
    schedule()

    {:ok,
     %{
       auto_approval_logged: MapSet.new(),
       auto_approval_retry: %{}
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule()

    state =
      Enum.reduce(pending_messages(), state, fn message, state ->
        sync(message, state)
      end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :tick, @tick_ms)

  defp pending_messages do
    Repo.all(
      from(m in Message,
        where: m.author_type == "agent" and m.status in ["queued", "running", "waiting"],
        order_by: [asc: m.inserted_at],
        limit: 100
      )
    )
  rescue
    # The host migrates out-of-band; a boot before migration has nothing to relay.
    _ -> []
  end

  defp sync(%Message{execution_id: nil} = message, state) do
    submit(message)
    state
  end

  defp sync(%Message{} = message, state), do: poll(message, state)

  defp submit(message) do
    case Agents.get(message.agent_id) do
      nil ->
        put_message(message, %{
          status: "failed",
          body: "The agent was deleted before this reply ran."
        })

      agent ->
        definition = Agents.definition(agent)

        case Knotra.submit(
               KnotraBots.Instance,
               definition,
               transcript(message),
               KnotraBots.scope(),
               "chat-" <> message.id,
               timeout: @execution_timeout
             ) do
          {:ok, execution_id} ->
            put_message(message, %{
              execution_id: execution_id,
              definition_version: definition.version,
              status: "running"
            })

          {:error, reason} when reason in [:max_children, :pending_limit] ->
            # Capacity is transient; the next tick retries the same key.
            :ok

          {:error, reason} ->
            Logger.warning("chat submit failed for #{message.id}: #{inspect(reason)}")

            put_message(message, %{
              status: "failed",
              body: "Could not start: #{inspect(reason)}"
            })
        end
    end
  catch
    :exit, _ -> :ok
  end

  defp poll(message, state) do
    case snapshot(message) do
      nil ->
        state

      %{status: :waiting} = snapshot ->
        case approve_read_only(message, snapshot, state) do
          {:ok, state} ->
            put_message(message, %{status: "running"})
            state

          {:hold, state} ->
            put_message(message, %{status: "waiting"})
            state
        end

      %{status: status} when status in [:accepted, :running, :decided, :ready] ->
        put_message(message, %{status: "running"})
        state

      %{status: :completed} = snapshot ->
        updated = put_message(message, %{status: "completed", body: snapshot.output || ""})
        maybe_chain(updated)
        state

      %{status: status} = snapshot ->
        put_message(message, %{status: to_string(status), body: terminal_body(status, snapshot)})
        state
    end
  end

  # The durable runtime always publishes a bound approval before a tool call. This
  # demo's host policy approves read-only tools immediately; a write proposal keeps
  # waiting for a human. The execution and its trace stay durable either way.
  defp approve_read_only(
         %Message{} = message,
         %{approval: %{disposition: :pending} = approval},
         state
       ) do
    key = {message.id, approval.id, approval.version}

    with true <- auto_approval_due?(state, key),
         %Agent{} = agent <- Agents.get(message.agent_id),
         true <- Agents.read_only_tool?(agent, approval.name) do
      case answer(
             message,
             KnotraBots.policy_scope(),
             %{
               request_id: approval.id,
               version: approval.version,
               name: approval.name,
               arguments: approval.arguments,
               decision: :approve
             }
           ) do
        {:ok, _snapshot} ->
          {:ok, clear_auto_approval_failure(state, key)}

        {:error, reason} ->
          {:hold, log_auto_approval_failure(state, key, message, reason)}
      end
    else
      _ -> {:hold, state}
    end
  end

  defp approve_read_only(_message, _snapshot, state), do: {:hold, state}

  @auto_approval_retry_ms 5_000

  defp auto_approval_due?(state, key) do
    case state.auto_approval_retry do
      %{^key => retry_at} -> now_ms() >= retry_at
      _ -> true
    end
  end

  # A persistent failure would otherwise retry and warn on every tick. Retry on a
  # cooldown so transient errors recover, and log once per approval attempt version.
  defp log_auto_approval_failure(state, key, message, reason) do
    unless MapSet.member?(state.auto_approval_logged, key) do
      Logger.warning("read-only auto-approval failed for #{message.id}: #{inspect(reason)}")
    end

    logged = MapSet.put(state.auto_approval_logged, key)
    retry = Map.put(state.auto_approval_retry, key, now_ms() + @auto_approval_retry_ms)

    # Bound the bookkeeping over a long-lived demo; rebuilding is cheap.
    logged = if MapSet.size(logged) > 200, do: MapSet.new(), else: logged
    retry = if map_size(retry) > 200, do: %{}, else: retry

    %{state | auto_approval_logged: logged, auto_approval_retry: retry}
  end

  defp clear_auto_approval_failure(state, key) do
    %{
      state
      | auto_approval_logged: MapSet.delete(state.auto_approval_logged, key),
        auto_approval_retry: Map.delete(state.auto_approval_retry, key)
    }
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp terminal_body(:rejected, _snapshot), do: "Approval rejected."
  defp terminal_body(:expired, _snapshot), do: "The interaction expired."
  defp terminal_body(:cancelled, _snapshot), do: "Cancelled."
  defp terminal_body(:blocked, snapshot), do: "Blocked: #{reason(snapshot)}"
  defp terminal_body(:failed, snapshot), do: "Failed: #{reason(snapshot)}"
  defp terminal_body(status, _snapshot), do: to_string(status)

  defp reason(%{error: nil}), do: "no further detail"
  defp reason(%{error: error}), do: inspect(error)

  defp maybe_chain(%Message{
         status: "completed",
         channel_id: channel_id,
         root_id: root,
         hop: hop,
         body: body,
         agent_id: agent_id
       })
       when hop < @max_hops and is_binary(root) do
    with %Channel{} = channel <- Channels.get(channel_id),
         agents when agents != [] <- Channels.agents(channel.id) do
      already =
        Repo.all(
          from(m in Message,
            where: m.root_id == ^root and m.author_type == "agent",
            select: m.agent_id
          )
        )
        |> MapSet.new()

      targets =
        Enum.filter(agents, fn agent ->
          agent.id != agent_id and agent.id not in already and mention?(agent, body)
        end)

      if targets != [] do
        now = now()

        chain_messages =
          Enum.map(targets, fn agent ->
            reply_message(channel, root, agent, now, hop + 1)
          end)

        Repo.insert_all(Message, rows(chain_messages))
        broadcast(channel.id)
      end
    end
  end

  defp maybe_chain(_message), do: :ok

  defp reply_message(channel, root_id, agent, at, hop) do
    {status, body} =
      case KnotraBots.model_status(agent.model) do
        :ok -> {"queued", ""}
        {:error, reason} -> {"failed", "Model not ready: #{reason}"}
      end

    %Message{
      id: new_id("msg"),
      channel_id: channel.id,
      author_type: "agent",
      agent_id: agent.id,
      body: body,
      status: status,
      root_id: root_id,
      hop: hop,
      inserted_at: at,
      updated_at: at
    }
  end

  defp put_message(message, attrs) do
    changes = Enum.reject(attrs, fn {key, value} -> Map.get(message, key) == value end)

    if changes == [] do
      message
    else
      updated =
        message
        |> Ecto.Changeset.change(Map.new(changes))
        |> Repo.update!()

      broadcast(updated.channel_id)
      updated
    end
  end

  defp transcript(message) do
    channel = Channels.get!(message.channel_id)
    agents = Map.new(Channels.agents(channel.id), &{&1.id, &1.name})

    prior =
      Repo.all(
        from(m in Message,
          where:
            m.channel_id == ^channel.id and m.inserted_at < ^message.inserted_at and
              m.author_type != "system" and
              (m.author_type == "human" or m.status == "completed"),
          order_by: [asc: m.inserted_at]
        )
      )

    lines =
      Enum.map(prior, fn entry ->
        case entry.author_type do
          "human" -> "Human: #{entry.body}"
          "agent" -> "#{Map.get(agents, entry.agent_id, "Agent")}: #{entry.body}"
        end
      end)

    header = "Channel: ##{channel.name}"
    topic = if channel.topic in [nil, ""], do: "", else: "\nTopic: #{channel.topic}"

    Enum.join([header <> topic | lines], "\n\n")
  end

  defp targets(channel, text) do
    agents = Channels.agents(channel.id)

    case Enum.filter(agents, &mention?(&1, text)) do
      [] ->
        case Enum.find(agents, &(&1.id == channel.default_agent_id)) || List.first(agents) do
          nil -> {:error, :no_agents}
          agent -> {:ok, [agent]}
        end

      mentioned ->
        {:ok, mentioned}
    end
  end

  defp mention?(%Agent{handle: handle}, text) when is_binary(handle) and handle != "" do
    Regex.match?(~r/(?:^|[\s(])@#{Regex.escape(handle)}(?![a-z0-9_-])/i, text)
  end

  defp mention?(_agent, _text), do: false

  defp valid_text(text) do
    cond do
      text == "" -> {:error, :empty_message}
      String.length(text) > @max_message -> {:error, :message_too_long}
      true -> :ok
    end
  end

  defp rows(messages) do
    Enum.map(messages, fn message ->
      message |> Map.from_struct() |> Map.delete(:__meta__)
    end)
  end

  defp now, do: NaiveDateTime.utc_now()

  defp new_id(prefix),
    do: prefix <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
