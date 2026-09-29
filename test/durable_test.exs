Code.require_file("support/durable_fixtures.ex", __DIR__)

defmodule Knotra.DurableTest do
  use ExUnit.Case, async: false
  alias Knotra.DurableFixtures, as: F
  alias Knotra.DurableFixtures.Repo

  setup do
    directory =
      Path.expand(
        "_build/persistence-tests/#{System.unique_integer([:positive, :monotonic])}-#{System.os_time()}"
      )

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    path = Path.join(directory, "execution.sqlite3")

    start_supervised!(
      {F.Ledger,
       F.repo_options(Path.join(directory, "ledger.sqlite3")) |> Keyword.put(:pool_size, 1)}
    )

    F.Ledger.initialize()
    start_supervised!({Repo, Keyword.put(F.repo_options(path), :pool_size, 1)})
    Ecto.Migrator.up(Repo, 1, Knotra.Persistence.Migration, log: false)
    stop_supervised(Repo)
    start_supervised!({Repo, F.repo_options(path)})
    start_instance()
    %{path: path, directory: directory}
  end

  defp start_instance do
    start_supervised!(
      {Knotra,
       name: __MODULE__,
       max_executions: 1,
       durable: [repo: Repo, access: Knotra.DurableFixtures.Access]}
    )
  end

  test "pending approval survives runtime and storage reconnect without a new model call", %{
    path: path
  } do
    definition = F.definition(owner: self(), api_key: "OPTION_SECRET")

    assert {:ok, id} =
             Knotra.submit(__MODULE__, definition, "Propose payment", F.scope(), "request-1")

    assert is_binary(id)
    assert_receive {:model_called, _}, 2_000
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000
    assert {:ok, before} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert before.approval.arguments == %{"amount" => 12}
    assert before.approval.version == 1
    assert before.approval.disposition == :pending
    assert before.counts.turns == 1
    assert before.counts.tools == 0
    assert is_integer(before.approval.expires_at)
    refute inspect(before) =~ "OPTION_SECRET"

    assert :ok = stop_supervised(__MODULE__)
    assert :ok = stop_supervised(Repo)
    start_supervised!({Repo, F.repo_options(path)})
    start_instance()
    assert {:ok, ^before} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:ok, ^id} =
             Knotra.submit(__MODULE__, definition, "Propose payment", F.scope(), "request-1")

    refute_receive {:model_called, _}

    assert {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    assert checkpoint.input == "Propose payment"
    assert checkpoint.counts.turns == 1
    assert [%{reply: %{continuation: %ReqLLM.Message{}}, results: []}] = checkpoint.exchanges
    refute inspect(checkpoint) =~ "OPTION_SECRET"
    assert F.Ledger.entries() == []
  end

  test "unsupported tool composition is rejected before durable acceptance" do
    definition = F.definition(owner: self())
    definition = %{definition | tools: definition.tools ++ definition.tools}

    assert {:error, :unsupported_composition} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "invalid")

    refute_receive {:model_called, _}
    assert {:ok, _} = Knotra.submit(__MODULE__, F.definition(), "Propose", F.scope(), "invalid")
  end

  test "concurrent matching submissions deduplicate and tenant scope isolates records" do
    definition = F.definition(owner: self(), gated: true)

    tasks =
      for _ <- 1..8,
          do:
            Task.async(fn ->
              Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "same")
            end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert [{:ok, id}] = Enum.uniq(results)
    assert_receive {:model_called, model}, 2_000
    refute_receive {:model_called, _}

    assert {:error, :submission_conflict} =
             Knotra.submit(__MODULE__, definition, "Changed", F.scope(), "same")

    other = %{F.scope() | tenant: "tenant-b"}
    assert {:error, :not_found} = Knotra.snapshot(__MODULE__, id, other)
    assert {:ok, other_id} = Knotra.submit(__MODULE__, definition, "Propose", other, "same")
    refute other_id == id
    assert {:error, :not_found} = Knotra.recover(__MODULE__, id, definition, other)
    assert {:error, :not_found} = Knotra.checkpoint(__MODULE__, id, other)
    send(model, :continue)
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000
  end

  test "inspection and private checkpoint permissions are independent" do
    definition = F.definition(owner: self())
    scope = Map.put(F.scope(), :credential, "AUTH_SECRET")
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", scope, "permissions")
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000
    inspect_only = %{scope | permissions: [:inspect]}
    assert {:ok, _} = Knotra.snapshot(__MODULE__, id, inspect_only)
    assert {:error, :forbidden} = Knotra.checkpoint(__MODULE__, id, inspect_only)
    assert {:error, :forbidden} = Knotra.recover(__MODULE__, id, definition, inspect_only)

    assert {:error, :forbidden} =
             Knotra.submit(__MODULE__, definition, "Propose", inspect_only, "denied")

    assert {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, scope)
    refute inspect(checkpoint) =~ "AUTH_SECRET"
  end

  test "acceptance failure is not acknowledged and does not start a model" do
    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER refuse_accept BEFORE INSERT ON knotra_executions BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      [],
      log: false
    )

    assert {:error, :persistence_unavailable} =
             Knotra.submit(
               __MODULE__,
               F.definition(owner: self()),
               "Propose",
               F.scope(),
               "failed"
             )

    refute_receive {:model_called, _}
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER refuse_accept", [], log: false)
    assert {:ok, _} = Knotra.submit(__MODULE__, F.definition(), "Propose", F.scope(), "failed")
  end

  test "failure committing a pending request never publishes an approval" do
    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER refuse_wait BEFORE UPDATE ON knotra_executions WHEN NEW.status = 'waiting' BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      [],
      log: false
    )

    assert {:ok, id} =
             Knotra.submit(
               __MODULE__,
               F.definition(owner: self()),
               "Propose",
               F.scope(),
               "failed-wait"
             )

    assert_receive {:knotra, %{id: ^id, status: :blocked, error: :persistence_unavailable}}, 2_000
    assert {:ok, %{status: :blocked, approval: nil}} = Knotra.snapshot(__MODULE__, id, F.scope())
    refute_receive {:knotra, %{id: ^id, status: :waiting}}
  end

  test "incompatible recovered composition is visibly blocked without model replay" do
    definition = F.definition(owner: self())
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "version")
    assert_receive {:model_called, _}, 2_000
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000
    stop_supervised(__MODULE__)
    start_instance()

    assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
             Knotra.recover(__MODULE__, id, %{definition | version: "v2"}, F.scope())

    assert {:ok, %{status: :blocked}} = Knotra.snapshot(__MODULE__, id, F.scope())
    refute_receive {:model_called, _}
  end

  test "crash before a pending commit preserves attempts and blocks uncheckpointed work" do
    definition = F.definition(owner: self(), gated: true)
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "crash")
    assert_receive {:model_called, model}, 2_000
    monitor = Process.monitor(model)
    stop_supervised(__MODULE__)
    assert_receive {:DOWN, ^monitor, :process, ^model, _}
    start_instance()

    assert {:ok, %{status: :blocked, error: :interrupted, counts: %{turns: 1}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    refute_receive {:model_called, _}
  end

  test "host validation and authorization run before an approval is presented" do
    definition = F.definition(owner: self(), arguments: %{"amount" => 12, "tenant" => "tenant-b"})
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "malformed")
    assert_receive {:knotra, %{id: ^id, status: :failed, error: :invalid_arguments}}, 2_000
    assert {:ok, %{approval: nil}} = Knotra.snapshot(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    start_instance()

    assert {:ok, forbidden} =
             Knotra.submit(
               __MODULE__,
               F.definition(owner: self()),
               "Propose",
               %{F.scope() | tenant: "tenant-b"},
               "unauthorized"
             )

    assert_receive {:knotra, %{id: ^forbidden, status: :failed, error: :forbidden}}, 2_000
  end

  test "pending approval is readable in a fresh BEAM with no model replay", %{path: path} do
    definition = F.definition(owner: self())
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "fresh-beam")
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000
    stop_supervised(__MODULE__)
    stop_supervised(Repo)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    {output, code} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["test/support/recover_pending.ex", path, id],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "RECOVERED_WITHOUT_REPLAY"
  end

  test "waiting records do not retain the single active execution slot" do
    for index <- 1..3 do
      assert {:ok, id} =
               Knotra.submit(
                 __MODULE__,
                 F.definition(owner: self()),
                 "Propose",
                 F.scope(),
                 "slot-#{index}"
               )

      assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000
      assert {:ok, %{status: :waiting}} = Knotra.snapshot(__MODULE__, id, F.scope())
    end

    assert F.Ledger.entries() == []
  end

  test "accepted work survives capacity exhaustion and can be recovered explicitly" do
    definition = F.definition(owner: self(), gated: true)
    assert {:ok, first} = Knotra.submit(__MODULE__, definition, "First", F.scope(), "first")
    assert_receive {:model_called, _}, 2_000
    assert {:ok, second} = Knotra.submit(__MODULE__, definition, "Second", F.scope(), "second")
    assert {:ok, %{status: :accepted}} = Knotra.snapshot(__MODULE__, second, F.scope())
    assert {:ok, ^second} = Knotra.submit(__MODULE__, definition, "Second", F.scope(), "second")
    refute_receive {:model_called, _}
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, _} = Knotra.recover(__MODULE__, second, F.definition(owner: self()), F.scope())
    assert_receive {:model_called, _}, 2_000
    assert_receive {:knotra, %{id: ^second, status: :waiting}}, 2_000

    assert {:ok, %{status: :blocked, error: :interrupted}} =
             Knotra.recover(__MODULE__, first, definition, F.scope())

    assert F.Ledger.entries() == []
  end

  test "idempotency compares normalized limits rather than keyword order" do
    definition = F.definition(owner: self())

    assert {:ok, id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "normalized",
               max_turns: 8,
               max_steps: 64
             )

    assert {:ok, ^id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "normalized",
               max_steps: 64,
               max_turns: 8
             )

    assert {:ok, ^id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "normalized")

    assert {:error, :submission_conflict} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "normalized",
               max_turns: 7
             )
  end

  test "crash after pending commit but before notification does not lose the request" do
    definition = %{F.definition(owner: self()) | observer: {F.GatedObserver, self()}}

    assert {:ok, id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "missed-notification")

    assert_receive {:model_called, _}, 2_000
    assert_receive {:pending_saved, observer}, 2_000
    monitor = Process.monitor(observer)
    assert {:ok, before} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert before.status == :waiting
    stop_supervised(__MODULE__)
    assert_receive {:DOWN, ^monitor, :process, ^observer, _}
    start_instance()
    assert {:ok, ^before} = Knotra.recover(__MODULE__, id, definition, F.scope())
    refute_receive {:model_called, _}
    assert F.Ledger.entries() == []
  end

  test "SQLite durability fixture uses committed WAL files and separate effect storage" do
    assert [["wal"]] = Ecto.Adapters.SQL.query!(Repo, "PRAGMA journal_mode", [], log: false).rows
    assert [[2]] = Ecto.Adapters.SQL.query!(Repo, "PRAGMA synchronous", [], log: false).rows
    assert [[1]] = Ecto.Adapters.SQL.query!(Repo, "PRAGMA foreign_keys", [], log: false).rows
    # Exqlite 0.41 installs a cancellation-aware busy handler; PRAGMA reports 0.
    # Do not overwrite it with PRAGMA busy_timeout. Concurrent submissions above
    # exercise independent writers using the configured bounded handler.
    assert F.Ledger.entries() == []
  end

  test "nonrecoverable model continuation is visibly blocked, not left running" do
    definition = F.definition(owner: self(), continuation: self())
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "unsafe")
    assert_receive {:model_called, _}, 2_000
    assert_receive {:knotra, %{id: ^id, status: :blocked, error: :unsupported_checkpoint}}, 2_000

    assert {:ok, %{status: :blocked, error: :unsupported_checkpoint}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    assert {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    refute inspect(checkpoint) =~ inspect(self())
  end
end
