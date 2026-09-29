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

  def prepare_query(_, query, opts), do: {query, opts}
end

defmodule Knotra.DurableFixtures.Ledger do
  use Ecto.Repo, otp_app: :knotra, adapter: Ecto.Adapters.SQLite3

  def initialize do
    Ecto.Adapters.SQL.query!(
      __MODULE__,
      "CREATE TABLE IF NOT EXISTS effects (value TEXT NOT NULL)",
      [],
      log: false
    )
  end

  def record do
    Ecto.Adapters.SQL.query!(__MODULE__, "INSERT INTO effects VALUES (?)", ["unexpected effect"],
      log: false
    )

    {:ok, "fake effect"}
  end

  def entries do
    Ecto.Adapters.SQL.query!(__MODULE__, "SELECT value FROM effects", [], log: false).rows
  end
end

defmodule Knotra.DurableFixtures.Access do
  @behaviour Knotra.Access
  def authorize(action, _id, %{tenant: tenant, permissions: permissions}) do
    if action in permissions, do: {:ok, tenant}, else: {:error, :forbidden}
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
  def authorize(_, %{tenant: "tenant-a"}), do: :ok
  def authorize(_, _), do: {:error, :forbidden}
  def call(_, _), do: Knotra.DurableFixtures.Ledger.record()
end

defmodule Knotra.DurableFixtures.Model do
  @behaviour Knotra.Model
  def checkpoint_version, do: 1

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
  def scope, do: %{tenant: "tenant-a", permissions: [:submit, :inspect, :recover, :checkpoint]}

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

  def repo_options(path) do
    [
      database: path,
      pool_size: 2,
      journal_mode: :wal,
      synchronous: :full,
      foreign_keys: :on,
      busy_timeout: 5_000,
      log: false
    ]
  end
end
