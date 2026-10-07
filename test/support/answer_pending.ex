Code.require_file("durable_fixtures.ex", __DIR__)
alias Knotra.DurableFixtures, as: F
[path, ledger_path, id | mode] = System.argv()
retry = mode == ["retry"]
{:ok, _} = Application.ensure_all_started(:knotra)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, repo} = F.Repo.start_link(F.repo_options(path))
{:ok, ledger} = F.Ledger.start_link(Keyword.put(F.repo_options(ledger_path), :pool_size, 1))

{:ok, runtime} =
  Knotra.start_link(
    name: FreshAnswer,
    durable: [repo: F.Repo, access: F.Access, demo_tools: [F.Tool, F.IdempotentTool]]
  )

try do
  definition =
    if retry,
      do: %{F.definition(owner: self()) | tools: [F.IdempotentTool]},
      else: F.provider_definition(self())

  {:ok, record} = Knotra.recover(FreshAnswer, id, definition, F.scope())

  unless retry do
    %{status: :waiting, approval: approval} = record

    answer = %{
      request_id: approval.id,
      version: approval.version,
      name: approval.name,
      arguments: approval.arguments,
      decision: :approve
    }

    {:ok, _} = Knotra.answer(FreshAnswer, id, definition, F.scope(), answer)
  end

  tools = if retry, do: 2, else: 1
  retries = if retry, do: 1, else: 0

  receive do
    {:knotra,
     %{
       id: ^id,
       status: :completed,
       output: "Completed: fake effect",
       counts: %{turns: 2, tools: ^tools, retries: ^retries},
       approval: %{
         responder_id: "fake-approver",
         operation: %{id: operation_id, result: "fake effect"}
       }
     }} ->
      [[^operation_id]] = F.Ledger.operation_ids()
  after
    10_000 ->
      raise "approval continuation did not complete: #{inspect(Knotra.snapshot(FreshAnswer, id, F.scope()))}"
  end

  unless retry do
    {:ok,
     %{
       exchanges: [
         %{reply: %{continuation: %ReqLLM.Message{metadata: %{response_id: "resp_checkpoint"}}}},
         _
       ]
     }} =
      Knotra.checkpoint(FreshAnswer, id, F.scope())
  end

  IO.puts("ANSWERED_AFTER_FRESH_BEAM")
after
  Supervisor.stop(runtime)
  Supervisor.stop(repo)
  Supervisor.stop(ledger)
end
