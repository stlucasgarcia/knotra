defmodule Mix.Tasks.KnotraBots.Migrate do
  @shortdoc "Applies Knotra's persistence migration to the example database"
  @moduledoc """
  Applies `Knotra.Persistence.Migration` through the example host's own migration
  workflow, as [ADR 0001](../../../docs/adr/0001-ecto-sqlite-persistence.md) requires.

      mix knotra_bots.migrate

  Run this (or `mix setup`) before `mix phx.server`. It starts only the Repo, so it
  works while the server is already running.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("loadpaths")
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _pid} = KnotraBots.Repo.start_link()
    KnotraBots.migrate!()
    Supervisor.stop(KnotraBots.Repo)
  end
end
