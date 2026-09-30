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
    %{path: path, directory: directory, ledger_path: Path.join(directory, "ledger.sqlite3")}
  end

  defp start_instance do
    start_supervised!(
      {Knotra,
       name: __MODULE__,
       max_executions: 1,
       durable: [repo: Repo, access: Knotra.DurableFixtures.Access, demo_tools: [F.Tool]]}
    )
  end

  test "approval after restart executes one fake effect and continues the saved conversation", %{
    path: path
  } do
    definition = F.definition(owner: self())
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "approve")
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000
    stop_supervised(__MODULE__)
    stop_supervised(Repo)
    # The independent effect ledger remains alive during execution recovery.
    start_supervised!({Repo, F.repo_options(path)})
    start_instance()

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :approve
    }

    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :completed,
                      output: "Completed: fake effect",
                      counts: %{turns: 2, tools: 1, steps: 4}
                    }},
                   2_000

    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "an interrupted admitted effect is blocked, never automatically retried" do
    {id, definition, answer} = pending_answer("uncertain")
    context = Map.put(F.scope(), :effect_gate, self())
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, context, answer)
    assert_receive {:effect_recorded, _}, 2_000
    stop_supervised(__MODULE__)
    start_instance()

    assert {:ok, %{status: :blocked, error: :uncertain_effect}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:ok, %{status: :blocked}} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert {:ok, %{status: :blocked}} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "answer identity, exact arguments, permission and tenant boundaries prevent dispatch" do
    {id, definition, answer} = pending_answer("boundaries")

    for bad <- [%{answer | arguments: %{"amount" => 12.0}}, %{answer | name: "invented"}] do
      assert {:error, :approval_mismatch} =
               Knotra.answer(__MODULE__, id, definition, F.scope(), bad)
    end

    for bad <- [%{answer | version: 9}, %{answer | request_id: "other"}] do
      assert {:error, :stale_approval} = Knotra.answer(__MODULE__, id, definition, F.scope(), bad)
    end

    assert {:error, :forbidden} =
             Knotra.answer(__MODULE__, id, definition, %{F.scope() | permissions: []}, answer)

    assert {:error, :not_found} =
             Knotra.answer(__MODULE__, id, definition, %{F.scope() | tenant: "other"}, answer)

    assert {:ok, %{status: :waiting}} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert F.Ledger.entries() == []
  end

  test "concurrent conflicting and duplicate answers dispatch at most once" do
    {id, definition, answer} = pending_answer("race-answer")
    decisions = List.duplicate(answer, 4) ++ List.duplicate(%{answer | decision: :reject}, 4)

    results =
      Task.async_stream(
        decisions,
        fn a -> Knotra.answer(__MODULE__, id, definition, F.scope(), a) end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.any?(results, &match?({:ok, _}, &1))
    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :answer_conflict}))
    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())

    if snapshot.approval.decision == :approve do
      assert_receive {:knotra, %{id: ^id, status: :completed}}, 2_000
      assert F.Ledger.entries() == [["unexpected effect"]]
    else
      assert snapshot.status == :rejected
      assert F.Ledger.entries() == []
    end

    repeated = %{answer | decision: snapshot.approval.decision}
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), repeated)
  end

  test "a decision committed before a lost answer acknowledgment is not dispatched on recovery" do
    {id, definition, answer} = pending_answer("decision-crash")
    gate_storage(:decided)

    {caller, monitor} =
      spawn_monitor(fn -> Knotra.answer(__MODULE__, id, definition, F.scope(), answer) end)

    assert_receive {:storage_returned, :decided, ^caller}, 2_000
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    assert {:ok, %{status: :decided}} = Knotra.snapshot(__MODULE__, id, F.scope())

    assert {:ok, %{status: :blocked, error: :interrupted}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:ok, %{status: :blocked}} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert F.Ledger.entries() == []
  end

  test "a committed tool result restores the loop without repeating the effect" do
    {id, definition, answer} = pending_answer("result-crash")
    gate_storage(:succeeded)
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert_receive {:storage_returned, :succeeded, worker}, 2_000
    Process.exit(worker, :kill)
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :completed,
                      output: "Completed: fake effect",
                      counts: %{turns: 2, tools: 1, steps: 4}
                    }},
                   2_000

    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "revocation after decision and intent recording prevents dispatch" do
    {id, definition, answer} = pending_answer("revocation")
    permission = start_supervised!({Agent, fn -> true end})
    context = Map.merge(F.scope(), %{permission: permission, authorize_gate: self()})
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, context, answer)
    assert_receive {:business_authorizing, task}, 2_000

    assert {:ok, %{approval: %{disposition: :approved, operation: %{status: :dispatching}}}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    Agent.update(permission, fn _ -> false end)
    send(task, :continue)
    assert_receive {:knotra, %{id: ^id, status: :failed, error: :forbidden}}, 2_000
    assert F.Ledger.entries() == []
  end

  test "an answer that expires before its conditional write cannot consume approval" do
    {id, definition, answer} = pending_answer("expiry", response_timeout: 1_000)
    {:ok, %{approval: approval}} = Knotra.snapshot(__MODULE__, id, F.scope())
    owner = self()

    task =
      Task.async(fn ->
        Process.put(:before_decision_gate, owner)
        Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
      end)

    assert_receive {:before_decision, caller}, 500

    receive do
    after
      max(approval.expires_at - System.system_time(:millisecond) + 2, 0) -> :ok
    end

    send(caller, :continue)
    assert {:error, :approval_expired} = Task.await(task)
    assert F.Ledger.entries() == []
  end

  test "a stale tool result cannot overwrite a newer blocked revision" do
    {id, definition, answer} = pending_answer("stale-result")

    assert {:ok, _} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :effect_gate, self()),
               answer
             )

    assert_receive {:effect_recorded, effect_task}, 2_000

    assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
             Knotra.recover(__MODULE__, id, %{definition | version: "changed"}, F.scope())

    gate_storage(:succeeded)
    send(effect_task, :continue)
    assert_receive {:storage_returned, :succeeded, worker}, 2_000

    assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    Process.exit(worker, :kill)
    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "dispatch intent survives a crash before the host call without automatic retry" do
    {id, definition, answer} = pending_answer("intent-crash")
    gate_storage(:dispatching)

    {caller, monitor} =
      spawn_monitor(fn -> Knotra.answer(__MODULE__, id, definition, F.scope(), answer) end)

    assert_receive {:storage_returned, :dispatching, worker}, 2_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, _}, 2_000

    assert {:ok, %{status: :blocked, error: :uncertain_effect}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert F.Ledger.entries() == []
  end

  test "a recorded fake effect has stable identity and a retry reply does not retry it" do
    {id, definition, answer} = pending_answer("no-effect-retry", max_retries: 3)
    context = Map.put(F.scope(), :effect_reply, {:retry, :temporarily_unavailable})
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, context, answer)

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :blocked,
                      error: :uncertain_effect,
                      approval: %{operation: %{id: operation_id}},
                      counts: %{tools: 1, retries: 0}
                    }},
                   2_000

    assert F.Ledger.operation_ids() == [[operation_id]]
    assert {:ok, %{status: :blocked}} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "continuation does not reset the consumed model budget" do
    {id, definition, answer} = pending_answer("turn-budget", max_turns: 1)
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert_receive {:knotra,
                    %{id: ^id, status: :failed, error: :turn_limit, counts: %{turns: 1, tools: 1}}},
                   2_000

    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "durable approval cannot execute without an explicit demonstration allowlist" do
    {id, definition, answer} = pending_answer("no-allowlist")
    stop_supervised(__MODULE__)
    start_supervised!({Knotra, name: __MODULE__, durable: [repo: Repo, access: F.Access]})

    assert {:error, :demonstration_only} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert {:ok, %{status: :waiting}} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert F.Ledger.entries() == []
  end

  test "a fresh BEAM answers with the restored provider continuation and independent ledger", %{
    path: path,
    ledger_path: ledger_path
  } do
    definition = F.provider_definition(self())
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "fresh-answer")
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 5_000
    stop_supervised(__MODULE__)
    stop_supervised(Repo)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    {output, code} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["test/support/answer_pending.ex", path, ledger_path, id],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "ANSWERED_AFTER_FRESH_BEAM"
    assert F.Ledger.entries() == [["unexpected effect"]]
    start_supervised!({Repo, F.repo_options(path)})
    start_instance()

    assert {:ok, %{status: :completed, counts: %{tools: 1, turns: 2}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())
  end

  test "a failed decision commit leaves the original approval answerable" do
    {id, definition, answer} = pending_answer("failed-decision")

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER fail_decision BEFORE UPDATE ON knotra_executions WHEN NEW.status = 'decided' BEGIN SELECT RAISE(FAIL, 'offline'); END",
      [],
      log: false
    )

    assert {:error, :persistence_unavailable} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert {:ok, %{status: :waiting, approval: %{version: 1, disposition: :pending}}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    assert F.Ledger.entries() == []
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_decision", [], log: false)
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert_receive {:knotra, %{id: ^id, status: :completed}}, 2_000
    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "a failed dispatch-intent commit cannot invoke the effect" do
    {id, definition, answer} = pending_answer("failed-intent")

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER fail_intent BEFORE UPDATE ON knotra_executions WHEN OLD.status = 'decided' AND NEW.status = 'running' BEGIN SELECT RAISE(FAIL, 'offline'); END",
      [],
      log: false
    )

    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert_receive {:knotra, %{id: ^id, status: :blocked}}, 2_000
    assert F.Ledger.entries() == []
  end

  test "an effect whose result cannot be committed is reconciled, not retried" do
    {id, definition, answer} = pending_answer("failed-result")

    assert {:ok, _} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :effect_gate, self()),
               answer
             )

    assert_receive {:effect_recorded, task}, 2_000

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER fail_result BEFORE UPDATE ON knotra_executions BEGIN SELECT RAISE(FAIL, 'offline'); END",
      [],
      log: false
    )

    gate_storage(:succeeded)
    send(task, :continue)
    assert_receive {:storage_returned, :succeeded, worker}, 2_000
    Process.exit(worker, :kill)
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_result", [], log: false)
    stop_supervised(__MODULE__)
    start_instance()

    assert {:ok, %{status: :blocked, error: :uncertain_effect}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert F.Ledger.entries() == [["unexpected effect"]]
  end

  test "answering fails closed on an incompatible checkpoint format" do
    {id, definition, answer} = pending_answer("future-format")
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    bytes = :erlang.term_to_binary(%{checkpoint | format: 2})

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE knotra_executions SET checkpoint = ? WHERE id = ?",
      [{:blob, bytes}, id],
      log: false
    )

    assert {:error, :incompatible_checkpoint} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert F.Ledger.entries() == []
  end

  test "an authorized rejection ends the attempted operation without an effect" do
    definition = F.definition(owner: self())
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "reject")
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :reject
    }

    assert {:ok, %{status: :rejected, error: :approval_rejected}} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert {:ok, %{approval: %{disposition: :rejected, version: 2}}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    assert F.Ledger.entries() == []
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

  test "a gated terminal observer cannot retain the active execution slot" do
    first_definition = %{F.definition(owner: self()) | observer: {F.GatedObserver, self()}}

    assert {:ok, first} =
             Knotra.submit(__MODULE__, first_definition, "Propose", F.scope(), "gated-first")

    assert_receive {:pending_saved, _observer}, 2_000
    assert {:ok, %{status: :waiting}} = Knotra.snapshot(__MODULE__, first, F.scope())

    assert {:ok, second} =
             Knotra.submit(
               __MODULE__,
               F.definition(owner: self()),
               "Propose",
               F.scope(),
               "gated-second"
             )

    assert_receive {:knotra, %{id: ^second, status: :waiting}}, 2_000
    assert F.Ledger.entries() == []
  end

  test "runtime-created atoms are rejected before waiting and remain inspectable in a fresh BEAM",
       %{path: path} do
    atom =
      String.to_atom(
        "runtime_only_#{System.unique_integer([:positive])}_#{System.system_time(:nanosecond)}"
      )

    definition = F.definition(owner: self(), continuation: atom)
    assert {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "runtime-atom")
    assert_receive {:knotra, %{id: ^id, status: :blocked, error: :unsupported_checkpoint}}, 2_000
    refute_receive {:knotra, %{id: ^id, status: :waiting}}
    stop_supervised(__MODULE__)
    stop_supervised(Repo)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    {output, code} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["test/support/recover_pending.ex", path, id, "blocked"],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "RECOVERED_WITHOUT_REPLAY"
  end

  test "a caller killed after acceptance commit but before acknowledgment can resubmit safely" do
    owner = self()
    definition = F.definition(owner: owner)

    {caller, monitor} =
      spawn_monitor(fn ->
        Process.put(:acceptance_commit_gate, {owner, "tenant-a", "lost-ack"})
        result = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "lost-ack")
        send(owner, {:unexpected_ack, result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:acceptance_committed, ^caller, original_id}, 2_000
    refute_receive {:model_called, _}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    refute_receive {:unexpected_ack, _}
    assert {:ok, %{status: :accepted}} = Knotra.snapshot(__MODULE__, original_id, F.scope())

    assert {:ok, ^original_id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "lost-ack")

    assert_receive {:model_called, _}, 2_000
    assert_receive {:knotra, %{id: ^original_id, status: :waiting}}, 2_000

    assert {:ok, ^original_id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "lost-ack")

    refute_receive {:model_called, _}
    assert F.Ledger.entries() == []
  end

  test "ReqLLM provider continuation remains checkpointable with portable atoms", %{path: path} do
    definition = F.provider_definition(self())

    assert {:ok, id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "provider-atoms")

    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 5_000

    assert {:ok, %{exchanges: [%{reply: %{continuation: %ReqLLM.Message{} = message}}]}} =
             Knotra.checkpoint(__MODULE__, id, F.scope())

    assert [%ReqLLM.ToolCall{function: %{name: "propose"}}] = message.tool_calls
    assert message.metadata.response_id == "resp_checkpoint"
    stop_supervised(__MODULE__)
    stop_supervised(Repo)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    {output, code} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++ paths ++ ["test/support/recover_pending.ex", path, id, "provider"],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "RECOVERED_WITHOUT_REPLAY"
  end

  defp gate_storage(phase) do
    armed = start_supervised!({Agent, fn -> true end}, id: make_ref())
    handler = make_ref()

    :ok =
      :telemetry.attach(
        handler,
        [:knotra, :durable_fixtures, :repo, :query],
        &F.StorageGate.handle/4,
        {self(), phase, armed}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp pending_answer(key, opts \\ []) do
    definition = F.definition(owner: self())
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), key, opts)
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000

    {id, definition,
     %{
       request_id: approval.id,
       version: approval.version,
       name: approval.name,
       arguments: approval.arguments,
       decision: :approve
     }}
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
