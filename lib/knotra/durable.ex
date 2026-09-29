defmodule Knotra.Durable do
  @moduledoc false
  alias Knotra.{Checkpoint, Persistence}
  @compile {:no_warn_undefined, Knotra.Persistence}

  def submit(instance, definition, input, context, key, opts) do
    protect(fn ->
      {response_timeout, limits} = Keyword.pop(opts, :response_timeout, 86_400_000)

      with {:ok, config, tenant} <- access(instance, :submit, nil, context),
           :ok <- supported(definition, input, limits),
           limits = Knotra.Execution.limits(limits),
           true <-
             is_binary(key) and key != "" and is_integer(response_timeout) and
               response_timeout > 0,
           {:ok, composition} <- composition(definition),
           {:ok, request} <- Checkpoint.encode({input, composition, limits, response_timeout}),
           id = identity(),
           snapshot = %{
             id: id,
             definition_version: definition.version,
             status: :accepted,
             output: nil,
             error: nil,
             counts: %{turns: 0, tools: 0, retries: 0, steps: 0},
             events: [],
             observation_error: nil,
             approval: nil
           },
           {:ok, saved_snapshot} <- Checkpoint.encode(snapshot),
           {:ok, checkpoint} <-
             Checkpoint.encode(%{
               format: 1,
               input: input,
               options: limits,
               response_timeout: response_timeout
             }),
           {:ok, row} <-
             Persistence.accept(config.repo, %{
               id: id,
               tenant: tenant,
               submission_key: key,
               request_hash: :crypto.hash(:sha256, request),
               composition: composition,
               checkpoint: checkpoint,
               snapshot: saved_snapshot
             }) do
        start_accepted(instance, config, row, definition, context)
        {:ok, row.id}
      else
        false -> {:error, :invalid_configuration}
        error -> error
      end
    end)
  end

  def snapshot(instance, id, context) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :inspect, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id) do
        Checkpoint.decode(row.snapshot)
      end
    end)
  end

  def checkpoint(instance, id, context) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :checkpoint, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id) do
        Checkpoint.decode(row.checkpoint)
      end
    end)
  end

  def recover(instance, id, definition, context) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :recover, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
           {:ok, fingerprint} <- composition(definition),
           {:ok, checkpoint} <- Checkpoint.decode(row.checkpoint) do
        cond do
          row.composition != fingerprint or checkpoint[:format] != 1 ->
            block(config, row, :incompatible_checkpoint)

          row.status == "accepted" ->
            with :ok <- supported(definition, checkpoint.input, checkpoint.options) do
              start_accepted(instance, config, row, definition, context)
              read_snapshot(config, tenant, id)
            end

          row.status == "running" and Registry.lookup(instance, {:durable, id}) == [] ->
            block(config, row, :interrupted)

          true ->
            Checkpoint.decode(row.snapshot)
        end
      end
    end)
  end

  defp read_snapshot(config, tenant, id) do
    with {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
         do: Checkpoint.decode(row.snapshot)
  end

  defp start_accepted(instance, config, %{status: "accepted"} = row, definition, context) do
    {:ok, saved} = Checkpoint.decode(row.checkpoint)

    metadata = %{
      instance: instance,
      repo: config.repo,
      row: row,
      response_timeout: saved.response_timeout
    }

    DynamicSupervisor.start_child(
      via(instance, :executions),
      {Knotra.Execution,
       {via(instance, :tasks), definition, saved.input, context, saved.options, metadata}}
    )
  end

  defp start_accepted(_, _, _, _, _), do: :ok

  # Called by the execution before any asynchronous callback is dispatched.
  # CAS prevents obsolete workers from overwriting a recovered disposition.
  def persist(%{durable: nil} = state), do: {:ok, state}

  def persist(state) do
    checkpoint = %{
      format: 1,
      input: state.input,
      loop_state: state.loop_state,
      exchanges: state.exchanges,
      last: state.last,
      counts: state.counts,
      limits: state.limits,
      stage: state.stage,
      remaining_ms: max(state.deadline_at - System.monotonic_time(:millisecond), 0),
      approval: state.approval
    }

    with {:ok, saved} <- Checkpoint.encode(checkpoint),
         {:ok, snapshot} <- Checkpoint.encode(Knotra.Execution.public(state)),
         {:ok, row} <-
           Persistence.update(state.durable.repo, state.durable.row,
             status: Atom.to_string(state.status),
             checkpoint: saved,
             snapshot: snapshot
           ) do
      {:ok, %{state | durable: %{state.durable | row: row}}}
    end
  end

  def approval(call, tools, auth) do
    with {:ok, _tool, validated} <- Knotra.ToolRuntimes.Default.prepare(call, tools, auth, true) do
      {:ok,
       %{
         id: identity(),
         version: 1,
         call_id: call.id,
         name: call.name,
         arguments: validated,
         disposition: :pending
       }}
    end
  end

  def block_failed(state, reason),
    do: block(%{repo: state.durable.repo}, state.durable.row, reason)

  defp block(config, row, reason) do
    with {:ok, snapshot} <- Checkpoint.decode(row.snapshot),
         updated = %{snapshot | status: :blocked, error: reason},
         {:ok, encoded} <- Checkpoint.encode(updated),
         {:ok, _} <- Persistence.update(config.repo, row, status: "blocked", snapshot: encoded) do
      {:ok, updated}
    end
  end

  defp supported(%Knotra.Definition{} = definition, input, opts) do
    {model, _} = definition.model

    if Knotra.Execution.valid_options?(definition, input, opts) and
         definition.loop == {Knotra.Loops.Default, []} and
         definition.tool_runtime == {Knotra.ToolRuntimes.Default, []} and
         match?({:ok, _}, Knotra.Execution.tool_definitions(definition, true)) and
         function_exported?(model, :checkpoint_version, 0) and
         is_integer(model.checkpoint_version()) and model.checkpoint_version() > 0,
       do: :ok,
       else: {:error, :unsupported_composition}
  end

  defp supported(_, _, _), do: {:error, :unsupported_composition}

  defp composition(%Knotra.Definition{} = definition) do
    {model, _} = definition.model
    Code.ensure_loaded(model)

    if function_exported?(model, :checkpoint_version, 0) do
      with {:ok, data} <-
             Checkpoint.encode(
               {definition.version, definition.loop, model, model.checkpoint_version(),
                definition.tool_runtime,
                Enum.map(definition.tools, fn tool -> {tool, tool.definition()} end)}
             ) do
        {:ok, :crypto.hash(:sha256, data)}
      end
    else
      {:error, :unsupported_composition}
    end
  end

  defp access(instance, action, id, context) do
    case Registry.meta(instance, :durable) do
      {:ok, opts} when is_list(opts) ->
        policy = Keyword.fetch!(opts, :access)
        repo = Keyword.fetch!(opts, :repo)

        case policy.authorize(action, id, context) do
          {:ok, tenant} when is_binary(tenant) and tenant != "" -> {:ok, %{repo: repo}, tenant}
          _ -> {:error, :forbidden}
        end

      _ ->
        {:error, :durability_not_configured}
    end
  end

  defp identity, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  defp via(instance, key), do: {:via, Registry, {instance, key}}

  defp protect(fun) do
    try do
      fun.()
    rescue
      _ -> {:error, :invalid_configuration}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end
end
