# Durable submission and pending approvals

Implemented scope: [issue #4](https://github.com/stlucasgarcia/knotra/issues/4), the constrained fake-operation demonstration in [issue #5](https://github.com/stlucasgarcia/knotra/issues/5), waiting cancellation/expiry in [issue #6](https://github.com/stlucasgarcia/knotra/issues/6), and allowances/capacity/compatible restoration in [issue #7](https://github.com/stlucasgarcia/knotra/issues/7), using the [SQLite-first Ecto decision](adr/0001-ecto-sqlite-persistence.md). This is an opt-in path alongside the existing non-durable `Knotra.start/5`, not production ownership/recovery certification.

**Works:** commit-before-acknowledgment acceptance, tenant-scoped submission deduplication, a model-proposed operation, validated/authorized pending approval, approval/rejection by request identity and version, sequential explicitly allowlisted fake operations, preserved budgets and model continuation, bounded outstanding work, recoverable capacity-waiting decisions, stable inspection after restart, durable pre-admission cancellation, persisted response expiry on access, and private versioned checkpoints. Pending/terminal durable workers exit rather than retaining process handles.

**Does not work yet:** production consequential operations, approval edits, parallel/batched operations, cancellation of arbitrary active work by durable identity, background expiry sweeping, automatic background draining, autonomous retry of interrupted model work or uncertain effects, PostgreSQL certification, or distributed ownership. Answer admission checks expiry, including at the SQLite conditional write; there is no expiry scheduler.

## Host setup

The host owns its Ecto Repo, connections, database file, supervision and migration lifecycle. Knotra does not start or migrate a Repo. The SQLite adapter is test-only in this library; a SQLite host adds its own runtime `ecto_sqlite3` dependency. Ecto and Ecto SQL are optional for non-durable users.

Apply `Knotra.Persistence.Migration` explicitly through the host's migration workflow. For example, a host migration can delegate its `change/0` to that module; give it a unique host migration version. The initial table is `knotra_executions`, including a database-enforced unique tenant/submission-key index. Neither model/plugin options nor host authorization context are stored in that table. Inputs, model messages and proposed arguments can still be sensitive: restrict table/checkpoint access and retention accordingly.

Configure the instance only after the host Repo is available:

```elixir
{Knotra,
 name: MyApp.Agents,
 max_executions: 20,
 durable: [repo: MyApp.Repo, access: MyApp.AgentAccess, max_pending: 100]}
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

The instance's `max_executions` bounds active workers, including durable workers. Waiting approvals and capacity-waiting decisions retain no worker slot. If initial capacity is unavailable, work remains `:accepted`; an approved decision whose worker cannot start becomes `:ready`. There is no background queue drainer: explicitly call `recover/4` with fresh definition/context when capacity is available. Matching resubmission can start still-accepted work; repeating its exact approved answer can start ready work.

Optional `durable: [max_pending: positive_integer]` (default `:infinity`) bounds **all outstanding records in the configured Repo**, across tenants and restarts—not just currently waiting approvals. Acceptance uses one SQLite conditional insert, so concurrent writers cannot exceed the configured bound. Excess submissions return `{:error, :pending_limit}` without acceptance. Existing submission keys still deduplicate or report conflict at capacity. Accepted/running/waiting/decided/ready and blocked/reconciliation work occupy this bound; completed/failed/rejected/cancelled/expired records release it. Lazy expiry must be discovered before its row releases capacity. Configure the same bound for writers sharing a Repo. This is admission control, not terminal-history retention or a hard monetary limit; the host still owns storage retention.

Public records contain `:accepted`, `:running`, `:waiting`, `:decided`, `:ready`, `:rejected`, `:cancelled`, `:expired`, `:completed`, `:failed` or `:blocked` status, ordered events, consumed counts and an optional approval. The approval includes stable identity, request version, originating call ID, operation name, validated arguments, `:pending` disposition and wall-clock expiry. Argument validation and host tool authorization run before the request is published. Expiry starts when the pending request is prepared. An observer receives public snapshots only after the corresponding database update; missing/failed delivery is not proof that a committed request was lost. Re-query the record. For worker-produced terminal records, a separately supervised notifier waits for the execution supervisor to release the worker's slot before invoking the observer. Its observer call is bounded to one second; a slow or failed observer cannot retain active execution capacity.

## Safe points and recovery limits

This slice supports the default loop and default tool runtime with one proposed call per model reply. Each subsequent call requires its own new approval; after an effect the model may finish or propose another single operation within the original limits. Batch/parallel calls and a tool-free initial reply remain outside this demonstration. Unsupported compositions are rejected before acceptance; malformed model replies or invalid/unauthorized arguments fail without an approval or effect.

A durable model explicitly opts in with optional `Knotra.Model.checkpoint_version/0`, returning a positive integer. The ReqLLM adapter provides version 1. Compatible replies must contain only bounded inert data: binaries/numbers, proper lists, tuples/maps, the fixed checkpoint atom vocabulary and supported Knotra/ReqLLM message/tool-call structs. Arbitrary metadata should use string keys/values. Atoms outside the literal vocabulary are rejected before publication—even if they exist in the writing VM—so fresh-VM safe decoding does not depend on that VM's atom history. Functions, PIDs, ports, references, unsupported structs and oversized records are rejected. There is no arbitrary plugin-state serializer.

The checkpoint contains a format version, accepted input, loop state, full model exchanges/continuations, pending operation, counts, limits, response timeout and remaining active allowance; it is separate from the public snapshot. It deliberately excludes credentials, configuration options, live handles and host authorization. Serialization is size-bounded Erlang external-term data, decoded with `:safe` and validated again; it is not an interoperable wire format or a place to accept uploaded terms. Storage remains host-trusted. Model-generated text/data may still contain sensitive content and is not automatically scrubbed.

A fingerprint pins definition version, loop/model/tool-runtime identities, tool metadata and model checkpoint version. **The host must change the definition version whenever behavior, prompts or semantic model options change.** Private options are neither stored nor hashed; unchanged module names alone cannot detect changed code. Incompatible restoration is visibly blocked, including unsupported model/loop state or unreadable checkpoints. Encoding an unsupported continuation blocks the execution while retaining its last valid checkpoint. **The current format is v2:** v1 checkpoints are not automatically upgraded or resumed. Their saved bytes remain available for authorized inspection; attempting to recover nonterminal v1 work records `:incompatible_checkpoint`. Terminal history is returned unchanged.

Updates use a conditional revision, so stale workers cannot overwrite newer durable state. `recover/4` can start still-accepted work using freshly supplied definition/context, or return a compatible pending approval without invoking the model again. A model call interrupted while marked running, with no live worker in this instance, becomes `:blocked` / `:interrupted`; it is **not** silently retried. A committed tool result at the observation safe point can resume the default loop with its preserved exchanges, consumed counts and remaining active allowance. An interrupted final model call remains blocked instead of replayed. A `:ready` decision is safely recoverable because capacity refusal proved no worker started. A `:decided` record interrupted before that proof or dispatch is still conservatively blocked; identical resubmission does not dispatch it. This API is not a cross-instance/node takeover protocol: use one owning Knotra instance for a given execution until ownership support exists.

## Allowances across waiting and restart

Model attempts consume `max_turns`; tool admissions consume `max_tool_calls`. Retries also consume the shared `max_retries` and their relevant attempt allowance. Default-loop decisions consume `max_steps`; retrying an operation does not invent a new loop decision. Counts and original limits survive each wait/restart. Neither another approval nor repeated delivery resets them. An admitted durable effect's retry/error remains uncertain, not an automatic retry.

Active `timeout` uses a fresh local monotonic deadline per worker, derived from the **remaining** saved allowance—not the original timeout. Checkpoint construction records the unspent milliseconds. Waiting/ready checkpoints freeze it; human-response time and ready-queue time do not consume active allowance. Running checkpoints also store a wall-clock deadline: recovery conservatively charges time since that running safe point, including downtime, and clamps the result to the saved remainder. No old monotonic timestamp is restored. Backward wall-clock movement cannot increase that saved remainder; forward jumps can exhaust it early. This deliberately conservative policy is not precision billing or distributed-clock certification. An exhausted allowance prevents further model/tool work.

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

The answer map must contain exactly these five fields. Identity/version and the exact validated arguments must match; numeric coercion is not accepted. Expired, incompatible, unauthorized and wrong-tenant answers cannot dispatch. A rejection records terminal `:rejected` / `:approval_rejected` with no replacement proposal. The conditional decision increments the request version and retains the answered version for duplicate detection. Repeating the identical authorized answer is harmless, including an earlier answer after a later request is published; a conflicting answer fails. Persisted `:approval_answered` events retain those receipts, and `:tool_result` events retain completed operation identities. A successful return acknowledges a persisted disposition, **not** necessarily completion of its effect or final model call. Inspect the execution to see the current outcome.

Approval records a stable `approval.operation.id` before starting a continuation worker. That worker conditionally records dispatch intent and consumed tool count before invoking the tool. It revalidates arguments, checks current host business authorization, and checks its persisted revision before `call/2`. Both authorization and invocation receive the stable ID as `context.knotra_operation_id`; model arguments cannot supply or replace it. The independent test ledger records that ID and survives execution restarts. The operation result is checkpointed before advancing the restored loop/model exchange.

An effect error, retry request, timeout, lost result, or crash after dispatch admission is conservatively `:blocked` / `:uncertain_effect`, even if it might not have run. No retry is automatic and no exactly-once claim is made. If capacity is unavailable after recording the decision, `:ready` preserves it for explicit recovery or exact-answer redelivery with fresh context. Other continuation-start failures block with `:dispatch_not_started`; duplicate answers cannot restart blocked work. Reconciliation/idempotent recovery remains #8. This is not completion of the parent specification.

## Cancellation and response expiry

```elixir
Knotra.cancel(MyApp.Agents, execution_id, fresh_host_context)
# {:ok, %{status: :cancelled, error: :cancelled, ...}}
# or {:error, :already_admitted} if dispatch admission already won
```

The host must authorize `:cancel` for the execution's tenant. This stable-ID overload is distinct from the existing non-durable `cancel(pid)`: it conditionally terminates a waiting request or a recorded/ready decision **before its dispatch admission**. Repeating cancellation is harmless. It increments the request version, persists the terminal disposition in both public state and checkpoint, and fences delayed workers. A late answer returns `:execution_cancelled`; recovery cannot revive the cancelled execution. Cancellation of still-accepted or other active pre-approval work is outside this slice (`:not_waiting`). Already-terminal non-admitted outcomes are returned unchanged.

Dispatch admission means the committed intent, not the later wall-clock instant of a host effect. If that revision wins first, cancellation returns `:already_admitted` without changing history, killing the effect, or erasing its result. The execution may still complete or become blocked/uncertain. Admission is tracked per operation: a later pending approval can be cancelled even after an earlier effect completed, without erasing that effect's event/ledger history. This is a declined cancellation for an already-admitted current operation, **not** remote rollback. If cancellation wins the conditional write first, no new dispatch can be admitted. Client-provided timestamps do not decide this race.

`response_timeout` sets a wall-clock human-response deadline, separate from the saved active-work allowance. While the request is still pending, authorized `snapshot/3`, `recover/4`, `answer/5`, or `cancel/3` discovers overdue requests and conditionally commits `:expired` / `:approval_expired`. Answer admission and expiry use complementary SQLite time predicates plus the same revision fence. An on-time committed answer consumes the human-response deadline; that deadline does not later expire an approved operation. There is no per-request timer or background sweeper, so an untouched overdue row is materialized as expired on its next lifecycle access—even following a fresh BEAM restart. Private `checkpoint/3` remains a read of the saved checkpoint, not an expiry trigger.

Expiry preserves consumed counts and remaining active allowance, ends this attempt, and never reproposes or implicitly approves. Late answers return `:approval_expired`. Storage failure returns an error rather than claiming an uncommitted cancellation or expiry. Direct lifecycle transitions are inspectable without replaying observers; a delayed old notification is not authoritative over the current durable record. Reconciliation of uncertain admitted effects remains deferred to #8.

## Verification and SQLite test lifecycle

Run `mix test test/durable_test.exs --warnings-as-errors` for the public-interface persistence scenarios. Run the existing suite separately or the full suite for regressions. No provider credentials or production effects are needed.

The test host uses committed, file-backed databases in private directories under ignored `_build/persistence-tests/`. It initializes migrations with one connection, then restarts with two connections, avoiding concurrent initial journal setup. Effective WAL mode, FULL synchronization and foreign keys are asserted. Exqlite 0.41 uses a cancellation-aware busy handler: the configured timeout is 5 seconds, while `PRAGMA busy_timeout` reports zero. Do not replace that handler with a PRAGMA just to make a configuration assertion pass. Concurrent submissions exercise independent writers; SQLite serializes writes, not business effects.

An independent ledger database observes fake effects and survives execution/runtime restarts. Tests stop runtime and Repo, reconnect to the same execution file, and separately inspect it from a fresh BEAM. Database triggers inject acceptance and pending-commit failures. A test-only Ecto Repo query gate pauses the submitting caller after the acceptance commit but before acknowledgment; killing it proves safe resubmission against the original ID without duplicate model work. Other scenarios cover lost-notification recovery, duplicate/conflicting submissions, tenant/permission checks, incompatible versions, unsupported continuations and runtime-created atoms, gated-observer capacity release, an offline ReqLLM provider continuation and interrupted model calls. Lifecycle tests additionally race approve/reject/cancel/expire through independent connections, synchronize around decision and dispatch writes, and verify eventual or uncertain effects remain observable when cancellation is too late. They control stored response deadlines to represent elapsed offline time without sleeps or private process-state assertions; the existing write-time expiry regression also checks the real SQLite clock. Fresh-BEAM checks verify cancellation preservation and lazy expiry persistence. Allowance tests observe model attempts and the independent effect ledger across repeated waits/restarts, exercise shared retry/attempt/step limits, and control saved deadlines/remainders to prove that restored workers cannot replenish time. Concurrent bounded submissions, restart admission, blocked-work quota retention and ready-decision recovery/cancellation cover capacity. Checkpoint canaries cover credentials/private options/authority and revocation after restart. Tests assert through public Knotra calls; direct SQL is confined to fixture configuration, controlled deadline/allowance/corruption setup and storage-failure injection. After all connections stop, each fixture deletes only its own directory and sidecars. A rollback-only SQL Sandbox is not used as restart evidence.

These checks prove the bounded SQLite slice, not power-loss durability, PostgreSQL parity, safe general effect retries, distributed leases or exactly-once execution. The existing architecture's DeepSeek-first comparison still applies: an inbox or snapshot is not a durable pending approval; LangGraph-style node replay can repeat effects. This slice deliberately stops instead of replaying an uncertain model step. No alternate harness dependency was adopted.
