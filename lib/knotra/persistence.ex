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

    def accept(repo, attributes, max_pending \\ :infinity) do
      protect(fn ->
        insert_accepted(repo, attributes, max_pending)

        row =
          repo.get_by(
            Record,
            [tenant: attributes.tenant, submission_key: attributes.submission_key],
            log: false
          )

        cond do
          row == nil -> {:error, :pending_limit}
          row.request_hash == attributes.request_hash -> {:ok, row}
          true -> {:error, :submission_conflict}
        end
      end)
    end

    defp insert_accepted(repo, attributes, :infinity) do
      repo.insert!(struct!(Record, attributes),
        on_conflict: :nothing,
        conflict_target: [:tenant, :submission_key],
        log: false
      )
    end

    defp insert_accepted(repo, attributes, limit) when is_integer(limit) and limit > 0 do
      # ponytail: COUNT scans retained history; use a transactional admission counter if costly.
      outstanding =
        from(r in Record,
          where: r.status not in ["completed", "failed", "cancelled", "expired", "rejected"],
          select: %{count: count(r.id)}
        )

      # A single SQLite writer statement makes capacity checking and insertion
      # atomic. Blocked/reconciliation work still owns capacity; history does not.
      query =
        from(c in subquery(outstanding),
          where: c.count < ^limit,
          select: %{
            id: ^attributes.id,
            tenant: ^attributes.tenant,
            submission_key: ^attributes.submission_key,
            request_hash: type(^attributes.request_hash, :binary),
            composition: type(^attributes.composition, :binary),
            checkpoint: type(^attributes.checkpoint, :binary),
            snapshot: type(^attributes.snapshot, :binary)
          }
        )

      repo.insert_all(Record, query,
        on_conflict: :nothing,
        conflict_target: [:tenant, :submission_key],
        log: false
      )
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
          case expires_at do
            nil ->
              query

            {:expired, deadline} ->
              where(query, fragment("(julianday('now') - 2440587.5) * 86400000 >= ?", ^deadline))

            deadline when is_integer(deadline) ->
              where(query, fragment("(julianday('now') - 2440587.5) * 86400000 < ?", ^deadline))
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
