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

  defp start_instance(options \\ []) do
    start_supervised!(
      {Knotra,
       name: __MODULE__,
       max_executions: 1,
       durable:
         [
           repo: Repo,
           access: Knotra.DurableFixtures.Access,
           demo_tools: [F.Tool, F.IdempotentTool, F.WeakIdempotentTool]
         ] ++ options}
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

  test "idempotent recovery reuses identity before effect, after effect and after result commit",
       %{path: path} do
    for phase <- [:dispatching, :effect_recorded, :succeeded] do
      {id, definition, answer} =
        pending_answer("idempotent-#{phase}", [max_retries: 2], F.IdempotentTool)

      context =
        if phase == :effect_recorded,
          do: Map.put(F.scope(), :effect_gate, self()),
          else: F.scope()

      if phase != :effect_recorded, do: gate_storage(phase)

      {caller, monitor} =
        spawn_monitor(fn -> Knotra.answer(__MODULE__, id, definition, context, answer) end)

      case phase do
        :effect_recorded ->
          assert_receive {:effect_recorded, _}, 2_000

        _ ->
          assert_receive {:storage_returned, ^phase, worker}, 2_000
          Process.exit(worker, :kill)
      end

      {:ok, %{approval: %{operation: %{id: operation_id}}}} =
        Knotra.snapshot(__MODULE__, id, F.scope())

      stop_supervised(__MODULE__)
      assert_receive {:DOWN, ^monitor, :process, ^caller, _}, 2_000
      stop_supervised(Repo)
      start_supervised!({Repo, F.repo_options(path)})
      start_instance()
      assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())
      tools = if phase == :succeeded, do: 1, else: 2
      retries = if phase == :succeeded, do: 0, else: 1

      assert_receive {:knotra,
                      %{
                        id: ^id,
                        status: :completed,
                        output: "Completed: fake effect",
                        counts: %{tools: ^tools, retries: ^retries, turns: 2, steps: 4}
                      }},
                     2_000

      assert Enum.count(F.Ledger.operation_ids(), &(&1 == [operation_id])) == 1

      assert {:ok,
              %{
                status: :completed,
                approval: %{operation: %{id: ^operation_id, result: "fake effect"}}
              }} = Knotra.recover(__MODULE__, id, definition, F.scope())

      assert {:ok, %{status: :completed}} =
               Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    end

    assert length(F.Ledger.operation_ids()) == 3
  end

  test "concurrent explicit recoveries admit one retry with unchanged approval and identity" do
    {id, definition, answer, operation_id} = uncertain_effect("retry-race", max_retries: 2)

    assert {:error, :approval_mismatch} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), %{
               answer
               | arguments: %{"amount" => 13}
             })

    context =
      Map.merge(F.scope(), %{authorize_gate: self(), knotra_operation_id: "not-the-operation"})

    results =
      Task.async_stream(1..8, fn _ -> Knotra.recover(__MODULE__, id, definition, context) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &(match?({:ok, _}, &1) or &1 == {:error, :stale_execution}))
    assert_receive {:business_authorizing, task}, 2_000
    refute_receive {:business_authorizing, _}
    assert {:ok, %{counts: %{tools: 2, retries: 1}}} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert F.Ledger.operation_ids() == [[operation_id]]
    send(task, :continue)

    assert_receive {:knotra, %{id: ^id, status: :completed, counts: %{tools: 2, retries: 1}}},
                   2_000

    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "retry authorization refusal preserves knowledge of the original uncertain effect" do
    {id, definition, _answer, operation_id} = uncertain_effect("retry-revoked", max_retries: 1)

    assert {:error, :forbidden} =
             Knotra.recover(__MODULE__, id, definition, %{F.scope() | permissions: []})

    assert {:error, :not_found} =
             Knotra.recover(__MODULE__, id, definition, %{F.scope() | tenant: "other"})

    permission = start_supervised!({Agent, fn -> false end})
    context = Map.put(F.scope(), :permission, permission)
    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, context)

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :blocked,
                      error: :uncertain_effect,
                      counts: %{tools: 2, retries: 1},
                      approval: %{
                        operation: %{id: ^operation_id, status: :dispatching, result: nil}
                      },
                      events: events
                    }},
                   2_000

    assert Enum.any?(
             events,
             &match?(
               %{type: :retry_refused, data: %{reason: :forbidden, operation_id: ^operation_id}},
               &1
             )
           )

    assert {:ok, %{status: :blocked, counts: %{tools: 2, retries: 1}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "uncertain retries cannot replenish tool, retry or active allowances" do
    for {kind, limits} <- [
          {:retries, [max_retries: 0]},
          {:tools, [max_retries: 2, max_tool_calls: 1]},
          {:time, [max_retries: 2]}
        ] do
      {id, definition, _answer, operation_id} = uncertain_effect("retry-limit-#{kind}", limits)

      if kind == :time do
        {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())

        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE knotra_executions SET checkpoint = ?, revision = revision + 1 WHERE id = ?",
          [{:blob, :erlang.term_to_binary(%{saved | remaining_ms: 0})}, id],
          log: false
        )
      end

      for _ <- 1..3 do
        assert {:ok,
                %{
                  status: :blocked,
                  error: :uncertain_effect,
                  counts: %{tools: 1, retries: 0},
                  approval: %{operation: %{id: ^operation_id, result: nil}}
                }} = Knotra.recover(__MODULE__, id, definition, F.scope())
      end

      assert Enum.count(F.Ledger.operation_ids(), &(&1 == [operation_id])) == 1
    end

    {id, definition, _answer, operation_id} = uncertain_effect("retry-exhausted", max_retries: 1)

    assert {:ok, _} =
             Knotra.recover(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :effect_reply, {:retry, :temporarily_unavailable})
             )

    assert_receive {:knotra, %{id: ^id, status: :blocked, counts: %{tools: 2, retries: 1}}}, 2_000

    assert {:ok, %{status: :blocked, counts: %{tools: 2, retries: 1}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert Enum.count(F.Ledger.operation_ids(), &(&1 == [operation_id])) == 1
  end

  test "model retries and uncertain-effect recovery share the same retry allowance" do
    retries = start_supervised!({Agent, fn -> %{0 => 1} end})

    definition = %{
      F.definition(owner: self())
      | model: {F.RepeatingModel, owner: self(), retries: retries},
        tools: [F.IdempotentTool]
    }

    {:ok, id} =
      Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "shared-effect-retries",
        max_retries: 1
      )

    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :approve
    }

    assert {:ok, _} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :effect_reply, {:retry, :temporarily_unavailable}),
               answer
             )

    assert_receive {:knotra,
                    %{id: ^id, status: :blocked, counts: %{tools: 1, retries: 1, turns: 2}}},
                   2_000

    assert {:ok, %{status: :blocked, counts: %{tools: 1, retries: 1, turns: 2}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert length(F.Ledger.operation_ids()) == 1
  end

  test "a weak declaration or removed demonstration allowlist cannot authorize retry" do
    for tool <- [F.Tool, F.WeakIdempotentTool] do
      {id, definition, _answer, operation_id} =
        uncertain_effect("weak-#{tool}", [max_retries: 2], tool)

      assert {:ok, %{status: :blocked, counts: %{tools: 1, retries: 0}}} =
               Knotra.recover(__MODULE__, id, definition, F.scope())

      assert Enum.count(F.Ledger.operation_ids(), &(&1 == [operation_id])) == 1
    end

    {id, definition, _answer, _operation_id} =
      uncertain_effect("removed-retry-allowlist", max_retries: 2)

    stop_supervised(__MODULE__)
    start_supervised!({Knotra, name: __MODULE__, durable: [repo: Repo, access: F.Access]})

    assert {:ok, %{status: :blocked, counts: %{tools: 1, retries: 0}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert length(F.Ledger.operation_ids()) == 3
  end

  test "capacity refusal retains uncertainty and does not turn a retry into ready work" do
    {id, definition, _answer, operation_id} = uncertain_effect("retry-capacity", max_retries: 1)
    assert_receive {:model_called, _}, 2_000

    {:ok, _} =
      Knotra.submit(
        __MODULE__,
        F.definition(owner: self(), gated: true),
        "Hold",
        F.scope(),
        "retry-blocker"
      )

    assert_receive {:model_called, _}, 2_000

    assert {:ok, %{status: :blocked, error: :uncertain_effect, counts: %{tools: 1, retries: 0}}} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert_receive {:knotra, %{id: ^id, status: :completed, counts: %{tools: 2, retries: 1}}},
                   2_000

    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "reliable idempotency cannot revive cancelled, rejected or expired work" do
    for outcome <- [:cancelled, :rejected, :expired] do
      {id, definition, answer} =
        pending_answer("retry-lifecycle-#{outcome}", [max_retries: 2], F.IdempotentTool)

      case outcome do
        :cancelled ->
          assert {:ok, _} = Knotra.cancel(__MODULE__, id, F.scope())

        :rejected ->
          assert {:ok, _} =
                   Knotra.answer(__MODULE__, id, definition, F.scope(), %{
                     answer
                     | decision: :reject
                   })

        :expired ->
          {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
          {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())
          F.expire_deadline(id, snapshot, saved)
      end

      assert {:ok, %{status: ^outcome, counts: %{tools: 0, retries: 0}}} =
               Knotra.recover(__MODULE__, id, definition, F.scope())
    end

    assert F.Ledger.entries() == []
  end

  test "a fresh BEAM retries an uncertain idempotent operation without another ledger effect", %{
    path: path,
    ledger_path: ledger_path
  } do
    {id, definition, _answer, operation_id} = uncertain_effect("fresh-retry", max_retries: 1)
    stop_supervised(__MODULE__)
    stop_supervised(Repo)
    paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

    {output, code} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2"] ++
          paths ++ ["test/support/answer_pending.ex", path, ledger_path, id, "retry"],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "ANSWERED_AFTER_FRESH_BEAM"
    start_supervised!({Repo, F.repo_options(path)})
    start_instance()

    assert {:ok,
            %{
              status: :completed,
              counts: %{tools: 2, retries: 1},
              approval: %{operation: %{id: ^operation_id}}
            }} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "a stale retry result cannot overwrite a newer blocked revision" do
    {id, definition, _answer, operation_id} = uncertain_effect("stale-retry", max_retries: 1)

    assert {:ok, _} =
             Knotra.recover(__MODULE__, id, definition, Map.put(F.scope(), :effect_gate, self()))

    assert_receive {:effect_recorded, task}, 2_000

    assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
             Knotra.recover(__MODULE__, id, %{definition | version: "changed"}, F.scope())

    gate_storage(:succeeded)
    send(task, :continue)
    assert_receive {:storage_returned, :succeeded, worker}, 2_000

    assert {:ok,
            %{
              status: :blocked,
              error: :incompatible_checkpoint,
              counts: %{tools: 2, retries: 1},
              approval: %{operation: %{id: ^operation_id, result: nil}}
            }} = Knotra.snapshot(__MODULE__, id, F.scope())

    Process.exit(worker, :kill)
    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "a failed retry-intent commit cannot consume allowances or invoke the effect" do
    {id, definition, _answer, operation_id} =
      uncertain_effect("failed-retry-intent", max_retries: 1)

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER fail_retry_intent BEFORE UPDATE ON knotra_executions WHEN OLD.status = 'blocked' AND NEW.status = 'running' BEGIN SELECT RAISE(FAIL, 'offline'); END",
      [],
      log: false
    )

    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert_receive {:knotra, %{id: ^id, status: :blocked, counts: %{tools: 1, retries: 0}}}, 2_000
    assert F.Ledger.operation_ids() == [[operation_id]]
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_retry_intent", [], log: false)
    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert_receive {:knotra, %{id: ^id, status: :completed, counts: %{tools: 2, retries: 1}}},
                   2_000

    assert F.Ledger.operation_ids() == [[operation_id]]
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

    decisions =
      for index <- 1..8 do
        decision = if index <= 4, do: :approve, else: :reject
        {%{answer | decision: decision}, "#{decision}-#{index}"}
      end

    results =
      Task.async_stream(
        decisions,
        fn {a, principal} ->
          Knotra.answer(
            __MODULE__,
            id,
            definition,
            Map.put(F.scope(), :responder_id, principal),
            a
          )
        end,
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

    principal = snapshot.approval.responder_id
    decision = snapshot.approval.decision
    assert String.starts_with?(principal, "#{decision}-")
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    assert checkpoint.approval.responder_id == principal

    assert [%{responder_id: ^principal, data: %{decision: ^decision}}] =
             Enum.filter(snapshot.events, &(&1.type == :approval_answered))

    repeated = %{answer | decision: decision}

    assert {:ok, %{approval: %{responder_id: ^principal}}} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), repeated)
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
    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    start_instance()
    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())

    assert {:ok, %{status: :failed, error: :forbidden}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

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

    assert {:ok, %{status: :waiting, approval: %{version: 1, disposition: :pending}} = snapshot} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    refute Map.has_key?(snapshot.approval, :responder_id)
    refute Map.has_key?(checkpoint.approval, :responder_id)
    refute Enum.any?(snapshot.events, &(&1.type == :approval_answered))

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

    assert {:ok, %{status: :blocked, counts: %{tools: 0}}} =
             Knotra.cancel(__MODULE__, id, F.scope())

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
    bytes = :erlang.term_to_binary(%{checkpoint | format: 999})

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

  test "a tool cannot certify non-dispatch after recording its effect" do
    {id, definition, answer} = pending_answer("forged-non-dispatch")
    context = Map.put(F.scope(), :effect_reply, {:not_dispatched, :forbidden})
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, context, answer)

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :blocked,
                      error: :uncertain_effect,
                      approval: %{operation: %{status: :dispatching, id: operation_id}}
                    }},
                   2_000

    assert F.Ledger.operation_ids() == [[operation_id]]
    assert {:ok, %{status: :blocked}} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "durable cancellation survives restart and rejects late answers" do
    {id, definition, answer} = pending_answer("cancel-waiting")

    assert {:ok, %{status: :cancelled, error: :cancelled}} =
             Knotra.cancel(__MODULE__, id, F.scope())

    assert {:ok, %{status: :cancelled}} = Knotra.cancel(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, %{status: :cancelled}} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:error, :execution_cancelled} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert F.Ledger.entries() == []
  end

  test "inspection persists expiry after the runtime and Repo restart", %{path: path} do
    {id, definition, answer} = pending_answer("expire-offline")
    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    F.expire_deadline(id, snapshot, checkpoint)
    stop_supervised(Repo)
    start_supervised!({Repo, F.repo_options(path)})
    start_instance()

    assert {:ok,
            %{status: :expired, error: :approval_expired, approval: %{disposition: :expired}}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    assert {:ok, %{status: :expired}} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:error, :approval_expired} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert F.Ledger.entries() == []
  end

  test "cancellation checks host authority and tenant without changing a waiting request" do
    {id, _definition, _answer} = pending_answer("cancel-boundaries")
    {:ok, before} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert {:error, :forbidden} = Knotra.cancel(__MODULE__, id, %{F.scope() | permissions: []})
    assert {:error, :not_found} = Knotra.cancel(__MODULE__, id, %{F.scope() | tenant: "other"})
    assert {:ok, ^before} = Knotra.snapshot(__MODULE__, id, F.scope())
  end

  test "cancellation committed after decision but before admission fences the delayed worker" do
    {id, definition, answer} = pending_answer("cancel-decided")
    gate_storage(:decided)
    task = Task.async(fn -> Knotra.answer(__MODULE__, id, definition, F.scope(), answer) end)
    assert_receive {:storage_returned, :decided, caller}, 2_000

    assert {:ok, %{status: :cancelled, approval: %{operation: %{status: :not_dispatched}}}} =
             Knotra.cancel(__MODULE__, id, F.scope())

    send(caller, :continue)
    assert {:error, :stale_execution} = Task.await(task)

    assert {:ok, %{status: :cancelled}} =
             Knotra.recover(__MODULE__, id, %{definition | version: "obsolete"}, F.scope())

    assert {:error, :execution_cancelled} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert F.Ledger.entries() == []
  end

  test "cancellation after admission cannot erase an eventual effect result" do
    {id, definition, answer} = pending_answer("cancel-too-late")
    gate_storage(:dispatching)
    task = Task.async(fn -> Knotra.answer(__MODULE__, id, definition, F.scope(), answer) end)
    assert_receive {:storage_returned, :dispatching, worker}, 2_000
    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())
    assert F.Ledger.entries() == []
    send(worker, :continue)
    assert {:ok, _} = Task.await(task)

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :completed,
                      approval: %{operation: %{id: operation_id, result: "fake effect"}}
                    }},
                   2_000

    assert F.Ledger.operation_ids() == [[operation_id]]
    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())
    assert {:ok, %{status: :completed}} = Knotra.snapshot(__MODULE__, id, F.scope())
  end

  test "cancellation after an uncertain effect preserves its dispatch history across restart" do
    {id, definition, answer} = pending_answer("cancel-uncertain")

    assert {:ok, _} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :effect_gate, self()),
               answer
             )

    assert_receive {:effect_recorded, _}, 2_000
    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    start_instance()

    assert {:ok,
            %{
              status: :blocked,
              error: :uncertain_effect,
              approval: %{operation: %{id: operation_id}}
            }} =
             Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:error, :already_admitted} = Knotra.cancel(__MODULE__, id, F.scope())
    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "approve, reject and cancel contenders leave one durable outcome" do
    {id, definition, answer} = pending_answer("cancel-race")

    results =
      Task.async_stream(
        List.duplicate([:approve, :reject, :cancel], 3) |> List.flatten(),
        fn
          :cancel ->
            Knotra.cancel(__MODULE__, id, F.scope())

          decision ->
            Knotra.answer(__MODULE__, id, definition, F.scope(), %{answer | decision: decision})
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, fn
             {:ok, _} ->
               true

             {:error, reason} ->
               reason in [
                 :execution_cancelled,
                 :answer_conflict,
                 :already_admitted,
                 :stale_execution,
                 :stale_approval
               ]
           end)

    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())

    if snapshot.status in [:running, :decided, :completed] do
      assert_receive {:knotra, %{id: ^id, status: :completed}}, 2_000
      assert F.Ledger.entries() == [["unexpected effect"]]
    else
      assert snapshot.status in [:cancelled, :rejected]
      assert F.Ledger.entries() == []
    end
  end

  test "concurrent inspection, recovery, answers and cancellation persist expiry once" do
    {id, definition, answer} = pending_answer("expiry-race")
    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    F.expire_deadline(id, snapshot, checkpoint)

    results =
      Task.async_stream(
        [:inspect, :recover, :approve, :reject, :cancel, :inspect, :recover],
        fn
          :inspect ->
            Knotra.snapshot(__MODULE__, id, F.scope())

          :recover ->
            Knotra.recover(__MODULE__, id, definition, F.scope())

          :cancel ->
            Knotra.cancel(__MODULE__, id, F.scope())

          decision ->
            Knotra.answer(__MODULE__, id, definition, F.scope(), %{answer | decision: decision})
        end,
        max_concurrency: 7
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(
             results,
             &(match?({:ok, %{status: :expired}}, &1) or &1 == {:error, :approval_expired})
           )

    assert {:ok, %{approval: %{version: 2}, counts: %{tools: 0, turns: 1}}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    {:ok, expired_checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    assert expired_checkpoint.remaining_ms == checkpoint.remaining_ms
    assert expired_checkpoint.counts == checkpoint.counts
    assert F.Ledger.entries() == []
  end

  test "expiry winning before a queued answer fences that answer" do
    {id, definition, answer} = pending_answer("expiry-delayed-answer")
    owner = self()

    task =
      Task.async(fn ->
        Process.put(:before_decision_gate, owner)
        Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
      end)

    assert_receive {:before_decision, caller}, 2_000
    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    F.expire_deadline(id, snapshot, checkpoint)
    assert {:ok, %{status: :expired}} = Knotra.snapshot(__MODULE__, id, F.scope())
    send(caller, :continue)
    assert {:error, :approval_expired} = Task.await(task)
    assert F.Ledger.entries() == []
  end

  test "failed cancellation and expiry writes never acknowledge terminal transitions" do
    {id, definition, answer} = pending_answer("lifecycle-failure")

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER fail_lifecycle BEFORE UPDATE ON knotra_executions WHEN NEW.status IN ('cancelled', 'expired') BEGIN SELECT RAISE(FAIL, 'offline'); END",
      [],
      log: false
    )

    assert {:error, :persistence_unavailable} = Knotra.cancel(__MODULE__, id, F.scope())
    assert {:ok, %{status: :waiting} = snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    F.expire_deadline(id, snapshot, checkpoint)
    assert {:error, :persistence_unavailable} = Knotra.snapshot(__MODULE__, id, F.scope())

    assert {:error, :persistence_unavailable} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_lifecycle", [], log: false)
    assert {:ok, %{status: :expired}} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert F.Ledger.entries() == []
  end

  test "answering alone persists expiry without inspection or a timer" do
    {id, definition, answer} = pending_answer("answer-expires")
    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    F.expire_deadline(id, snapshot, checkpoint)

    assert {:error, :approval_expired} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert {:ok, %{approval: %{disposition: :expired}}} =
             Knotra.checkpoint(__MODULE__, id, F.scope())

    assert F.Ledger.entries() == []
  end

  test "a fresh BEAM preserves cancellation and discovers offline expiry", %{path: path} do
    for terminal <- [:cancelled, :expired] do
      {id, _definition, _answer} = pending_answer("fresh-lifecycle-#{terminal}")

      if terminal == :cancelled do
        assert {:ok, %{status: :cancelled}} = Knotra.cancel(__MODULE__, id, F.scope())
      else
        {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
        {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
        F.expire_deadline(id, snapshot, checkpoint)
      end

      stop_supervised(__MODULE__)
      stop_supervised(Repo)
      paths = Path.wildcard(Path.expand("_build/test/lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])

      {output, code} =
        System.cmd(
          System.find_executable("elixir"),
          ["--erl", "+S 2:2"] ++
            paths ++ ["test/support/recover_pending.ex", path, id, Atom.to_string(terminal)],
          stderr_to_stdout: true
        )

      assert code == 0, output
      assert output =~ "RECOVERED_WITHOUT_REPLAY"
      start_supervised!({Repo, F.repo_options(path)})
      start_instance()
      assert {:ok, %{status: ^terminal}} = Knotra.snapshot(__MODULE__, id, F.scope())
    end

    assert F.Ledger.entries() == []
  end

  test "pending capacity rejects new work atomically but preserves matching submissions" do
    stop_supervised(__MODULE__)
    start_instance(max_pending: 1)
    definition = F.definition(owner: self())

    results =
      Task.async_stream(
        1..8,
        fn n ->
          {n, Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "bounded-#{n}")}
        end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{key, {:ok, id}}] = Enum.filter(results, &match?({_, {:ok, _}}, &1))
    assert 7 == Enum.count(results, &match?({_, {:error, :pending_limit}}, &1))
    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000

    assert {:ok, ^id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "bounded-#{key}")

    assert {:ok, %{status: :cancelled}} = Knotra.cancel(__MODULE__, id, F.scope())

    assert {:ok, other} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "after-slot")

    assert other != id

    assert {:error, :pending_limit} =
             Knotra.submit(
               __MODULE__,
               definition,
               "Propose",
               %{F.scope() | tenant: "another"},
               "global-bound"
             )

    stop_supervised(__MODULE__)
    start_instance(max_pending: 1)

    assert {:error, :pending_limit} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "after-restart-bound")

    assert F.Ledger.entries() == []
  end

  test "matching resubmission cannot start queued work with an incompatible checkpoint" do
    {:ok, _} =
      Knotra.submit(
        __MODULE__,
        F.definition(owner: self(), gated: true),
        "Hold",
        F.scope(),
        "legacy-blocker"
      )

    assert_receive {:model_called, _}, 2_000
    definition = F.definition(owner: self())
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "legacy-accepted")
    assert {:ok, %{status: :accepted}} = Knotra.snapshot(__MODULE__, id, F.scope())
    {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())
    bytes = :erlang.term_to_binary(%{saved | format: 1})

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE knotra_executions SET checkpoint = ? WHERE id = ?",
      [{:blob, bytes}, id],
      log: false
    )

    stop_supervised(__MODULE__)
    start_instance()

    assert {:ok, ^id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "legacy-accepted")

    assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
             Knotra.snapshot(__MODULE__, id, F.scope())

    refute_receive {:model_called, _}
    assert F.Ledger.entries() == []
    assert {:ok, %{format: 1}} = Knotra.checkpoint(__MODULE__, id, F.scope())
  end

  test "an approved decision waits for active capacity and resumes once after restart" do
    {id, definition, answer} = pending_answer("ready-decision")
    assert_receive {:model_called, _}

    {:ok, _blocker} =
      Knotra.submit(
        __MODULE__,
        F.definition(owner: self(), gated: true),
        "Hold",
        F.scope(),
        "hold-slot"
      )

    assert_receive {:model_called, _}, 2_000
    assert {:ok, %{status: :ready}} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert {:ok, %{status: :ready}} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert F.Ledger.entries() == []
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert_receive {:knotra, %{id: ^id, status: :completed, counts: %{tools: 1, turns: 2}}}, 2_000

    assert {:ok, %{status: :completed}} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert length(F.Ledger.operation_ids()) == 1
  end

  test "two approval waits preserve shared model retries and attempts through restart" do
    retries = start_supervised!({Agent, fn -> %{0 => 1, 1 => 1} end})

    definition = %{
      F.definition(owner: self())
      | model: {F.RepeatingModel, owner: self(), retries: retries}
    }

    {:ok, id} =
      Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "repeated-waits",
        max_retries: 2,
        max_turns: 5,
        max_tool_calls: 2
      )

    answers =
      for index <- 1..2 do
        assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000
        stop_supervised(__MODULE__)
        start_instance()

        answer = %{
          request_id: approval.id,
          version: approval.version,
          name: approval.name,
          arguments: approval.arguments,
          decision: :approve
        }

        principal = "wait-#{index}"
        context = Map.put(F.scope(), :responder_id, principal)
        assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, context, answer)
        assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
        {answer, principal}
      end

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :completed,
                      output: "Completed: 2 effects",
                      counts: %{turns: 5, tools: 2, retries: 2, steps: 6}
                    }},
                   2_000

    {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    receipts = Enum.filter(snapshot.events, &(&1.type == :approval_answered))
    assert length(receipts) == 2

    for {answer, principal} <- answers do
      assert Enum.any?(receipts, &match?(%{data: ^answer, responder_id: ^principal}, &1))

      assert {:ok, %{status: :completed}} =
               Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    end

    assert length(F.Ledger.operation_ids()) == 2
    assert_receive {:repeated_model_attempt, 0}
    assert_receive {:repeated_model_attempt, 0}
    assert_receive {:repeated_model_attempt, 1}
    assert_receive {:repeated_model_attempt, 1}
    assert_receive {:repeated_model_attempt, 2}
    refute_receive {:repeated_model_attempt, _}
  end

  test "running downtime consumes active allowance before restored model work" do
    {id, definition, answer} = pending_answer("active-downtime")
    gate_storage(:succeeded)
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert_receive {:storage_returned, :succeeded, worker}, 2_000
    {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())
    bytes = :erlang.term_to_binary(Map.put(saved, :active_deadline_at, 0))

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE knotra_executions SET checkpoint = ?, revision = revision + 1 WHERE id = ?",
      [{:blob, bytes}, id],
      log: false
    )

    Process.exit(worker, :kill)
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, _} = Knotra.recover(__MODULE__, id, definition, F.scope())
    assert_receive {:knotra, %{id: ^id, status: :failed, error: :deadline_exceeded}}, 2_000
    refute_receive {:model_resumed, _}
    assert length(F.Ledger.operation_ids()) == 1
  end

  test "incompatible or unreadable recovery becomes publicly blocked" do
    for kind <- [
          :legacy_model,
          :old_format,
          :float_format,
          :corrupt,
          :missing_allowance,
          :loop_state
        ] do
      {id, definition, _answer} = pending_answer("compat-#{kind}")
      {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())

      definition =
        if kind == :legacy_model, do: %{definition | model: {F.LegacyModel, []}}, else: definition

      bytes =
        case kind do
          :old_format ->
            :erlang.term_to_binary(%{saved | format: 1})

          :float_format ->
            :erlang.term_to_binary(%{saved | format: 2.0})

          :loop_state ->
            :erlang.term_to_binary(%{
              saved
              | loop_state: {:tools, [%{id: "invented", name: "propose", arguments: %{}}]}
            })

          :corrupt ->
            <<0>>

          :missing_allowance ->
            :erlang.term_to_binary(Map.delete(saved, :remaining_ms))

          _ ->
            :erlang.term_to_binary(saved)
        end

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE knotra_executions SET checkpoint = ? WHERE id = ?",
        [{:blob, bytes}, id],
        log: false
      )

      assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
               Knotra.recover(__MODULE__, id, definition, F.scope())

      assert {:ok, %{status: :blocked, error: :incompatible_checkpoint}} =
               Knotra.snapshot(__MODULE__, id, F.scope())
    end

    assert F.Ledger.entries() == []
  end

  test "resumed attempt and step limits prevent excess model and tool work" do
    cases = [
      {:retries_exhausted, [max_retries: 1, max_turns: 8], 1},
      {:turn_limit, [max_retries: 2, max_turns: 3], 1},
      {:tool_limit, [max_retries: 2, max_tool_calls: 1], 2},
      {:step_limit, [max_retries: 2, max_steps: 3], 2}
    ]

    for {reason, limits, phase_one_attempts} <- cases do
      retries = start_supervised!({Agent, fn -> %{0 => 1, 1 => 1} end}, id: make_ref())

      definition = %{
        F.definition(owner: self())
        | model: {F.RepeatingModel, owner: self(), retries: retries}
      }

      {:ok, id} =
        Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "limit-#{reason}", limits)

      assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000
      stop_supervised(__MODULE__)
      start_instance()

      answer = %{
        request_id: approval.id,
        version: approval.version,
        name: approval.name,
        arguments: approval.arguments,
        decision: :approve
      }

      assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

      assert_receive {:knotra, %{id: ^id, status: :failed, error: ^reason, counts: %{tools: 1}}},
                     2_000

      assert {:ok, %{status: :failed}} =
               Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

      assert {:ok, %{status: :failed}} = Knotra.recover(__MODULE__, id, definition, F.scope())
      assert_receive {:repeated_model_attempt, 0}
      assert_receive {:repeated_model_attempt, 0}
      for _ <- 1..phase_one_attempts, do: assert_receive({:repeated_model_attempt, 1})
      refute_receive {:repeated_model_attempt, _}
    end

    assert length(F.Ledger.operation_ids()) == 4
  end

  test "a later pending approval can be cancelled without erasing a previous effect" do
    definition = %{F.definition(owner: self()) | model: {F.RepeatingModel, owner: self()}}
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "second-cancel")
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: first}}, 2_000

    answer = %{
      request_id: first.id,
      version: first.version,
      name: first.name,
      arguments: first.arguments,
      decision: :approve
    }

    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: second}}, 2_000
    assert first.id != second.id

    assert {:ok, %{status: :waiting, approval: %{id: second_id}}} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert second_id == second.id

    assert {:ok, %{status: :cancelled, counts: %{tools: 1}}} =
             Knotra.cancel(__MODULE__, id, F.scope())

    assert {:ok, %{events: events}} = Knotra.snapshot(__MODULE__, id, F.scope())
    [%{data: %{operation_id: operation_id}}] = Enum.filter(events, &(&1.type == :tool_result))
    assert F.Ledger.operation_ids() == [[operation_id]]
  end

  test "an exhausted frozen active allowance cannot start a tool after human waiting" do
    {id, definition, answer} = pending_answer("frozen-budget")
    {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())
    assert saved.active_deadline_at == nil
    bytes = :erlang.term_to_binary(%{saved | remaining_ms: 0})

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE knotra_executions SET checkpoint = ? WHERE id = ?",
      [{:blob, bytes}, id],
      log: false
    )

    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert_receive {:knotra,
                    %{id: ^id, status: :failed, error: :deadline_exceeded, counts: %{tools: 0}}},
                   2_000

    assert F.Ledger.entries() == []
  end

  test "checkpoints exclude authority and private provider options and recovery checks fresh authority" do
    permission = start_supervised!({Agent, fn -> true end})
    {module, opts} = F.provider_definition(self()).model
    opts = Keyword.put(opts, :private_option, "PRIVATE_OPTION_CANARY")
    opts = Keyword.update!(opts, :options, &Keyword.put(&1, :api_key, "CREDENTIAL_CANARY"))
    definition = %{F.provider_definition(self()) | model: {module, opts}}

    context =
      Map.merge(F.scope(), %{
        permission: permission,
        authorization: fn -> true end,
        credential: "HOST_AUTH_CANARY",
        handle: self(),
        reference: make_ref()
      })

    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", context, "canaries")
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 5_000
    {:ok, saved} = Knotra.checkpoint(__MODULE__, id, F.scope())
    bytes = :erlang.term_to_binary(saved)

    for canary <- ["PRIVATE_OPTION_CANARY", "CREDENTIAL_CANARY", "HOST_AUTH_CANARY"],
        do: refute(bytes =~ canary)

    assert Enum.sort(Map.keys(saved)) ==
             Enum.sort([
               :format,
               :input,
               :response_timeout,
               :loop_state,
               :exchanges,
               :last,
               :counts,
               :limits,
               :stage,
               :remaining_ms,
               :active_deadline_at,
               :approval
             ])

    stop_supervised(__MODULE__)
    start_instance()
    Agent.update(permission, fn _ -> false end)

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :approve
    }

    assert {:ok, _} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :permission, permission),
               answer
             )

    assert_receive {:knotra, %{id: ^id, status: :failed, error: :forbidden}}, 2_000
    assert F.Ledger.entries() == []
  end

  test "blocked work continues to occupy the configured outstanding bound" do
    stop_supervised(__MODULE__)
    start_instance(max_pending: 1)
    definition = F.definition(owner: self(), continuation: self())
    {:ok, id} = Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "blocked-quota")
    assert_receive {:knotra, %{id: ^id, status: :blocked}}, 2_000

    assert {:error, :pending_limit} =
             Knotra.submit(
               __MODULE__,
               F.definition(owner: self()),
               "Propose",
               F.scope(),
               "new-quota"
             )

    assert F.Ledger.entries() == []
  end

  test "an approved capacity-waiting decision can be cancelled before admission" do
    {id, definition, answer} = pending_answer("ready-cancel")
    assert_receive {:model_called, _}

    {:ok, _} =
      Knotra.submit(
        __MODULE__,
        F.definition(owner: self(), gated: true),
        "Hold",
        F.scope(),
        "ready-blocker"
      )

    assert_receive {:model_called, _}, 2_000
    assert {:ok, %{status: :ready}} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert {:ok, %{status: :cancelled}} = Knotra.cancel(__MODULE__, id, F.scope())
    stop_supervised(__MODULE__)
    start_instance()
    assert {:ok, %{status: :cancelled}} = Knotra.recover(__MODULE__, id, definition, F.scope())

    assert {:error, :execution_cancelled} =
             Knotra.answer(__MODULE__, id, definition, F.scope(), answer)

    assert F.Ledger.entries() == []
  end

  test "actual active time spent before waiting is not replenished by restoration" do
    definition = F.definition(owner: self(), gated: true)

    {:ok, id} =
      Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "spent-time", timeout: 5_000)

    assert_receive {:model_called, model_task}, 2_000
    Process.send_after(model_task, :continue, 50)
    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000
    {:ok, before} = Knotra.checkpoint(__MODULE__, id, F.scope())
    assert before.remaining_ms <= 4_960
    assert before.active_deadline_at == nil
    stop_supervised(__MODULE__)
    start_instance()

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :approve
    }

    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, F.scope(), answer)
    assert_receive {:model_resumed, _}, 2_000
    assert_receive {:knotra, %{id: ^id, status: :completed}}, 2_000
    {:ok, after_work} = Knotra.checkpoint(__MODULE__, id, F.scope())
    assert after_work.remaining_ms <= before.remaining_ms
    assert F.Ledger.entries() == [["unexpected effect"]]
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

  defp uncertain_effect(key, opts, tool \\ F.IdempotentTool) do
    {id, definition, answer} = pending_answer(key, opts, tool)

    assert {:ok, _} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               Map.put(F.scope(), :effect_reply, {:retry, :temporarily_unavailable}),
               answer
             )

    assert_receive {:knotra,
                    %{
                      id: ^id,
                      status: :blocked,
                      error: :uncertain_effect,
                      approval: %{operation: %{id: operation_id}}
                    }},
                   2_000

    {id, definition, answer, operation_id}
  end

  defp pending_answer(key, opts \\ [], tool \\ F.Tool) do
    definition = %{F.definition(owner: self()) | tools: [tool]}
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

  test "a caller killed before acceptance cannot acknowledge work or start a model" do
    owner = self()

    definition = F.definition(owner: owner)

    {caller, monitor} =
      spawn_monitor(fn ->
        result =
          Knotra.submit(
            __MODULE__,
            definition,
            "Propose",
            Map.put(F.scope(), :before_acceptance, owner),
            "before-acceptance"
          )

        send(owner, {:unexpected_ack, result})
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:before_acceptance, ^caller}, 2_000
    refute_receive {:model_called, _}
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    refute_receive {:unexpected_ack, _}

    assert {:ok, id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "before-acceptance")

    assert_receive {:knotra, %{id: ^id, status: :waiting}}, 2_000

    assert {:ok, ^id} =
             Knotra.submit(__MODULE__, definition, "Propose", F.scope(), "before-acceptance")

    assert F.Ledger.entries() == []
  end

  test "durable malformed tool failures exclude credential and private-state canaries" do
    definition = F.definition(owner: self(), private_option: "DURABLE_PRIVATE_CANARY")

    context =
      Map.merge(F.scope(), %{
        credential: "DURABLE_AUTH_CANARY",
        effect_reply: {:error, "DURABLE_FAILURE_CANARY"}
      })

    assert {:ok, id} =
             Knotra.submit(__MODULE__, definition, "Propose", context, "durable-failure-canaries")

    assert_receive {:knotra, %{id: ^id, status: :waiting, approval: approval}}, 2_000

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :approve
    }

    assert {:ok, _} = Knotra.answer(__MODULE__, id, definition, context, answer)
    assert_receive {:knotra, %{id: ^id, status: :blocked, error: :uncertain_effect}}, 2_000
    assert {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
    assert {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
    bytes = :erlang.term_to_binary({snapshot, checkpoint})

    for canary <- ["DURABLE_PRIVATE_CANARY", "DURABLE_AUTH_CANARY", "DURABLE_FAILURE_CANARY"],
        do: refute(bytes =~ canary)

    assert snapshot.approval.operation.status == :dispatching
    assert snapshot.approval.operation.result == nil
    assert F.Ledger.operation_ids() == [[snapshot.approval.operation.id]]
  end

  test "trusted responder identity survives decisions, duplicate answers and storage reconnect",
       %{path: path} do
    for decision <- [:approve, :reject] do
      {id, definition, answer} = pending_answer("audit-#{decision}")
      principal = "trusted-#{decision}"

      context =
        Map.merge(F.scope(), %{
          responder_id: principal,
          credential: "AUDIT_AUTH_CANARY",
          principal: %{name: "CHANNEL_ACTOR_CANARY", credential: "AUDIT_AUTH_CANARY"},
          authorization: fn -> :ok end
        })

      answer = %{answer | decision: decision}

      assert {:ok, %{approval: %{responder_id: ^principal}}} =
               Knotra.answer(__MODULE__, id, definition, context, answer)

      status = if decision == :approve, do: :completed, else: :rejected

      if decision == :approve do
        assert_receive {:knotra, %{id: ^id, status: :completed}}, 2_000
      end

      {:ok, before} = Knotra.snapshot(__MODULE__, id, F.scope())
      stop_supervised(__MODULE__)
      stop_supervised(Repo)
      start_supervised!({Repo, F.repo_options(path)})
      start_instance()

      assert {:ok, ^before} =
               Knotra.recover(
                 __MODULE__,
                 id,
                 definition,
                 Map.put(F.scope(), :responder_id, "recoverer")
               )

      assert {:ok, %{status: ^status, approval: %{responder_id: ^principal}}} =
               Knotra.answer(
                 __MODULE__,
                 id,
                 definition,
                 Map.put(F.scope(), :responder_id, "different-duplicate"),
                 answer
               )

      {:ok, snapshot} = Knotra.snapshot(__MODULE__, id, F.scope())
      {:ok, checkpoint} = Knotra.checkpoint(__MODULE__, id, F.scope())
      assert checkpoint.approval.responder_id == principal

      assert [%{responder_id: ^principal, data: ^answer}] =
               Enum.filter(snapshot.events, &(&1.type == :approval_answered))

      bytes = :erlang.term_to_binary({snapshot, checkpoint})
      for canary <- ["AUDIT_AUTH_CANARY", "CHANNEL_ACTOR_CANARY"], do: refute(bytes =~ canary)
    end

    assert length(F.Ledger.entries()) == 1
  end

  test "answer refuses missing or malformed host responder identities and client actor injection" do
    {id, definition, answer} = pending_answer("audit-boundaries")
    answer = %{answer | decision: :reject}
    {:ok, before} = Knotra.snapshot(__MODULE__, id, F.scope())
    legacy = Map.delete(F.scope(), :responder_id)
    assert {:error, :forbidden} = Knotra.answer(__MODULE__, id, definition, legacy, answer)

    for bad <- [
          nil,
          "",
          :actor,
          %{token: "PRIVATE_ACTOR_CANARY"},
          self(),
          fn -> :ok end,
          String.duplicate("x", 257)
        ] do
      assert {:error, :forbidden} =
               Knotra.answer(
                 __MODULE__,
                 id,
                 definition,
                 Map.put(F.scope(), :responder_id, bad),
                 answer
               )
    end

    assert {:error, :invalid_answer} =
             Knotra.answer(
               __MODULE__,
               id,
               definition,
               F.scope(),
               Map.put(answer, :responder_id, "client-actor")
             )

    assert {:ok, ^before} = Knotra.snapshot(__MODULE__, id, legacy)
    assert F.Ledger.entries() == []
  end
end
