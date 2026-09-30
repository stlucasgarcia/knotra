Code.require_file("durable_fixtures.ex", __DIR__)
alias Knotra.DurableFixtures, as: F
[path, id | mode] = System.argv()
{:ok, _} = Application.ensure_all_started(:knotra)
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, repo} = F.Repo.start_link(F.repo_options(path))

{:ok, runtime} =
  Knotra.start_link(
    name: FreshRuntime,
    durable: [repo: F.Repo, access: F.Access]
  )

try do
  definition =
    if mode == ["provider"], do: F.provider_definition(self()), else: F.definition(owner: self())

  recovered = Knotra.recover(FreshRuntime, id, definition, F.scope())

  case mode do
    ["blocked"] ->
      {:ok, %{status: :blocked, error: :unsupported_checkpoint}} = recovered

    ["cancelled"] ->
      {:ok, %{status: :cancelled, error: :cancelled}} = recovered

    ["expired"] ->
      {:ok, %{status: :expired, error: :approval_expired}} = recovered

      {:ok, %{approval: %{disposition: :expired}}} =
        Knotra.checkpoint(FreshRuntime, id, F.scope())

    _ ->
      {:ok, %{status: :waiting, approval: %{arguments: %{"amount" => 12}}}} = recovered

      {:ok,
       %{
         exchanges: [%{reply: %Knotra.Reply{continuation: %ReqLLM.Message{}}}],
         counts: %{turns: 1}
       }} =
        Knotra.checkpoint(FreshRuntime, id, F.scope())
  end

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
