defmodule Knotra.Durable do
  @moduledoc false
  alias Knotra.{Checkpoint, Persistence}
  @compile {:no_warn_undefined, Knotra.Persistence}

  @statuses ~w(accepted running waiting decided ready rejected cancelled expired completed failed blocked)a
  @closeable ~w(completed failed cancelled expired rejected blocked)

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
             approval: nil,
             input_request: nil
           },
           {:ok, saved_snapshot} <- Checkpoint.encode(snapshot),
           {:ok, checkpoint} <-
             Checkpoint.encode(%{
               format: Checkpoint.version(),
               input: input,
               options: limits,
               response_timeout: response_timeout
             }),
           {:ok, row} <-
             Persistence.accept(
               config.repo,
               %{
                 id: id,
                 tenant: tenant,
                 submission_key: key,
                 request_hash: :crypto.hash(:sha256, request),
                 composition: composition,
                 checkpoint: checkpoint,
                 snapshot: saved_snapshot
               },
               config.max_pending
             ) do
        start_accepted(instance, config, row, definition, context)
        {:ok, row.id}
      else
        false -> {:error, :invalid_configuration}
        error -> error
      end
    end)
  end

  def cancel(instance, id, context), do: cancel(instance, id, context, 5)

  defp cancel(instance, id, context, attempts) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :cancel, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
           {:ok, row} <- refresh_expiry(config, row),
           {:ok, snapshot} <- Checkpoint.decode(row.snapshot) do
        cond do
          admitted?(snapshot) ->
            {:error, :already_admitted}

          row.status in ["waiting", "decided", "ready"] ->
            case end_waiting(config, row, snapshot, :cancelled, :cancelled) do
              {:ok, updated} ->
                Checkpoint.decode(updated.snapshot)

              {:error, :stale_execution} ->
                retry_cancel(instance, id, context, attempts)

              error ->
                error
            end

          row.status in ["cancelled", "expired", "rejected", "completed", "failed", "blocked"] ->
            {:ok, snapshot}

          true ->
            {:error, :not_waiting}
        end
      end
    end)
  end

  defp retry_cancel(instance, id, context, attempts) when attempts > 0,
    do: cancel(instance, id, context, attempts - 1)

  defp retry_cancel(_instance, _id, _context, _attempts), do: {:error, :stale_execution}

  # V2 pins admission per operation so prior effects do not prevent cancelling
  # a later pending request. Only the interaction that is current for this record
  # may block cancellation: a later clarification must remain cancellable after an
  # earlier operation completed. The count fallback is for inspecting V1 history.
  defp admitted?(snapshot) do
    case interaction(snapshot) do
      {:approval, %{operation: operation}} when is_map(operation) ->
        Map.get(operation, :admitted, snapshot.counts.tools > 0)

      _ ->
        false
    end
  end

  defp refresh_expiry(config, row, attempts \\ 5)

  defp refresh_expiry(config, %{status: "waiting"} = row, attempts) do
    with {:ok, snapshot} <- Checkpoint.decode(row.snapshot) do
      case interaction(snapshot) do
        {kind, %{disposition: :pending} = request} ->
          if request.expires_at <= System.system_time(:millisecond) do
            {status, reason} =
              if kind == :approval,
                do: {:expired, :approval_expired},
                else: {:expired, :input_expired}

            case end_waiting(
                   config,
                   row,
                   snapshot,
                   status,
                   reason,
                   {:expired, request.expires_at}
                 ) do
              {:error, :stale_execution} ->
                with {:ok, current} <- Persistence.fetch(config.repo, row.tenant, row.id) do
                  cond do
                    current.revision == row.revision -> {:ok, current}
                    attempts > 0 -> refresh_expiry(config, current, attempts - 1)
                    true -> {:error, :stale_execution}
                  end
                end

              result ->
                result
            end
          else
            {:ok, row}
          end

        _ ->
          {:ok, row}
      end
    end
  end

  defp refresh_expiry(_config, row, _attempts), do: {:ok, row}

  # A pending interaction is either an approval or an input request, never both.
  # When nothing is pending (decided/ready rows), the interaction answered most
  # recently is the current one, so an older answered record cannot shadow it.
  defp interaction(snapshot) do
    cond do
      match?(%{input_request: %{disposition: :pending}}, snapshot) ->
        {:input_request, snapshot.input_request}

      match?(%{approval: %{disposition: :pending}}, snapshot) ->
        {:approval, snapshot.approval}

      last_answered(snapshot) == :input_answered ->
        {:input_request, snapshot.input_request}

      last_answered(snapshot) == :approval_answered ->
        {:approval, snapshot.approval}

      Map.get(snapshot, :input_request) != nil ->
        {:input_request, snapshot.input_request}

      true ->
        {:approval, snapshot.approval}
    end
  end

  # Public snapshot events are oldest-first; the shared rule takes newest-first.
  defp last_answered(snapshot),
    do: Knotra.Execution.last_answered(Enum.reverse(snapshot.events))

  defp answered_event(snapshot, type, data, responder_id) do
    sequence =
      case List.last(snapshot.events) do
        nil -> 1
        event -> event.sequence + 1
      end

    %{
      sequence: sequence,
      elapsed_ms:
        case List.last(snapshot.events) do
          nil -> 0
          event -> event.elapsed_ms
        end,
      type: type,
      responder_id: responder_id,
      data: data
    }
  end

  defp end_waiting(config, row, snapshot, status, reason, deadline \\ nil) do
    {key, request} = interaction(snapshot)
    request = %{request | disposition: status, version: request.version + 1}

    request =
      if key == :approval and request[:operation],
        do: put_in(request.operation.status, :not_dispatched),
        else: request

    updated =
      snapshot
      |> Map.put(key, request)
      |> Map.merge(%{status: status, error: reason})

    with {:ok, checkpoint} <- Checkpoint.decode(row.checkpoint),
         {:ok, saved} <- Checkpoint.encode(Map.put(checkpoint, key, request)),
         {:ok, visible} <- Checkpoint.encode(updated) do
      Persistence.update(
        config.repo,
        row,
        [status: Atom.to_string(status), checkpoint: saved, snapshot: visible],
        deadline
      )
    end
  end

  def answer(instance, id, definition, context, answer),
    do: answer(instance, id, definition, context, answer, 5)

  defp answer(instance, id, definition, context, answer, attempts) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :answer, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
           {:ok, row} <- refresh_expiry(config, row),
           {:ok, snapshot} <- Checkpoint.decode(row.snapshot),
           {:ok, checkpoint} <- compatible_checkpoint(row, definition) do
        # The answer shape selects the interaction kind: approvals carry a
        # decision, input requests carry information. Routing by presence alone
        # would let an earlier answered input request swallow a later approval.
        cond do
          is_map(answer) and Map.has_key?(answer, :decision) ->
            answer_approval(
              instance,
              config,
              row,
              snapshot,
              checkpoint,
              definition,
              context,
              answer,
              attempts
            )

          is_map(answer) and Map.has_key?(answer, :answer) ->
            answer_input(
              instance,
              config,
              row,
              snapshot,
              checkpoint,
              definition,
              context,
              answer,
              attempts
            )

          true ->
            {:error, :invalid_answer}
        end
      end
    end)
  end

  defp retry_answer(instance, id, definition, context, answer, attempts) when attempts > 0,
    do: answer(instance, id, definition, context, answer, attempts - 1)

  defp retry_answer(_instance, _id, _definition, _context, _answer, _attempts),
    do: {:error, :stale_execution}

  # Approval answers bind one unchanged operation and keep their five-key shape.
  # An already-answered request is idempotent *before* the allowlist check: removing
  # a tool from `demo_tools` must not turn a harmless duplicate into an error.
  defp answer_approval(
         instance,
         config,
         row,
         snapshot,
         checkpoint,
         definition,
         context,
         answer,
         attempts
       ) do
    with :ok <- valid_answer(snapshot, answer),
         :ok <- validate_answer_context(answer, context) do
      if snapshot.approval.disposition != :pending do
        if row.status == "ready",
          do: admit_continuation(instance, config, row, definition, context),
          else: {:ok, snapshot}
      else
        with :ok <- demonstration(config, definition, snapshot.approval, answer.decision) do
          approval =
            snapshot.approval
            |> Map.put(:answered_version, answer.version)
            |> Map.put(:decision, answer.decision)
            |> Map.put(:responder_id, config.responder_id)
            |> Map.put(:version, answer.version + 1)
            |> Map.put(
              :disposition,
              if(answer.decision == :approve, do: :approved, else: :rejected)
            )

          approval =
            if answer.decision == :approve,
              do:
                Map.put(approval, :operation, %{
                  id: identity(),
                  status: :decided,
                  result: nil,
                  admitted: false
                }),
              else: approval

          updated = %{
            snapshot
            | status: if(answer.decision == :approve, do: :decided, else: :rejected),
              error: if(answer.decision == :reject, do: :approval_rejected),
              approval: approval,
              events:
                snapshot.events ++
                  [answered_event(snapshot, :approval_answered, answer, config.responder_id)]
          }

          with {:ok, saved} <- Checkpoint.encode(%{checkpoint | approval: approval}),
               {:ok, visible} <- Checkpoint.encode(updated),
               {:ok, decided} <-
                 Persistence.update(
                   config.repo,
                   row,
                   [status: Atom.to_string(updated.status), checkpoint: saved, snapshot: visible],
                   snapshot.approval.expires_at
                 ) do
            if answer.decision == :approve do
              admit_continuation(instance, config, decided, definition, context)
            else
              {:ok, updated}
            end
          else
            {:error, :stale_execution} ->
              retry_answer(instance, row.id, definition, context, answer, attempts)

            error ->
              error
          end
        end
      end
    else
      {:duplicate, snapshot} -> {:ok, snapshot}
      error -> error
    end
  end

  defp validate_answer_context(%{decision: :reject}, _context), do: :ok
  defp validate_answer_context(_answer, context) when is_map(context), do: :ok
  defp validate_answer_context(_answer, _context), do: {:error, :invalid_context}

  # Input answers carry information, never permission, so they never dispatch a
  # tool. They continue the same execution after the recorded answer.
  defp answer_input(
         instance,
         config,
         row,
         snapshot,
         checkpoint,
         definition,
         context,
         answer,
         attempts
       ) do
    with :ok <- valid_input_answer(snapshot, answer) do
      cond do
        snapshot.input_request.disposition != :pending ->
          # A stale input answer may only re-admit the input request's own
          # continuation; it must never start an approved approval's dispatch.
          if row.status == "ready" and match?({:input_request, _}, interaction(snapshot)),
            do: admit_continuation(instance, config, row, definition, context),
            else: {:ok, snapshot}

        true ->
          request =
            snapshot.input_request
            |> Map.put(:answered_version, answer.version)
            |> Map.put(:answer, answer.answer)
            |> Map.put(:responder_id, config.responder_id)
            |> Map.put(:version, answer.version + 1)
            |> Map.put(:disposition, :answered)

          updated = %{
            snapshot
            | status: :ready,
              input_request: request,
              events:
                snapshot.events ++
                  [answered_event(snapshot, :input_answered, answer, config.responder_id)]
          }

          with {:ok, saved} <- Checkpoint.encode(Map.put(checkpoint, :input_request, request)),
               {:ok, visible} <- Checkpoint.encode(updated),
               {:ok, decided} <-
                 Persistence.update(
                   config.repo,
                   row,
                   [status: Atom.to_string(updated.status), checkpoint: saved, snapshot: visible],
                   snapshot.input_request.expires_at
                 ) do
            admit_continuation(instance, config, decided, definition, context)
          else
            {:error, :stale_execution} ->
              retry_answer(instance, row.id, definition, context, answer, attempts)

            error ->
              error
          end
      end
    else
      {:duplicate, snapshot} -> {:ok, snapshot}
      error -> error
    end
  end

  defp valid_answer(%{status: :cancelled}, _), do: {:error, :execution_cancelled}
  defp valid_answer(%{status: :expired}, _), do: {:error, :approval_expired}

  defp valid_answer(
         %{approval: approval} = snapshot,
         %{request_id: id, version: version, name: name, arguments: args, decision: decision} =
           answer
       )
       when is_map(approval) and map_size(answer) == 5 and is_integer(version) and version > 0 and
              decision in [:approve, :reject] do
    cond do
      approval.id != id ->
        case Enum.find(
               snapshot.events,
               &match?(%{type: :approval_answered, data: %{request_id: ^id}}, &1)
             ) do
          %{data: ^answer} -> {:duplicate, snapshot}
          nil -> {:error, :stale_approval}
          _ -> {:error, :answer_conflict}
        end

      Map.get(approval, :answered_version, approval.version) != version ->
        {:error, :stale_approval}

      approval.name != name or approval.arguments !== args ->
        {:error, :approval_mismatch}

      approval.disposition != :pending ->
        if approval[:decision] == decision, do: :ok, else: {:error, :answer_conflict}

      snapshot.status != :waiting ->
        {:error, :not_pending}

      true ->
        :ok
    end
  end

  defp valid_answer(_, _), do: {:error, :invalid_answer}

  defp valid_input_answer(%{status: :cancelled}, _), do: {:error, :execution_cancelled}
  defp valid_input_answer(%{status: :expired}, _), do: {:error, :input_expired}

  defp valid_input_answer(
         %{input_request: request} = snapshot,
         %{request_id: id, version: version, answer: text} = answer
       )
       when is_map(request) and map_size(answer) == 3 and is_integer(version) and version > 0 and
              is_binary(text) and text != "" do
    cond do
      request.id != id ->
        case Enum.find(
               snapshot.events,
               &match?(%{type: :input_answered, data: %{request_id: ^id}}, &1)
             ) do
          %{data: ^answer} -> {:duplicate, snapshot}
          nil -> {:error, :stale_input_request}
          _ -> {:error, :answer_conflict}
        end

      Map.get(request, :answered_version, request.version) != version ->
        {:error, :stale_input_request}

      request.disposition != :pending ->
        if request[:answer] == text, do: :ok, else: {:error, :answer_conflict}

      snapshot.status != :waiting ->
        {:error, :not_pending}

      true ->
        :ok
    end
  end

  defp valid_input_answer(_, _), do: {:error, :invalid_answer}

  defp demonstration(_config, _definition, _approval, :reject), do: :ok

  defp demonstration(config, definition, approval, :approve) do
    if demonstration_tool(config, definition, approval.name) do
      :ok
    else
      {:error, :demonstration_only}
    end
  end

  defp demonstration_tool(config, definition, name) do
    module = Enum.find(definition.tools, &(&1.definition().name == name))

    if module != nil and module in config.demo_tools do
      module
    end
  end

  defp admit_continuation(instance, config, row, definition, context, retry \\ false) do
    case start_continuation(instance, config, row, definition, context, retry) do
      {:ok, _} ->
        read_snapshot(config, row.tenant, row.id)

      {:error, :already_running} ->
        read_snapshot(config, row.tenant, row.id)

      {:error, :max_children} when retry ->
        block(config, row, :uncertain_effect)

      {:error, :max_children} ->
        if row.status == "ready" do
          read_snapshot(config, row.tenant, row.id)
        else
          with {:ok, snapshot} <- Checkpoint.decode(row.snapshot),
               {:ok, saved} <- Checkpoint.encode(%{snapshot | status: :ready}),
               {:ok, _} <- Persistence.update(config.repo, row, status: "ready", snapshot: saved) do
            read_snapshot(config, row.tenant, row.id)
          else
            {:error, :stale_execution} -> read_snapshot(config, row.tenant, row.id)
            error -> error
          end
        end

      _ ->
        block(config, row, if(retry, do: :uncertain_effect, else: :dispatch_not_started))
    end
  end

  defp start_continuation(instance, config, row, definition, context, retry \\ false) do
    {:ok, saved} = Checkpoint.decode(row.checkpoint)

    with :ok <- supported(definition, saved.input, Map.to_list(saved.limits)) do
      metadata = %{
        instance: instance,
        repo: config.repo,
        row: row,
        resume: true,
        retry: retry,
        response_timeout: saved.response_timeout,
        demo_tools: config.demo_tools
      }

      DynamicSupervisor.start_child(
        via(instance, :executions),
        {Knotra.Execution,
         {via(instance, :tasks), definition, saved.input, context, Map.to_list(saved.limits),
          metadata}}
      )
    end
  end

  def snapshot(instance, id, context) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :inspect, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
           {:ok, row} <- refresh_expiry(config, row) do
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

  def list(instance, context, opts) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :inspect, nil, context),
           {:ok, status, limit} <- list_options(opts),
           {:ok, rows} <- Persistence.list(config.repo, tenant, status, limit) do
        refresh_and_decode(rows, config)
      end
    end)
  end

  def close(instance, id, context) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :close, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
           {:ok, row} <- refresh_expiry(config, row),
           :ok <- closeable?(row),
           :ok <- Persistence.delete(config.repo, row, @closeable) do
        :ok
      end
    end)
  end

  defp list_options(opts) when is_list(opts) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 100)

    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_configuration}

      Keyword.keys(opts) -- [:status, :limit] != [] ->
        {:error, :invalid_configuration}

      status != nil and status not in @statuses ->
        {:error, :invalid_configuration}

      not is_integer(limit) or limit < 1 ->
        {:error, :invalid_configuration}

      true ->
        {:ok, status && Atom.to_string(status), min(limit, 1_000)}
    end
  end

  defp list_options(_opts), do: {:error, :invalid_configuration}

  defp refresh_and_decode(rows, config) do
    result =
      Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
        with {:ok, row} <- refresh_expiry(config, row),
             {:ok, snapshot} <- Checkpoint.decode(row.snapshot) do
          {:cont, {:ok, [snapshot | acc]}}
        else
          error -> {:halt, error}
        end
      end)

    case result do
      {:ok, snapshots} -> {:ok, Enum.reverse(snapshots)}
      error -> error
    end
  end

  defp closeable?(%{status: status}) when status in @closeable, do: :ok
  defp closeable?(_row), do: {:error, :not_closeable}

  def recover(instance, id, definition, context) do
    protect(fn ->
      with {:ok, config, tenant} <- access(instance, :recover, id, context),
           {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
           {:ok, row} <- refresh_expiry(config, row),
           {:ok, snapshot} <- Checkpoint.decode(row.snapshot),
           {compatibility, checkpoint} <- compatible_checkpoint(row, definition) do
        cond do
          row.status in ["cancelled", "expired", "completed", "failed", "rejected"] or
              (row.status == "blocked" and snapshot.error != :uncertain_effect) ->
            {:ok, snapshot}

          compatibility == :error ->
            block(config, row, :incompatible_checkpoint)

          row.status in ["running", "blocked"] and
            match?(
              %{
                approval: %{
                  disposition: :approved,
                  operation: %{status: :dispatching, admitted: true, result: nil}
                }
              },
              checkpoint
            ) and
              Registry.lookup(instance, {:durable, id}) == [] ->
            if is_map(context) and snapshot.approval === checkpoint.approval and
                 retryable?(config, definition, checkpoint) do
              admit_continuation(instance, config, row, definition, context, true)
            else
              if row.status == "blocked",
                do: {:ok, snapshot},
                else: block(config, row, :uncertain_effect)
            end

          row.status == "blocked" ->
            {:ok, snapshot}

          row.status == "ready" ->
            admit_continuation(instance, config, row, definition, context)

          row.status == "accepted" ->
            with :ok <- supported(definition, checkpoint.input, checkpoint.options) do
              start_accepted(instance, config, row, definition, context)
              read_snapshot(config, tenant, id)
            end

          row.status in ["running", "decided"] and Registry.lookup(instance, {:durable, id}) == [] ->
            if match?(
                 %{approval: %{operation: %{status: :succeeded}}, stage: :observation},
                 checkpoint
               ) do
              start_continuation(instance, config, row, definition, context)
              read_snapshot(config, tenant, id)
            else
              block(config, row, :interrupted)
            end

          true ->
            Checkpoint.decode(row.snapshot)
        end
      end
    end)
  end

  defp retryable?(config, definition, checkpoint) do
    module = demonstration_tool(config, definition, checkpoint.approval.name)

    module != nil and module.definition()[:idempotency] === :operation_id and
      checkpoint.counts.tools > 0 and checkpoint.counts.tools < checkpoint.limits.max_tool_calls and
      checkpoint.counts.retries < checkpoint.limits.max_retries and checkpoint.remaining_ms > 0 and
      (is_nil(checkpoint.active_deadline_at) or
         checkpoint.active_deadline_at > System.system_time(:millisecond))
  end

  defp read_snapshot(config, tenant, id) do
    with {:ok, row} <- Persistence.fetch(config.repo, tenant, id),
         do: Checkpoint.decode(row.snapshot)
  end

  defp start_accepted(instance, config, %{status: "accepted"} = row, definition, context) do
    case compatible_checkpoint(row, definition) do
      {:ok, saved} ->
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

      {:error, :incompatible_checkpoint} ->
        block(config, row, :incompatible_checkpoint)
    end
  end

  defp start_accepted(_, _, _, _, _), do: :ok

  # Called by the execution before any asynchronous callback is dispatched.
  # CAS prevents obsolete workers from overwriting a recovered disposition.
  def persist(%{durable: nil} = state), do: {:ok, state}

  def persist(state) do
    remaining = max(state.deadline_at - System.monotonic_time(:millisecond), 0)

    checkpoint = %{
      format: Checkpoint.version(),
      response_timeout: state.durable.response_timeout,
      input: state.input,
      loop_state: state.loop_state,
      exchanges: state.exchanges,
      last: state.last,
      counts: state.counts,
      limits: state.limits,
      stage: state.stage,
      remaining_ms: remaining,
      active_deadline_at:
        if(state.status == :running, do: System.system_time(:millisecond) + remaining),
      approval: state.approval,
      input_request: state.input_request
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

  def dispatch(state, call) do
    context = Map.put(state.auth, :knotra_operation_id, state.approval.operation.id)

    with {:ok, module, validated} <-
           Knotra.ToolRuntimes.Default.prepare(call, state.definition.tools, context, true),
         :ok <- allowlisted(module, state, validated, call),
         {:ok, row} <- Persistence.fetch(state.durable.repo, state.durable.row.tenant, state.id),
         :ok <- current_row(row, state),
         :ok <- dispatch_deadline(state) do
      # Only the harness can attest non-dispatch. Raw tool returns must not
      # impersonate that internal result after call/2 has already run.
      case module.call(validated, context) do
        {:ok, output} when is_binary(output) -> {:ok, validated, output}
        {kind, reason} when kind in [:error, :retry] and is_atom(reason) -> {kind, reason}
        _ -> {:error, :invalid_plugin_result}
      end
    else
      {:error, reason} -> {:not_dispatched, reason}
    end
  end

  defp allowlisted(module, state, validated, call) do
    if module in state.durable.demo_tools and validated === call.arguments,
      do: :ok,
      else: {:error, :approval_mismatch}
  end

  defp current_row(row, state) do
    if row.revision == state.durable.row.revision and row.status == "running",
      do: :ok,
      else: {:error, :stale_execution}
  end

  defp dispatch_deadline(state) do
    if System.monotonic_time(:millisecond) < state.deadline_at,
      do: :ok,
      else: {:error, :deadline_exceeded}
  end

  def approval(call, tools, auth) do
    with {:ok, _tool, validated} <- Knotra.ToolRuntimes.Default.prepare(call, tools, auth, true),
         :ok <- portable_arguments(validated) do
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

  # Approved arguments are checkpointed; a normalizing validator that introduces
  # non-portable atoms must fail closed before the request is published.
  defp portable_arguments(arguments) do
    case Checkpoint.encode(arguments) do
      {:ok, _bytes} -> :ok
      {:error, _reason} -> {:error, :unsupported_arguments}
    end
  end

  @doc false
  def input_request(%{prompt: prompt}, response_timeout)
      when is_binary(prompt) and prompt != "" do
    %{
      id: identity(),
      version: 1,
      prompt: prompt,
      disposition: :pending,
      expires_at: System.system_time(:millisecond) + response_timeout
    }
  end

  def block_failed(state, reason) do
    {:ok, checkpoint} = Checkpoint.decode(state.durable.row.checkpoint)

    reason =
      if match?(%{approval: %{operation: %{status: :dispatching}}}, checkpoint),
        do: :uncertain_effect,
        else: reason

    block(%{repo: state.durable.repo}, state.durable.row, reason)
  end

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

    if Knotra.Execution.validate(definition, input, opts, true) == :ok and
         definition.loop == {Knotra.Loops.Default, []} and
         definition.tool_runtime == {Knotra.ToolRuntimes.Default, []} and
         function_exported?(model, :checkpoint_version, 0) and
         is_integer(model.checkpoint_version()) and model.checkpoint_version() > 0,
       do: :ok,
       else: {:error, :unsupported_composition}
  end

  defp supported(_, _, _), do: {:error, :unsupported_composition}

  defp compatible_checkpoint(row, definition) do
    with {:ok, fingerprint} <- composition(definition),
         {:ok, saved} <- Checkpoint.decode(row.checkpoint),
         true <- fingerprint == row.composition and saved[:format] === Checkpoint.version(),
         true <- valid_checkpoint?(row, saved),
         :ok <-
           supported(
             definition,
             saved.input,
             if(row.status == "accepted", do: saved.options, else: Map.to_list(saved.limits))
           ) do
      {:ok, saved}
    else
      _ -> {:error, :incompatible_checkpoint}
    end
  rescue
    _ -> {:error, :incompatible_checkpoint}
  end

  defp valid_checkpoint?(%{status: "accepted"}, %{
         input: input,
         options: opts,
         response_timeout: timeout
       }) do
    is_binary(input) and Keyword.keyword?(opts) and is_integer(timeout) and timeout > 0
  end

  defp valid_checkpoint?(
         row,
         %{
           input: input,
           loop_state: loop,
           exchanges: exchanges,
           last: _,
           stage: stage,
           approval: _,
           counts: counts,
           limits: limits,
           remaining_ms: remaining,
           active_deadline_at: deadline,
           response_timeout: timeout
         } = checkpoint
       ) do
    valid_input_record(Map.get(checkpoint, :input_request)) and
      is_binary(input) and is_list(exchanges) and
      ((is_nil(loop) and stage == :setup) or loop in [:model, :reply, {:tools, []}]) and
      is_integer(timeout) and timeout > 0 and
      is_integer(remaining) and remaining >= 0 and remaining <= limits.timeout and
      (is_nil(deadline) or (is_integer(deadline) and deadline >= 0)) and
      (row.status != "running" or is_integer(deadline)) and
      Enum.all?(
        [turns: :max_turns, tools: :max_tool_calls, retries: :max_retries, steps: :max_steps],
        fn {key, limit} ->
          is_integer(counts[key]) and counts[key] >= 0 and counts[key] <= limits[limit]
        end
      )
  end

  defp valid_checkpoint?(_, _), do: false

  # nil is a valid optional key so approval checkpoints predating input requests
  # still restore; an answered record additionally carries its answer and responder.
  defp valid_input_record(nil), do: true

  defp valid_input_record(
         %{
           id: id,
           version: version,
           prompt: prompt,
           disposition: disposition,
           expires_at: expires_at
         } = request
       ) do
    is_binary(id) and id != "" and is_integer(version) and version > 0 and is_binary(prompt) and
      prompt != "" and disposition in [:pending, :answered, :cancelled, :expired] and
      is_integer(expires_at) and
      (disposition != :answered or
         (is_binary(request[:answer]) and is_binary(request[:responder_id]) and
            byte_size(request[:responder_id]) in 1..256))
  end

  defp valid_input_record(_), do: false

  defp composition(%Knotra.Definition{} = definition) do
    {model, _} = definition.model
    Code.ensure_loaded(model)

    if function_exported?(model, :checkpoint_version, 0) do
      with {:ok, data} <-
             Checkpoint.encode(
               {definition.version, plugin_identity(definition.loop), Atom.to_string(model),
                model.checkpoint_version(), plugin_identity(definition.tool_runtime),
                Enum.map(definition.tools, fn tool ->
                  {Atom.to_string(tool), JSON.encode!(tool.definition())}
                end)}
             ) do
        {:ok, :crypto.hash(:sha256, data)}
      end
    else
      {:error, :unsupported_composition}
    end
  end

  defp plugin_identity({module, options}), do: {Atom.to_string(module), options}

  defp access(instance, action, id, context) do
    case Registry.meta(instance, :durable) do
      {:ok, opts} when is_list(opts) ->
        policy = Keyword.fetch!(opts, :access)
        repo = Keyword.fetch!(opts, :repo)

        with {:ok, tenant, responder_id} <-
               access_identity(policy.authorize(action, id, context), action) do
          {:ok,
           %{
             repo: repo,
             demo_tools: Keyword.get(opts, :demo_tools, []),
             max_pending: Keyword.get(opts, :max_pending, :infinity),
             responder_id: responder_id
           }, tenant}
        end

      _ ->
        {:error, :durability_not_configured}
    end
  end

  defp access_identity({:ok, tenant}, action)
       when action != :answer and is_binary(tenant) and tenant != "",
       do: {:ok, tenant, nil}

  defp access_identity({:ok, tenant, responder_id}, _action)
       when is_binary(tenant) and tenant != "" and is_binary(responder_id) and
              byte_size(responder_id) in 1..256,
       do: {:ok, tenant, responder_id}

  defp access_identity(_, _), do: {:error, :forbidden}

  defp identity, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  defp via(instance, key), do: {:via, Registry, {instance, key}}

  defp protect(fun) do
    try do
      fun.()
    rescue
      # A match failure inside the durable state machine is a defect, not host
      # misconfiguration; do not disguise it as `:invalid_configuration`.
      error in [MatchError] -> reraise(error, __STACKTRACE__)
      _ -> {:error, :invalid_configuration}
    catch
      :exit, _ -> {:error, :unavailable}
    end
  end
end
