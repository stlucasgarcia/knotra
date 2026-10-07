defmodule Knotra.DurableFixtures.Repo do
  use Ecto.Repo, otp_app: :knotra, adapter: Ecto.Adapters.SQLite3

  @impl true
  def prepare_query(:all, query, opts) do
    # Test-only fault gate at the first read following the committed insert.
    # SQL captures the accepted identity at this storage boundary; behavioral
    # assertions and resubmission still use the public Knotra interface.
    case Process.delete(:acceptance_commit_gate) do
      {owner, tenant, key} ->
        %{rows: [[id]]} =
          Ecto.Adapters.SQL.query!(
            __MODULE__,
            "SELECT id FROM knotra_executions WHERE tenant = ? AND submission_key = ?",
            [tenant, key],
            log: false
          )

        send(owner, {:acceptance_committed, self(), id})

        receive do
          :continue -> :ok
        end

      nil ->
        :ok
    end

    {query, opts}
  end

  def prepare_query(:update_all, query, opts) do
    if owner = Process.delete(:before_decision_gate) do
      send(owner, {:before_decision, self()})

      receive do
        :continue -> :ok
      end
    end

    {query, opts}
  end

  def prepare_query(_, query, opts), do: {query, opts}
end

defmodule Knotra.DurableFixtures.Ledger do
  use Ecto.Repo, otp_app: :knotra, adapter: Ecto.Adapters.SQLite3

  def initialize do
    Ecto.Adapters.SQL.query!(
      __MODULE__,
      "CREATE TABLE IF NOT EXISTS effects (value TEXT NOT NULL, operation_id TEXT NOT NULL)",
      [],
      log: false
    )

    Ecto.Adapters.SQL.query!(
      __MODULE__,
      "CREATE TABLE IF NOT EXISTS idempotent_results (operation_id TEXT PRIMARY KEY, arguments TEXT NOT NULL, result TEXT NOT NULL)",
      [],
      log: false
    )
  end

  # This fake external service atomically binds identity, arguments and result
  # inside its own ledger, never inside Knotra's checkpoint transaction.
  def record_once(operation_id, args) do
    arguments = JSON.encode!(args)

    transact(fn ->
      %{num_rows: inserted} =
        Ecto.Adapters.SQL.query!(
          __MODULE__,
          "INSERT INTO idempotent_results VALUES (?, ?, ?) ON CONFLICT(operation_id) DO NOTHING",
          [operation_id, arguments, "fake effect"],
          log: false
        )

      %{rows: [[bound_arguments, result]]} =
        Ecto.Adapters.SQL.query!(
          __MODULE__,
          "SELECT arguments, result FROM idempotent_results WHERE operation_id = ?",
          [operation_id],
          log: false
        )

      if bound_arguments == arguments do
        if inserted == 1, do: record(operation_id)
        {:ok, result}
      else
        {:error, :approval_mismatch}
      end
    end)
  end

  def record(operation_id) do
    Ecto.Adapters.SQL.query!(
      __MODULE__,
      "INSERT INTO effects VALUES (?, ?)",
      ["unexpected effect", operation_id],
      log: false
    )

    {:ok, "fake effect"}
  end

  def operation_ids do
    Ecto.Adapters.SQL.query!(__MODULE__, "SELECT operation_id FROM effects", [], log: false).rows
  end

  def entries do
    Ecto.Adapters.SQL.query!(__MODULE__, "SELECT value FROM effects", [], log: false).rows
  end
end

defmodule Knotra.DurableFixtures.StorageGate do
  def handle(_event, _measurements, metadata, {owner, phase, armed}) do
    matching =
      String.starts_with?(metadata.query, "UPDATE") and
        Enum.any?(metadata.cast_params || metadata.params || [], fn
          value when is_binary(value) ->
            case Knotra.Checkpoint.decode(value) do
              {:ok, %{format: 2, approval: %{operation: %{status: ^phase}}}} -> true
              _ -> false
            end

          _ ->
            false
        end)

    if matching and Agent.get_and_update(armed, &{&1, false}) do
      send(owner, {:storage_returned, phase, self()})

      receive do
        :continue -> :ok
      end
    end
  end
end

defmodule Knotra.DurableFixtures.Access do
  @behaviour Knotra.Access
  def authorize(action, _id, %{tenant: tenant, permissions: permissions} = context) do
    if action in permissions do
      # Test-only controls at the host authorization boundary; neither grants access.
      if action == :submit and context[:before_acceptance] do
        send(context.before_acceptance, {:before_acceptance, self()})

        receive do
          :continue -> :ok
        end
      end

      case {action, context[:audit_probe]} do
        {:answer, {owner, principal}} -> send(owner, {:authorized_as, principal})
        _ -> :ok
      end

      if action == :answer and Map.has_key?(context, :responder_id),
        do: {:ok, tenant, context.responder_id},
        else: {:ok, tenant}
    else
      {:error, :forbidden}
    end
  end

  def authorize(_, _, _), do: {:error, :forbidden}
end

defmodule Knotra.DurableFixtures.Tool do
  @behaviour Knotra.Tool
  def definition do
    %{
      name: "propose",
      description: "An operation requiring approval",
      read_only: false,
      parameters: %{"type" => "object", "properties" => %{"amount" => %{"type" => "integer"}}}
    }
  end

  def validate(%{"amount" => amount} = args)
      when is_integer(amount) and amount > 0 and map_size(args) == 1,
      do: {:ok, args}

  def validate(_), do: {:error, :invalid_arguments}

  def authorize(_, %{tenant: "tenant-a"} = context) do
    if owner = context[:authorize_gate] do
      send(owner, {:business_authorizing, self()})

      receive do
        :continue -> :ok
      end
    end

    if context[:permission] && not Agent.get(context.permission, & &1),
      do: {:error, :forbidden},
      else: :ok
  end

  def authorize(_, _), do: {:error, :forbidden}

  def call(_, context) do
    effect_reply(Knotra.DurableFixtures.Ledger.record(context.knotra_operation_id), context)
  end

  def effect_reply(result, context) do
    if owner = context[:effect_gate] do
      send(owner, {:effect_recorded, self()})

      receive do
        :continue -> :ok
      end
    end

    Map.get(context, :effect_reply, result)
  end
end

defmodule Knotra.DurableFixtures.IdempotentTool do
  @behaviour Knotra.Tool
  def definition,
    do: Map.put(Knotra.DurableFixtures.Tool.definition(), :idempotency, :operation_id)

  defdelegate validate(args), to: Knotra.DurableFixtures.Tool
  defdelegate authorize(args, context), to: Knotra.DurableFixtures.Tool

  def call(args, context) do
    result = Knotra.DurableFixtures.Ledger.record_once(context.knotra_operation_id, args)
    Knotra.DurableFixtures.Tool.effect_reply(result, context)
  end
end

defmodule Knotra.DurableFixtures.WeakIdempotentTool do
  @behaviour Knotra.Tool
  def definition,
    do: Map.put(Knotra.DurableFixtures.Tool.definition(), :idempotency, :best_effort)

  defdelegate validate(args), to: Knotra.DurableFixtures.Tool
  defdelegate authorize(args, context), to: Knotra.DurableFixtures.Tool
  defdelegate call(args, context), to: Knotra.DurableFixtures.Tool
end

defmodule Knotra.DurableFixtures.Model do
  @behaviour Knotra.Model
  def checkpoint_version, do: 1

  def call(%{exchanges: [%{results: [%{output: output}]}]} = request, opts) do
    if owner = opts[:owner], do: send(owner, {:model_resumed, request})
    {:ok, %Knotra.Reply{text: "Completed: " <> output}}
  end

  def call(_request, opts) do
    if owner = opts[:owner], do: send(owner, {:model_called, self()})
    if opts[:gated], do: receive(do: (:continue -> :ok))
    args = Keyword.get(opts, :arguments, %{"amount" => 12})

    continuation =
      Keyword.get(
        opts,
        :continuation,
        ReqLLM.Context.assistant("",
          tool_calls: [ReqLLM.ToolCall.new("call-1", "propose", JSON.encode!(args))]
        )
      )

    {:ok,
     %Knotra.Reply{
       calls: [%{id: "call-1", name: "propose", arguments: args}],
       continuation: continuation,
       usage: %{input_tokens: 10}
     }}
  end
end

defmodule Knotra.DurableFixtures.LegacyModel do
  @behaviour Knotra.Model
  def call(_, _), do: {:ok, %Knotra.Reply{text: "legacy"}}
end

defmodule Knotra.DurableFixtures.RepeatingModel do
  @behaviour Knotra.Model
  def checkpoint_version, do: 1

  def call(request, opts) do
    n = length(request.exchanges)
    send(opts[:owner], {:repeated_model_attempt, n})

    retry? =
      if store = opts[:retries] do
        Agent.get_and_update(store, fn remaining ->
          {Map.get(remaining, n, 0) > 0, Map.update(remaining, n, 0, &max(&1 - 1, 0))}
        end)
      else
        false
      end

    cond do
      retry? ->
        {:retry, :temporarily_unavailable}

      n < Keyword.get(opts, :operations, 2) ->
        call = %{id: "call-#{n + 1}", name: "propose", arguments: %{"amount" => 12}}

        {:ok,
         %Knotra.Reply{
           calls: [call],
           continuation:
             ReqLLM.Context.assistant("",
               tool_calls: [ReqLLM.ToolCall.new(call.id, call.name, JSON.encode!(call.arguments))]
             )
         }}

      true ->
        {:ok, %Knotra.Reply{text: "Completed: #{n} effects"}}
    end
  end
end

defmodule Knotra.DurableFixtures.OpenAIHTTP do
  def run(request) do
    send(Req.Request.get_private(request, :model_owner), {:model_called, self()})

    body = %{
      "id" => "resp_checkpoint",
      "object" => "response",
      "model" => "gpt-4o-mini",
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call-1",
          "name" => "propose",
          "arguments" => ~s({"amount":12})
        }
      ]
    }

    payload = JSON.decode!(request.body)
    send(Req.Request.get_private(request, :model_owner), {:provider_request, payload})
    results = Enum.filter(payload["input"], &(&1["type"] == "function_call_output"))

    body =
      if results != [] do
        [%{"call_id" => "call-1", "output" => "fake effect"}] = results

        %{
          body
          | "id" => "resp_final",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "status" => "completed",
                "content" => [
                  %{
                    "type" => "output_text",
                    "text" => "Completed: fake effect",
                    "annotations" => []
                  }
                ]
              }
            ]
        }
      else
        body
      end

    {request,
     Req.Response.new(
       status: 200,
       headers: [{"content-type", "application/json"}],
       body: JSON.encode!(body)
     )}
  end
end

defmodule Knotra.DurableFixtures.GatedObserver do
  @behaviour Knotra.Observer
  def record(%{status: :waiting}, owner) do
    send(owner, {:pending_saved, self()})

    receive do
      :continue -> :ok
    end
  end

  def record(_, _), do: :ok
end

defmodule Knotra.DurableFixtures do
  def scope,
    do: %{
      tenant: "tenant-a",
      responder_id: "fake-approver",
      permissions: [:submit, :inspect, :recover, :checkpoint, :answer, :cancel]
    }

  def definition(opts \\ []) do
    %Knotra.Definition{
      version: "approval-v1",
      model: {Knotra.DurableFixtures.Model, opts},
      tools: [Knotra.DurableFixtures.Tool],
      observer: {Knotra.Observers.Send, opts[:owner]}
    }
  end

  def provider_definition(owner) do
    %{
      definition(owner: owner)
      | model:
          {Knotra.Models.ReqLLM,
           model: "openai:gpt-4o-mini",
           options: [
             api_key: "fake-checkpoint-key",
             req_http_options: [
               adapter: Knotra.DurableFixtures.OpenAIHTTP,
               plugins: [fn request -> Req.Request.put_private(request, :model_owner, owner) end]
             ]
           ]}
    }
  end

  # Controlled stored deadline: simulate elapsed offline time without sleeping
  # or changing process state. Inputs come from the authorized public interface.
  def expire_deadline(id, snapshot, checkpoint) do
    snapshot = put_in(snapshot.approval.expires_at, 0)
    checkpoint = put_in(checkpoint.approval.expires_at, 0)

    Ecto.Adapters.SQL.query!(
      Knotra.DurableFixtures.Repo,
      "UPDATE knotra_executions SET snapshot = ?, checkpoint = ?, revision = revision + 1 WHERE id = ?",
      [
        {:blob, :erlang.term_to_binary(snapshot)},
        {:blob, :erlang.term_to_binary(checkpoint)},
        id
      ],
      log: false
    )
  end

  def repo_options(path) do
    [
      database: path,
      pool_size: 2,
      journal_mode: :wal,
      synchronous: :full,
      foreign_keys: :on,
      busy_timeout: 5_000,
      telemetry_prefix: [:knotra, :durable_fixtures, :repo],
      log: false
    ]
  end
end
