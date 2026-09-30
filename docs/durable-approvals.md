# Durable submission and pending approvals

Implemented scope: [issue #4](https://github.com/stlucasgarcia/knotra/issues/4), the constrained fake-operation demonstration in [issue #5](https://github.com/stlucasgarcia/knotra/issues/5), and waiting cancellation/expiry in [issue #6](https://github.com/stlucasgarcia/knotra/issues/6), using the [SQLite-first Ecto decision](adr/0001-ecto-sqlite-persistence.md). This is an opt-in path alongside the existing non-durable `Knotra.start/5`, not production ownership/recovery certification.

**Works:** commit-before-acknowledgment acceptance, tenant-scoped submission deduplication, a model-proposed operation, validated/authorized pending approval, approval/rejection by request identity and version, one explicitly allowlisted fake operation, restored model continuation, stable inspection after restart, durable pre-admission cancellation, persisted response expiry on access, and private versioned checkpoints. Pending/terminal durable workers exit rather than retaining process handles.

**Does not work yet:** production consequential operations, approval edits, additional operations in the same execution, cancellation of arbitrary active work by durable identity, background expiry sweeping, automatic background draining, autonomous retry of interrupted model work or uncertain effects, PostgreSQL certification, or distributed ownership. Answer admission checks expiry, including at the SQLite conditional write; there is no expiry scheduler.

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

`MyApp.AgentAccess` implements `Knotra.Access.authorize/3`. It receives the action (`:submit`, `:inspect`, `:checkpoint`, `:recover`, `:answer`, or `:cancel`), execution ID (nil for submission), and a host-supplied context. Return `{:ok, tenant_id}` only after checking permission, deriving tenant identity from trusted host data; otherwise return an error. The context is never constructed from model arguments. Authorize `:checkpoint` separately: it exposes private continuation data, unlike public inspection.

Keep the existing tool contract: JSON schema is model metadata, while `validate/1` validates arguments and `authorize/2` enforces host business scope. In durable mode, `read_only: false` tools may describe a consequential proposal. Submission alone never calls a tool. Answering can execute only a module explicitly listed in the instance's `durable: [demo_tools: [...]]` configuration (default `[]`), and only after an unchanged approval and fresh tool authorization. This allowlist is a trusted host opt-in for a fake demonstration, not a detector or sandbox for real side effects. Do not allowlist production operations. The ordinary `start/5` path still rejects write-tool definitions.

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

Public records contain `:accepted`, `:running`, `:waiting`, `:decided`, `:rejected`, `:cancelled`, `:expired`, `:completed`, `:failed` or `:blocked` status, ordered events, consumed counts and an optional approval. The approval includes stable identity, request version, originating call ID, operation name, validated arguments, `:pending` disposition and wall-clock expiry. Argument validation and host tool authorization run before the request is published. Expiry starts when the pending request is prepared. An observer receives public snapshots only after the corresponding database update; missing/failed delivery is not proof that a committed request was lost. Re-query the record. For worker-produced terminal records, a separately supervised notifier waits for the execution supervisor to release the worker's slot before invoking the observer. Its observer call is bounded to one second; a slow or failed observer cannot retain active execution capacity.

## Safe points and recovery limits

This slice supports the default loop and default tool runtime with exactly one model-proposed tool call, followed by a tool result and a final model reply with no further tool calls. Unsupported compositions are rejected before acceptance; malformed model replies or invalid/unauthorized arguments fail without an approval or effect.

A durable model explicitly opts in with optional `Knotra.Model.checkpoint_version/0`, returning a positive integer. The ReqLLM adapter provides version 1. Compatible replies must contain only bounded inert data: binaries/numbers, proper lists, tuples/maps, the fixed checkpoint atom vocabulary and supported Knotra/ReqLLM message/tool-call structs. Arbitrary metadata should use string keys/values. Atoms outside the literal vocabulary are rejected before publication—even if they exist in the writing VM—so fresh-VM safe decoding does not depend on that VM's atom history. Functions, PIDs, ports, references, unsupported structs and oversized records are rejected. There is no arbitrary plugin-state serializer.

The checkpoint contains a format version, accepted input, loop state, full model exchanges/continuations, pending operation, counts, limits and remaining active allowance; it is separate from the public snapshot. It deliberately excludes credentials, configuration options, live handles and host authorization. Serialization is size-bounded Erlang external-term data, decoded with `:safe` and validated again; it is not an interoperable wire format or a place to accept uploaded terms. Storage remains host-trusted. Model-generated text/data may still contain sensitive content and is not automatically scrubbed.

A fingerprint pins definition version, loop/model/tool-runtime identities, tool metadata and model checkpoint version. **The host must change the definition version whenever behavior, prompts or semantic model options change.** Private options are neither stored nor hashed; unchanged module names alone cannot detect changed code. Incompatible restoration is visibly blocked. Encoding an unsupported continuation blocks the execution while retaining its last valid checkpoint.

Updates use a conditional revision, so stale workers cannot overwrite newer durable state. `recover/4` can start still-accepted work using freshly supplied definition/context, or return a compatible pending approval without invoking the model again. A model call interrupted while marked running, with no live worker in this instance, becomes `:blocked` / `:interrupted`; it is **not** silently retried. A committed tool result at the observation safe point can resume the default loop with its preserved exchanges, consumed counts and remaining active allowance. An interrupted final model call remains blocked instead of replayed. A recorded decision that did not start dispatch is also conservatively blocked on recovery; identical resubmission does not dispatch it. This API is not a cross-instance/node takeover protocol: use one owning Knotra instance for a given execution until ownership support exists.

## Answering the demonstration approval

Configure a fake tool explicitly: `durable: [repo: MyApp.Repo, access: MyApp.AgentAccess, demo_tools: [MyApp.FakeTool]]`. The host access policy must authorize `:answer` for the execution and derive the correct tenant from trusted responder identity. Use a fresh **map** context; neither that context nor credentials are restored from storage.

```elixir
{:ok, %{approval: request}} = Knotra.snapshot(MyApp.Agents, execution_id, host_context)

answer = %{
  request_id: request.id,
  version: request.version,
  name: request.name,
  arguments: request.arguments,
  decision: :approve # or :reject
}

{:ok, record} = Knotra.answer(MyApp.Agents, execution_id, definition, fresh_host_context, answer)
```

The answer map must contain exactly these five fields. Identity/version and the exact validated arguments must match; numeric coercion is not accepted. Expired, incompatible, unauthorized and wrong-tenant answers cannot dispatch. A rejection records terminal `:rejected` / `:approval_rejected` with no replacement proposal. The conditional decision increments the request version and retains the answered version for duplicate detection. Repeating the identical authorized answer is harmless; a conflicting answer fails. A successful return acknowledges a persisted disposition, **not** necessarily completion of its effect or final model call. Inspect the execution to see the current outcome.

Approval records a stable `approval.operation.id` before starting a continuation worker. That worker conditionally records dispatch intent and consumed tool count before invoking the tool. It revalidates arguments, checks current host business authorization, and checks its persisted revision before `call/2`. Both authorization and invocation receive the stable ID as `context.knotra_operation_id`; model arguments cannot supply or replace it. The independent test ledger records that ID and survives execution restarts. The operation result is checkpointed before advancing the restored loop/model exchange.

An effect error, retry request, timeout, lost result, or crash after dispatch admission is conservatively `:blocked` / `:uncertain_effect`, even if it might not have run. No retry is automatic and no exactly-once claim is made. If capacity is unavailable after recording the decision, the execution blocks with `:dispatch_not_started`; it is not silently queued for later effect execution. Duplicate answers cannot restart blocked work. Broader limit conformance is #7, and reconciliation/idempotent recovery is #8. This is not completion of the parent specification.

## Cancellation and response expiry

```elixir
Knotra.cancel(MyApp.Agents, execution_id, fresh_host_context)
# {:ok, %{status: :cancelled, error: :cancelled, ...}}
# or {:error, :already_admitted} if dispatch admission already won
```

The host must authorize `:cancel` for the execution's tenant. This stable-ID overload is distinct from the existing non-durable `cancel(pid)`: it conditionally terminates a waiting request or a recorded decision **before dispatch admission**. Repeating cancellation is harmless. It increments the request version, persists the terminal disposition in both public state and checkpoint, and fences delayed workers. A late answer returns `:execution_cancelled`; recovery cannot revive the cancelled execution. Cancellation of still-accepted or other active pre-approval work is outside this slice (`:not_waiting`). Already-terminal non-admitted outcomes are returned unchanged.

Dispatch admission means the committed intent, not the later wall-clock instant of a host effect. If that revision wins first, cancellation returns `:already_admitted` without changing history, killing the effect, or erasing its result. The execution may still complete or become blocked/uncertain. This is a declined cancellation, **not** remote rollback. If cancellation wins the conditional write first, no new dispatch can be admitted. Client-provided timestamps do not decide this race.

`response_timeout` sets a wall-clock human-response deadline, separate from the saved active-work allowance. While the request is still pending, authorized `snapshot/3`, `recover/4`, `answer/5`, or `cancel/3` discovers overdue requests and conditionally commits `:expired` / `:approval_expired`. Answer admission and expiry use complementary SQLite time predicates plus the same revision fence. An on-time committed answer consumes the human-response deadline; that deadline does not later expire an approved operation. There is no per-request timer or background sweeper, so an untouched overdue row is materialized as expired on its next lifecycle access—even following a fresh BEAM restart. Private `checkpoint/3` remains a read of the saved checkpoint, not an expiry trigger.

Expiry preserves consumed counts and remaining active allowance, ends this attempt, and never reproposes or implicitly approves. Late answers return `:approval_expired`. Storage failure returns an error rather than claiming an uncommitted cancellation or expiry. Direct lifecycle transitions are inspectable without replaying observers; a delayed old notification is not authoritative over the current durable record. Reconciliation of uncertain admitted effects remains deferred to #8.

## Verification and SQLite test lifecycle

Run `mix test test/durable_test.exs --warnings-as-errors` for the public-interface persistence scenarios. Run the existing suite separately or the full suite for regressions. No provider credentials or production effects are needed.

The test host uses committed, file-backed databases in private directories under ignored `_build/persistence-tests/`. It initializes migrations with one connection, then restarts with two connections, avoiding concurrent initial journal setup. Effective WAL mode, FULL synchronization and foreign keys are asserted. Exqlite 0.41 uses a cancellation-aware busy handler: the configured timeout is 5 seconds, while `PRAGMA busy_timeout` reports zero. Do not replace that handler with a PRAGMA just to make a configuration assertion pass. Concurrent submissions exercise independent writers; SQLite serializes writes, not business effects.

An independent ledger database observes fake effects and survives execution/runtime restarts. Tests stop runtime and Repo, reconnect to the same execution file, and separately inspect it from a fresh BEAM. Database triggers inject acceptance and pending-commit failures. A test-only Ecto Repo query gate pauses the submitting caller after the acceptance commit but before acknowledgment; killing it proves safe resubmission against the original ID without duplicate model work. Other scenarios cover lost-notification recovery, duplicate/conflicting submissions, tenant/permission checks, incompatible versions, unsupported continuations and runtime-created atoms, gated-observer capacity release, an offline ReqLLM provider continuation and interrupted model calls. Lifecycle tests additionally race approve/reject/cancel/expire through independent connections, synchronize around decision and dispatch writes, and verify eventual or uncertain effects remain observable when cancellation is too late. They control stored response deadlines to represent elapsed offline time without sleeps or private process-state assertions; the existing write-time expiry regression also checks the real SQLite clock. Fresh-BEAM checks verify cancellation preservation and lazy expiry persistence. Tests assert through public Knotra calls; direct SQL is confined to fixture configuration, controlled deadline setup and storage-failure injection. After all connections stop, each fixture deletes only its own directory and sidecars. A rollback-only SQL Sandbox is not used as restart evidence.

These checks prove the bounded SQLite slice, not power-loss durability, PostgreSQL parity, safe general effect retries, distributed leases or exactly-once execution. The existing architecture's DeepSeek-first comparison still applies: an inbox or snapshot is not a durable pending approval; LangGraph-style node replay can repeat effects. This slice deliberately stops instead of replaying an uncertain model step. No alternate harness dependency was adopted.
