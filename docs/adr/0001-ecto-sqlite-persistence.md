# Ecto persistence: SQLite first, PostgreSQL later

Status: accepted for [issue #3](https://github.com/stlucasgarcia/knotra/issues/3); implementation starts in [issue #4](https://github.com/stlucasgarcia/knotra/issues/4).

The owner approved starting with SQLite because it is easier to test locally, using Ecto so a PostgreSQL integration can follow later. Use file-backed SQLite for the first restart-safe approval slice, with a host-owned Ecto Repo; this replaces the earlier PostgreSQL-first recommendation without claiming adapter parity or implementing persistence now.

## Authorization and dependency placement

This decision supersedes the **ReqLLM-only restriction only for the Ecto/SQLite persistence integration** in the [milestone-1 design](../design.md). That document remains accurate about the original prototype; any older PostgreSQL-first recommendation or unresolved persistence-authorization wording must be read subject to this ADR. Other direct dependencies and other harnesses remain outside the authorization.

When the implementation needs them:

- Knotra may declare `ecto` and `ecto_sql` as optional runtime dependencies for its opt-in persistence integration. Applications using only the current non-durable execution path must not need a configured Repo or database.
- Knotra may declare `ecto_sqlite3` as a test-only dependency for its SQLite integration test host. An embedding application choosing SQLite supplies `ecto_sqlite3` as its own runtime dependency.
- Normal transitive dependencies, including the adapter's `exqlite` driver, are permitted. Do not add a custom SQLite driver or a separate raw-driver execution path.
- Select mutually compatible versions against the project's Elixir/OTP versions and lock them in the implementing change. No dependency or lockfile change is needed to complete this decision ticket.
- PostgreSQL is the next intended backend, not a requirement of the SQLite slice. Do not add Postgrex, a PostgreSQL service, or a PostgreSQL adapter implementation now; select those versions and integration details in a later scoped ticket.

Approval evidence: the owner's implementation request for issue #3 states, “let's start with sqlite and then expand to postgres later on as we are going to use Ecto anyways, sqlite is easier for testing.” This ticket records that authorization; it is not inferred from a triage label.

## Ownership

- The **host application** owns and supervises the Repo, connection pool, database location, credentials where applicable, backups and deployment lifecycle. Knotra receives the configured Repo rather than starting an implicit global Repo.
- Knotra's persistence integration owns its schema and versioned migration definitions. The host explicitly applies those migrations through its normal Ecto migration workflow; do not migrate an embedding application's database automatically on startup.
- The repository's test host plays that role in integration tests. The implementer of issue #4 supplies the test Repo, migrations and repeatable fixtures; no separate database server or human-managed credentials are needed for SQLite.
- No schema, new public runtime interface or migration is introduced by issue #3. Acceptance remains through Knotra's public execution interface, as agreed in the parent spec.

## Real-storage test environment and lifecycle

Use the development machine or CI runner's writable **local filesystem**, with a private, uniquely named directory per test scenario under `_build/persistence-tests/`. This path is ignored by Git. Do not use `:memory:`, a shared network filesystem, or a database already used by a host application. Do not assume an operating-system temporary directory is disk-backed.

The test host introduced in issue #4 must implement this setup/cleanup procedure:

1. Create an owned directory with restrictive permissions and unique names for the execution database and a **separate fake-effect ledger database**. Keep the ledger outside the execution's transactions and recovery lifecycle; it represents an external effect, not an atomic part of the checkpoint.
2. Start the Ecto test Repo with absolute file paths and apply the versioned migrations explicitly. Configure WAL journal mode, `synchronous: :full`, foreign keys enabled, a bounded busy timeout (5 seconds initially), and at least two connections for concurrent-answer/conditional-transition scenarios. Verify effective settings rather than relying on adapter defaults.
3. Use real committed transactions for durability tests, not a rollback-only SQL Sandbox owner shared across workers. Keep test scenarios isolated by database directory; contenders within one scenario must use independent connections to the same database.
4. Submit and inspect through the public Knotra interface. Stop or kill the execution/runtime and close its Repo, then reconnect to the **same files** without deleting data or rerunning a destructive setup. Include a fresh BEAM invocation in the restart suite so process-local state cannot satisfy the assertion. The ledger and test-directory owner survive the restart.
5. Synchronize contenders/failure points explicitly. SQLite serializes writers: a busy timeout is an explicit failed attempt, not a successful state change. Assert affected-row/revision outcomes, not timing or successful serialization through a single shared connection. Do not rerun a business effect simply because a database write was busy.
6. After all assertions, stop workers and close every execution/ledger connection. Remove only the directory created by that scenario, including SQLite `-wal` and `-shm` sidecars; never delete files belonging to a live Repo. Cleanup on failure must be equally scoped.

Environment availability was checked for this decision: the project's `_build` directory is on a writable local Btrfs filesystem; C compiler, make, Python, Elixir 1.20.4 and OTP 29 are available. A temporary Python/SQLite 3.53.1 probe committed a file-backed WAL record, exited the writer process without normal connection cleanup, reconnected, and raced two independent conditional updates: exactly one changed the revision. Its private directory and sidecars were removed afterward.

**That probe establishes local environment availability only.** Ecto/ecto_sqlite3 are not installed by this ticket, and the probe does not certify the Exqlite SQLite version, adapter behavior, Knotra durability, power-loss durability or CI compatibility. Installing the authorized dependencies and building/running the Ecto test host belongs to issue #4. If a CI runner lacks a writable local filesystem or native-driver support, that runner's execution is blocked; the implementer must provide the documented prerequisites, not silently substitute memory storage. No external infrastructure owner is outstanding for local SQLite testing.

## Minimum persistence acceptance contract

The downstream implementation and its real-storage tests must prove:

- Acknowledge durable acceptance only after commit. A lost acknowledgment can be resolved by tenant-scoped submission identity; a failed commit cannot be presented as accepted work.
- Enforce tenant-scoped request uniqueness in the database. Matching resubmissions retrieve the accepted execution; conflicting payload reuse is rejected, and another tenant cannot retrieve it using the same key.
- Use atomic conditional transitions for execution/request revisions, decisions and dispatch admission. A stale writer must not overwrite newer state; use database constraints/affected-row outcomes, not only process-local checks.
- Retrieve the same execution and pending approval after runtime termination and reconnect. Persist checkpoints separately from public snapshots, preserve compatible continuation and consumed budgets, and rehydrate current host authorization rather than credentials or authority captured in state.
- Keep the fake-effect ledger independent so crash-after-effect/before-result tests can detect duplicates. No local transaction or approval implies exactly-once external effects.

The temporary environment probe is not a substitute for these public-interface tests. The baseline offline suite covers the existing non-durable runtime only. Full multi-replica ownership, distributed failover and production readiness remain deferred.

## PostgreSQL expansion and sources

Prefer Ecto-supported portable data and conditional-update/constraint semantics where sufficient. Isolate adapter-specific behavior where it is actually required; do not build a speculative universal database layer. SQLite's writer serialization is not proof of PostgreSQL concurrent transaction behavior. Before claiming PostgreSQL support, run the same public-interface contract against PostgreSQL and add its concurrency/ownership tests; Ecto alone does not make SQL, migrations, or isolation semantics identical. Existing SQLite data migration is a separate scope, not an automatic adapter switch.

Reference documentation inspected for this decision (not installed package versions): [Ecto SQLite3 0.25.0 adapter options](https://hexdocs.pm/ecto_sqlite3/0.25.0/Ecto.Adapters.SQLite3.html) and [Ecto SQL 3.14.0 Sandbox transaction behavior](https://hexdocs.pm/ecto_sql/3.14.0/Ecto.Adapters.SQL.Sandbox.html). In particular, the SQLite adapter defaults synchronous mode to `:normal`, so the restart test host explicitly requests `:full`; SQL Sandbox's rollback-based test isolation must not be confused with committed restart evidence.
