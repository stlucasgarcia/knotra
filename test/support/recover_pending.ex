Code.require_file("durable_fixtures.ex", __DIR__)
alias Knotra.DurableFixtures, as: F
[path, id] = System.argv()
{:ok, _} = Application.ensure_all_started(:knotra)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, repo} = F.Repo.start_link(F.repo_options(path))

{:ok, runtime} =
  Knotra.start_link(
    name: FreshRuntime,
    durable: [repo: F.Repo, access: F.Access]
  )

try do
  {:ok, %{status: :waiting, approval: %{arguments: %{"amount" => 12}}}} =
    Knotra.recover(FreshRuntime, id, F.definition(owner: self()), F.scope())

  {:ok,
   %{exchanges: [%{reply: %Knotra.Reply{continuation: %ReqLLM.Message{}}}], counts: %{turns: 1}}} =
    Knotra.checkpoint(FreshRuntime, id, F.scope())

  receive do
    {:model_called, _} -> raise "recovery repeated the model"
  after
    0 -> :ok
  end

  IO.puts("RECOVERED_WITHOUT_REPLAY")
after
  Supervisor.stop(runtime)
  Supervisor.stop(repo)
end
