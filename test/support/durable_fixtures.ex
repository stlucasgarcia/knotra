defmodule Knotra.DurableFixtures.Repo do
  use Ecto.Repo, otp_app: :knotra, adapter: Ecto.Adapters.SQLite3
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
