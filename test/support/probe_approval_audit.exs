# Public-interface self-check for the parent spec's responder-audit requirement.
# Run explicitly with MIX_ENV=test; the regression suite also covers this contract.
Code.require_file("durable_fixtures.ex", __DIR__)
alias Knotra.DurableFixtures, as: F

{:ok, _} = Application.ensure_all_started(:knotra)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
directory = Path.expand("_build/persistence-tests/audit-#{System.os_time()}")
File.mkdir_p!(directory)
File.chmod!(directory, 0o700)
{:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

missing =
  try do
    {:ok, _} =
      Supervisor.start_child(supervisor, {
        F.Ledger,
        F.repo_options(Path.join(directory, "ledger.sqlite3")) |> Keyword.put(:pool_size, 1)
      })

    F.Ledger.initialize()
    path = Path.join(directory, "execution.sqlite3")

    {:ok, _} =
      Supervisor.start_child(
        supervisor,
        {F.Repo, F.repo_options(path) |> Keyword.put(:pool_size, 1)}
      )

    Ecto.Migrator.up(F.Repo, 1, Knotra.Persistence.Migration, log: false)
    :ok = Supervisor.terminate_child(supervisor, F.Repo)
    :ok = Supervisor.delete_child(supervisor, F.Repo)
    {:ok, _} = Supervisor.start_child(supervisor, {F.Repo, F.repo_options(path)})

    # The fake host, not model/channel input, selects this authenticated principal.
    owner = self()
    principal = "audit-probe-approver"

    context = Map.merge(F.scope(), %{audit_probe: {owner, principal}, responder_id: principal})

    {:ok, _} =
      Supervisor.start_child(supervisor, {
        Knotra,
        name: Knotra.AuditProbe, durable: [repo: F.Repo, access: F.Access, demo_tools: [F.Tool]]
      })

    definition = F.definition(owner: owner)
    {:ok, id} = Knotra.submit(Knotra.AuditProbe, definition, "Propose", F.scope(), "audit-probe")

    approval =
      receive do
        {:knotra, %{id: ^id, status: :waiting, approval: approval}} -> approval
      after
        5_000 -> raise "pending approval not observed"
      end

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :reject
    }

    {:ok, %{status: :rejected}} =
      Knotra.answer(Knotra.AuditProbe, id, definition, context, answer)

    receive do
      {:authorized_as, ^principal} -> :ok
    after
      5_000 -> raise "host authorization not observed"
    end

    {:ok, snapshot} = Knotra.snapshot(Knotra.AuditProbe, id, F.scope())
    {:ok, checkpoint} = Knotra.checkpoint(Knotra.AuditProbe, id, F.scope())
    receipts = Enum.filter(snapshot.events, &(&1.type == :approval_answered))
    [] = F.Ledger.entries()

    present =
      snapshot.approval[:responder_id] == principal and
        checkpoint.approval[:responder_id] == principal and
        match?([%{responder_id: ^principal, data: %{decision: :reject}}], receipts)

    IO.puts("Authenticated responder recorded: #{present}; decision: rejected; effects: 0")
    not present
  after
    Supervisor.stop(supervisor)
    File.rm_rf!(directory)
  end

if missing,
  do: raise("UNIMPLEMENTED: decision records do not identify the authenticated responder")
