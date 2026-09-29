# Durable submission and pending approvals

Implemented scope: [issue #4](https://github.com/stlucasgarcia/knotra/issues/4), using the [SQLite-first Ecto decision](adr/0001-ecto-sqlite-persistence.md). This is an opt-in path alongside the existing non-durable `Knotra.start/5`, not production ownership/recovery certification.

**Works:** commit-before-acknowledgment acceptance, tenant-scoped submission deduplication, a model-proposed operation, validated/authorized pending approval, stable inspection after restart, and private versioned checkpoints. Pending/terminal durable workers exit rather than retaining process handles.

**Does not work yet:** answering, approval edits, operation execution, cancellation by durable identity, active expiry processing, automatic background draining, autonomous retry of interrupted model work, PostgreSQL certification, or distributed ownership. There is intentionally no approval-answer function in this slice. An expiry timestamp is recorded, not an implemented expiry scheduler.

## Host setup

The host owns its Ecto Repo, connections, database file, supervision and migration lifecycle. Knotra does not start or migrate a Repo. The SQLite adapter is test-only in this library; a SQLite host adds its own runtime `ecto_sqlite3` dependency. Ecto and Ecto SQL are optional for non-durable users.

Apply `Knotra.Persistence.Migration` explicitly through the host's migration workflow. For example, a host migration can delegate its `change/0` to that module; give it a unique host migration version. The initial table is `knotra_executions`, including a database-enforced unique tenant/submission-key index. Neither model/plugin options nor host authorization context are stored in that table. Inputs, model messages and proposed arguments can still be sensitive: restrict table/checkpoint access and retention accordingly.

Configure the instance only after the host Repo is available:

```elixir
{Knotra,
 name: MyApp.Agents,
 max_executions: 20,
 durable: [repo: MyApp.Repo, access: MyApp.AgentAccess]}
```

`MyApp.AgentAccess` implements `Knotra.Access.authorize/3`. It receives the action (`:submit`, `:inspect`, `:checkpoint`, or `:recover`), execution ID (nil for submission), and a host-supplied context. Return `{:ok, tenant_id}` only after checking permission, deriving tenant identity from trusted host data; otherwise return an error. The context is never constructed from model arguments. Authorize `:checkpoint` separately: it exposes private continuation data, unlike public inspection.

Keep the existing tool contract: JSON schema is model metadata, while `validate/1` validates arguments and `authorize/2` enforces host business scope. In durable mode, `read_only: false` tools may describe a consequential proposal. **No tool's `call/2` runs on this path**, including read-only tools. The ordinary `start/5` path still rejects write-tool definitions.

## Public interface

```elixir
{:ok, execution_id} =
  Knotra.submit(MyApp.Agents, definition, "Propose an operation", host_context,
    "host-request-key", response_timeout: 86_400_000)

{:ok, record} = Knotra.snapshot(MyApp.Agents, execution_id, host_context)
{:ok, record} = Knotra.recover(MyApp.Agents, execution_id, definition, fresh_host_context)

# Only if separately authorized; not a frontend payload:
{:ok, checkpoint} = Knotra.checkpoint(MyApp.Agents, execution_id, privileged_context)
```

`submit/6` accepts the existing execution limit options plus a positive `response_timeout` in milliseconds (default one day). It returns a stable random ID after acceptance is committed, not a worker PID or a promise that a model has already finished. A model/tool failure after acceptance remains an inspectable outcome, not a retroactive acceptance failure.

Matching tenant/key submissions reuse the original ID. Matching includes input, normalized limits, response timeout and composition fingerprint. Conflicting reuse returns `:submission_conflict`. Identical keys in different tenants do not identify the same execution. A commit failure returns `:persistence_unavailable`; retrying after a lost acknowledgment resolves through the same tenant/key.

A configured active-slot limit also covers durable workers. If a slot is unavailable, work remains `:accepted`; this slice has no background queue drainer. The host explicitly calls `recover/4` (or resubmits the same request) when capacity is available. There is not yet a separate pending-record quota or retention service; the host must bound submissions and storage. Later limit/admission work belongs to issue #7.

Public records contain `:accepted`, `:running`, `:waiting`, `:failed` or `:blocked` status, ordered events, consumed counts and an optional approval. The approval includes stable identity, request version, originating call ID, operation name, validated arguments, `:pending` disposition and wall-clock expiry. Argument validation and host tool authorization run before the request is published. Expiry starts when the pending request is prepared. An observer receives public snapshots only after the corresponding database update; missing/failed delivery is not proof that a committed request was lost. Re-query the record. Terminal observer callbacks remain bounded, and the worker exits after delivery or timeout.

## Safe points and recovery limits

This slice supports the default loop and default tool runtime with exactly one model-proposed tool call. Unsupported compositions are rejected before acceptance; malformed model replies or invalid/unauthorized arguments fail without an approval or effect.

A durable model explicitly opts in with optional `Knotra.Model.checkpoint_version/0`, returning a positive integer. The ReqLLM adapter provides version 1. Compatible replies must contain only bounded inert data: scalars, proper lists, tuples/maps and the supported Knotra/ReqLLM message/tool-call structs. Functions, PIDs, ports, references, unsupported structs and oversized records are rejected. There is no arbitrary plugin-state serializer.

The checkpoint contains a format version, accepted input, loop state, full model exchanges/continuations, pending operation, counts, limits and remaining active allowance; it is separate from the public snapshot. It deliberately excludes credentials, configuration options, live handles and host authorization. Serialization is size-bounded Erlang external-term data, decoded with `:safe` and validated again; it is not an interoperable wire format or a place to accept uploaded terms. Storage remains host-trusted. Model-generated text/data may still contain sensitive content and is not automatically scrubbed.

A fingerprint pins definition version, loop/model/tool-runtime identities, tool metadata and model checkpoint version. **The host must change the definition version whenever behavior, prompts or semantic model options change.** Private options are neither stored nor hashed; unchanged module names alone cannot detect changed code. Incompatible restoration is visibly blocked. Encoding an unsupported continuation blocks the execution while retaining its last valid checkpoint.

Updates use a conditional revision, so stale workers cannot overwrite newer durable state. `recover/4` can start still-accepted work using freshly supplied definition/context, or return a compatible pending approval without invoking the model again. A model call interrupted while marked running, with no live worker in this instance, becomes `:blocked` / `:interrupted`; it is **not** silently retried. Pending approval continuation/answering is issue #5. This API is not a cross-instance/node takeover protocol: use one owning Knotra instance for a given execution until ownership support exists.

## Verification and SQLite test lifecycle

Run `mix test test/durable_test.exs --warnings-as-errors` for the public-interface persistence scenarios. Run the existing suite separately or the full suite for regressions. No provider credentials or production effects are needed.

The test host uses committed, file-backed databases in private directories under ignored `_build/persistence-tests/`. It initializes migrations with one connection, then restarts with two connections, avoiding concurrent initial journal setup. Effective WAL mode, FULL synchronization and foreign keys are asserted. Exqlite 0.41 uses a cancellation-aware busy handler: the configured timeout is 5 seconds, while `PRAGMA busy_timeout` reports zero. Do not replace that handler with a PRAGMA just to make a configuration assertion pass. Concurrent submissions exercise independent writers; SQLite serializes writes, not business effects.

An independent ledger database observes fake effects and survives execution/runtime restarts. Tests stop runtime and Repo, reconnect to the same execution file, and separately inspect it from a fresh BEAM. Database triggers inject acceptance and pending-commit failures. Other scenarios cover lost-notification recovery, duplicate/conflicting submissions, tenant/permission checks, incompatible versions, unsupported continuations, active capacity release and interrupted model calls. Tests assert through public Knotra calls; direct SQL is confined to fixture configuration and storage-failure injection. After all connections stop, each fixture deletes only its own directory and sidecars. A rollback-only SQL Sandbox is not used as restart evidence.

These checks prove the bounded SQLite slice, not power-loss durability, PostgreSQL parity, safe general effect retries, distributed leases or exactly-once execution. The existing architecture's DeepSeek-first comparison still applies: an inbox or snapshot is not a durable pending approval; LangGraph-style node replay can repeat effects. This slice deliberately stops instead of replaying an uncertain model step. No alternate harness dependency was adopted.
