defmodule Knotra.Observability do
  @moduledoc """
  Built-in, in-memory observability for a Knotra instance.

  Every execution running under `{Knotra, name: MyApp.Agents}` reports its
  definition, model, counters, status, and event timeline to a bounded store
  owned by that instance. The store keeps the most recent
  `:max_records` executions (default 200) and the newest `:max_events` events per
  execution (default 2000). It is a debugging surface, not a durable audit log:
  it does not survive a BEAM restart and never contains authorization context or
  private model continuations.

  Use the public read functions directly, or mount `Knotra.Dashboard.Live` in a
  Phoenix LiveView host.

  ## Correlation

  Non-durable executions can be grouped and linked with the `:trace` option:

      Knotra.start(MyApp.Agents, definition, input, context,
        trace: %{
          agent: "concierge",
          conversation_id: "conversation-42",
          parent_id: parent_execution_id,
          labels: %{"channel" => "support"}
        })

  Durable executions are annotated after `Knotra.submit/6` returns their id:

      Knotra.Observability.annotate(MyApp.Agents, execution_id, %{
        agent: "researcher",
        conversation_id: "conversation-42"
      })

  `link/4` records an explicit edge when the host knows a handoff that cannot be
  expressed through `:parent_id`.

  ## Configuration

      {Knotra,
       name: MyApp.Agents,
       observability: [
         max_records: 200,
         max_events: 2_000,
         notify_ms: 100,
         message_limit: 200
       ]}

  `:max_records` and `:max_events` accept `:infinity`. Record retention evicts
  the oldest terminal execution first; running executions are never evicted.
  """

  alias Knotra.Observability.Store

  @type instance :: GenServer.server()
  @type id :: String.t() | integer()

  @trace_keys [:conversation_id, :parent_id, :agent, :labels]
  @empty_trace %{conversation_id: nil, parent_id: nil, agent: nil, labels: %{}}

  @doc """
  Returns aggregated dashboard data: agents, execution summaries, conversations,
  agent-to-agent edges, recent messages, and counters.

  Options: `:message_limit` (default 200).
  """
  @spec snapshot(instance(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def snapshot(instance, opts \\ []), do: call(instance, {:snapshot, opts})

  @doc "Execution summaries, newest first. Each summary omits the event timeline."
  @spec executions(instance()) :: {:ok, [map()]} | {:error, :not_found}
  def executions(instance) do
    with {:ok, snapshot} <- snapshot(instance), do: {:ok, snapshot.executions}
  end

  @doc "One execution including its event timeline (oldest first)."
  @spec execution(instance(), id()) :: {:ok, map()} | {:error, :not_found}
  def execution(instance, id), do: call(instance, {:execution, id})

  @doc "Agent definitions seen by this instance, including model, tools, and run counts."
  @spec agents(instance()) :: {:ok, [map()]} | {:error, :not_found}
  def agents(instance) do
    with {:ok, snapshot} <- snapshot(instance), do: {:ok, snapshot.agents}
  end

  @doc "Conversation flows, agent-to-agent edges, and explicit links."
  @spec graph(instance()) :: {:ok, map()} | {:error, :not_found}
  def graph(instance) do
    with {:ok, snapshot} <- snapshot(instance), do: {:ok, snapshot.graph}
  end

  @doc "Recent model, tool, input, and failure messages across executions, newest first."
  @spec messages(instance(), keyword()) :: {:ok, [map()]} | {:error, :not_found}
  def messages(instance, opts \\ []) do
    with {:ok, snapshot} <- snapshot(instance, opts), do: {:ok, snapshot.messages}
  end

  @doc "Counters only; useful for cheap polling."
  @spec stats(instance()) :: {:ok, map()} | {:error, :not_found}
  def stats(instance) do
    with {:ok, snapshot} <- snapshot(instance, message_limit: 0), do: {:ok, snapshot.stats}
  end

  @doc "Subscribes the calling process to throttled `{:knotra_observability, instance}` messages."
  @spec subscribe(instance()) :: :ok | {:error, :not_found}
  def subscribe(instance), do: call(instance, {:subscribe, self()})

  @doc "Flushes pending casts. Useful in tests before asserting on recorded data."
  @spec sync(instance()) :: :ok | {:error, :not_found}
  def sync(instance), do: call(instance, :sync)

  @doc """
  Attaches correlation metadata to an execution. Accepts the same keys as the
  `:trace` start option. Unknown keys or malformed values return
  `{:error, :invalid_trace}`.
  """
  @spec annotate(instance(), id(), map() | keyword() | nil) ::
          :ok | {:error, :not_found | :invalid_trace}
  def annotate(instance, id, trace) do
    case normalize_trace(trace) do
      {:ok, trace} -> call(instance, {:annotate, id, trace})
      :error -> {:error, :invalid_trace}
    end
  end

  @doc """
  Records an explicit dependency edge between two execution ids. Options:
  `:label` (binary, default `"delegates"`).
  """
  @spec link(instance(), id(), id(), keyword()) :: :ok | {:error, :not_found}
  def link(instance, from, to, opts \\ []) do
    label = opts |> Keyword.get(:label, "delegates") |> to_string() |> String.slice(0, 120)
    call(instance, {:link, from, to, label})
  end

  @doc false
  def empty_trace, do: @empty_trace

  @doc false
  def describe_definition(%Knotra.Definition{} = definition) do
    model = definition.model

    %{
      version: definition.version,
      model: model_info(model),
      tools: tool_names(definition.tools),
      loop: plugin_name(definition.loop),
      tool_runtime: plugin_name(definition.tool_runtime),
      observer: plugin_name(definition.observer)
    }
  end

  @doc false
  def register(state) do
    if state.instance do
      meta = state.observability_meta

      Store.record(
        state.instance,
        {:register, Map.merge(meta, %{pid: self(), status: state.status, counts: state.counts})}
      )
    end

    :ok
  end

  @doc false
  def record_event(state, entry) do
    if state.instance do
      attrs = state_attrs(state)
      Store.record(state.instance, {:event, state.observability_meta, attrs, entry})
    end

    :ok
  end

  @doc false
  def update(state) do
    if state.instance do
      Store.record(state.instance, {:update, state.id, state_attrs(state)})
    end

    :ok
  end

  defp state_attrs(state) do
    %{
      status: state.status,
      counts: state.counts,
      output: state.output,
      error: state.error,
      observation_error: state.observation_error,
      approval: Map.get(state, :approval),
      input_request: Map.get(state, :input_request)
    }
  end

  @doc false
  @spec normalize_trace(nil | map() | keyword()) :: {:ok, map() | nil} | :error
  def normalize_trace(nil), do: {:ok, nil}

  def normalize_trace(trace) when is_list(trace) do
    if Keyword.keyword?(trace), do: normalize_trace(Map.new(trace)), else: :error
  end

  def normalize_trace(trace) when is_map(trace) do
    if Enum.all?(Map.keys(trace), &(&1 in @trace_keys)) do
      with {:ok, conversation_id} <- normalize_id(trace[:conversation_id]),
           {:ok, parent_id} <- normalize_id(trace[:parent_id]),
           {:ok, agent} <- normalize_label(trace[:agent]),
           {:ok, labels} <- normalize_labels(trace[:labels]) do
        {:ok,
         %{
           conversation_id: conversation_id,
           parent_id: parent_id,
           agent: agent,
           labels: labels
         }}
      end
    else
      :error
    end
  end

  def normalize_trace(_trace), do: :error

  @doc false
  def normalize_label(nil), do: {:ok, nil}
  def normalize_label(value) when is_binary(value), do: {:ok, String.slice(value, 0, 120)}

  def normalize_label(value) when is_atom(value) and value not in [nil, true, false],
    do: {:ok, value |> Atom.to_string() |> String.slice(0, 120)}

  def normalize_label(_value), do: :error

  defp normalize_id(nil), do: {:ok, nil}
  defp normalize_id(value) when is_integer(value), do: {:ok, value}
  defp normalize_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_id(_value), do: :error

  defp normalize_labels(nil), do: {:ok, %{}}

  defp normalize_labels(labels) when is_map(labels) do
    labels
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- label_key(key),
           {:ok, value} <- label_value(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp normalize_labels(_labels), do: :error

  defp label_key(key) when is_binary(key) and key != "", do: {:ok, String.slice(key, 0, 80)}

  defp label_key(key) when is_atom(key) and key not in [nil, true, false],
    do: {:ok, key |> Atom.to_string() |> String.slice(0, 80)}

  defp label_key(_key), do: :error

  defp label_value(value) when is_binary(value), do: {:ok, String.slice(value, 0, 200)}

  defp label_value(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, value}

  defp label_value(_value), do: :error

  defp model_info({module, opts}) do
    %{module: inspect(module), id: model_id(opts)}
  end

  defp model_info(_), do: %{module: nil, id: nil}

  defp model_id(opts) when is_list(opts) do
    value = Keyword.get(opts, :model) || Keyword.get(opts, :model_id)
    if is_binary(value) or is_atom(value), do: to_string(value)
  end

  defp model_id(opts) when is_map(opts) do
    value = Map.get(opts, :model) || Map.get(opts, "model") || Map.get(opts, :model_id)
    if is_binary(value) or is_atom(value), do: to_string(value)
  end

  defp model_id(_opts), do: nil

  defp tool_names(tools) do
    Enum.map(tools, fn module ->
      try do
        case module.definition() do
          %{name: name} when is_binary(name) -> name
          _ -> inspect(module)
        end
      rescue
        _ -> inspect(module)
      catch
        _, _ -> inspect(module)
      end
    end)
  end

  defp plugin_name({module, _opts}), do: inspect(module)
  defp plugin_name(_), do: nil

  defp call(instance, message) do
    GenServer.call(Store.via(instance), message)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
    :exit, {:normal, _} -> {:error, :not_found}
    :exit, {:shutdown, _} -> {:error, :not_found}
    :exit, {{:shutdown, _}, _} -> {:error, :not_found}
    :exit, _ -> {:error, :not_found}
  end
end
