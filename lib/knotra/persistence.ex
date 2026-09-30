if Code.ensure_loaded?(Ecto.Schema) and Code.ensure_loaded?(Ecto.Migration) do
  defmodule Knotra.Persistence.Record do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :string, autogenerate: false}
    schema "knotra_executions" do
      field(:tenant, :string)
      field(:submission_key, :string)
      field(:request_hash, :binary)
      field(:composition, :binary)
      field(:revision, :integer, default: 0)
      field(:status, :string, default: "accepted")
      field(:checkpoint, :binary)
      field(:snapshot, :binary)
    end
  end

  defmodule Knotra.Persistence.Migration do
    @moduledoc "Host-applied initial migration. Never run automatically by Knotra."
    use Ecto.Migration

    def change do
      create table(:knotra_executions, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:tenant, :string, null: false)
        add(:submission_key, :string, null: false)
        add(:request_hash, :binary, null: false)
        add(:composition, :binary, null: false)
        add(:revision, :integer, null: false, default: 0)
        add(:status, :string, null: false, default: "accepted")
        add(:checkpoint, :binary, null: false)
        add(:snapshot, :binary, null: false)
      end

      create(unique_index(:knotra_executions, [:tenant, :submission_key]))
    end
  end

  defmodule Knotra.Persistence do
    @moduledoc false
    import Ecto.Query
    alias Knotra.Persistence.Record

    def accept(repo, attributes) do
      protect(fn ->
        repo.insert!(struct!(Record, attributes),
          on_conflict: :nothing,
          conflict_target: [:tenant, :submission_key],
          log: false
        )

        row =
          repo.get_by!(
            Record,
            [tenant: attributes.tenant, submission_key: attributes.submission_key],
            log: false
          )

        if row.request_hash == attributes.request_hash,
          do: {:ok, row},
          else: {:error, :submission_conflict}
      end)
    end

    def fetch(repo, tenant, id) do
      protect(fn ->
        case repo.get_by(Record, [tenant: tenant, id: id], log: false) do
          nil -> {:error, :not_found}
          row -> {:ok, row}
        end
      end)
    end

    def update(repo, row, changes, expires_at \\ nil) do
      protect(fn ->
        query =
          from(r in Record,
            where: r.id == ^row.id and r.tenant == ^row.tenant and r.revision == ^row.revision
          )

        # SQLite-certified deadline check at the conditional write, including
        # time spent queued for a writer. PostgreSQL certification remains deferred.
        query =
          if expires_at do
            where(query, fragment("(julianday('now') - 2440587.5) * 86400000 < ?", ^expires_at))
          else
            query
          end

        case repo.update_all(query, [set: changes ++ [revision: row.revision + 1]], log: false) do
          {1, _} -> {:ok, struct(row, changes ++ [revision: row.revision + 1])}
          {0, _} -> {:error, :stale_execution}
        end
      end)
    end

    defp protect(fun) do
      try do
        fun.()
      rescue
        _ -> {:error, :persistence_unavailable}
      catch
        :exit, _ -> {:error, :persistence_unavailable}
      end
    end
  end
end
