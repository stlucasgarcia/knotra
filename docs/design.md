# Knotra: agreed design and first milestone

Status: milestone 1 implemented as a non-durable prototype; production guarantees remain deferred. Comparative evidence: [Elixir alternatives](research/elixir-agent-alternatives.md). Domain vocabulary: [CONTEXT.md](../CONTEXT.md).

## Purpose

An embedded Elixir library for background agent executions, eventually supporting an agent factory. The first use case accepts an email, performs an authorized read-only receipt lookup, and produces a proposed reply. The host owns triggers and business authorization. Each execution has isolated state; agent definitions are reusable.

## Dependency constraint

ReqLLM is the only permitted direct third-party dependency for now. Its transitive dependencies are unavoidable. Elixir/OTP standard libraries are available. Do not add other harnesses, Ecto, Postgrex, Telemetry, Phoenix, or alternative storage packages. Borrow architectural ideas, not framework dependencies.

This supersedes PostgreSQL/Ecto and telemetry-package implementation in the first milestone. Keep their capability boundaries; defer concrete integrations. Do not write a database driver to evade this constraint.

## Everything is a plugin

The core defines execution identity, data contracts, valid lifecycle transitions, and composition validation. Behavior is supplied by explicitly configured plugins, including the loop, model access, tool execution, persistence, admission, ownership/recovery, and observation. These are capability boundaries, not a requirement for one package, process, or implementation per capability now.

Use narrow Elixir behaviours, ordinary modules for stateless behavior, and optional supervised children where lifecycle requires them. No generic state-mutating event bus, discovery framework, hot swapping, or service container. Introduce concrete interfaces as the milestone needs them, not speculative stubs for every future capability.

The default tool execution plugin is `Knotra.ToolRuntimes.Default`: validation, authorization, then execution. Read-only is the current policy restriction, not a separate runtime mechanism; future write support must add approval and retry rules without duplicating that pipeline.

The loop requests operations through configured capabilities; the supported API must preserve authorization, recording, cancellation, and budgets. Trusted in-VM plugins are not sandboxed against malicious code. Capability validation must reject a production composition that cannot provide the required production guarantees.

## Elixir/OTP approach

Embed a named instance under the host supervision tree. Use supervised temporary execution processes and supervised tasks for blocking calls. Processes exist for concurrency, lifecycle, or isolation, not to represent every module. Keep individual execution steps sequential initially and bound concurrent executions. Keep coordinator processes responsive to cancellation and deadlines.

Supervision restarts processes; durable recovery restores work. These are separate responsibilities.

## Milestone 1: prove the replaceable execution path

Explicitly non-durable and not production-ready.

- Small execution contracts and a replaceable default model/tool loop.
- ReqLLM model plugin preserving provider options and rejecting unsupported capabilities explicitly.
- Host-supplied repeatable read-only tools; authorization context cannot be chosen through model arguments.
- Isolated execution state, bounded turns/tool calls/retries/time, and cancellation.
- Inspectable in-memory execution records and an observation boundary without an additional telemetry dependency.
- Test-only in-memory persistence implementation, with no restart-recovery claims.
- A sanitized email/receipt scenario and deterministic model/tool fakes.
- An alternate loop exercised through the same core to prove substitution.

Use focused ExUnit checks and shared conformance checks where substitution needs proof. Tests must cover unauthorized lookup rejection, model/tool failures, limits, cancellation, recorded outcomes, and loop replacement. Offline checks must stub both models and tools. Live-model evaluation is explicit and separate from deterministic tests; it checks facts, permitted tool use, output structure, and termination rather than exact prose.

Do not compare or adopt Alloy/Jido adapters under the dependency restriction. Implement the smallest default loop using ReqLLM.

## Deferred production baseline

The following remain requirements, not claims of milestone 1:

- Host-provided PostgreSQL/Ecto integration through a persistence plugin, only after dependency authorization changes.
- Durable acceptance before acknowledgment and tenant-scoped submission idempotency.
- Durable pending work, bounded admission/concurrency, and database-coordinated ownership across replicas without requiring BEAM distribution.
- Stale-owner rejection on durable updates; no promise that an already-dispatched remote request can be retracted.
- Recorded step boundaries and persisted aggregate budgets across recovery.
- Pinned definition/composition identity; compatible interrupted work can recover, incompatible work becomes visibly blocked.
- Host-integrated deployment draining and revalidated authorization on recovery.
- Host-controlled record retention/access, credentials excluded, and explicitly sanitized evaluation scenarios.

Exactly-once external effects are not promised. Interrupted model calls or reads can repeat. Cancellation does not roll back remote effects. Write tools require a separately agreed authorization, idempotency, and reconciliation design.

## Inspection, evaluation, and caches

Execution inspection, fixed-response offline replay, and fresh-model evaluation are distinct capabilities. Operational observation is not the durable execution record. General replay infrastructure is deferred; deterministic fakes are sufficient initially.

Preserve provider prompt-cache options and report usage when available. Unknown usage remains unknown. No semantic answer cache, financial-tool result cache, or projection cache initially. Do not claim an exact monetary cap from incomplete provider accounting.

## Future direction, not current scope

Skills, memory, routing, agent creation, generated-code sandboxes, financial writes, connectors, dashboards, and Rust are deferred. Future generated agents must enter through validated execution and authorization boundaries. Rust is an allowed future option only when measured need justifies it.

Knotra does not differentiate merely through embedding, OTP, plugins, or replaceable loops; competitors already provide these. Its intended distinction is the combined production execution contract. That must be demonstrated by tests and operational evidence before being claimed.

## Implementation evidence and remaining boundary

Milestone 1 provides replaceable loop/model/tool-runtime/observer behaviours, supervised execution, bounded attempts, cancellation, and public in-memory records. A test-only observer stores snapshots in an Agent; there is no production persistence implementation or recovery interface yet. Completed handles consume instance capacity until explicitly released.

Host tools must implement argument validation separately from their JSON-schema metadata: ReqLLM 1.24 does not enforce map schemas locally. The adapter disables ReqLLM transport retries so attempts do not silently escape Knotra's counters; provider failures are conservatively non-retryable.

Verification: 20 offline ExUnit tests, warnings-as-errors compilation/tests, formatting, and diff checks passed. Tests include alternate loop/model/tool-runtime/observer implementations, the email/receipt scenario, forbidden and malformed calls, budgets, cancellation, task death, and a ReqLLM interaction using a fake HTTP adapter. No paid/live model evaluation or durable failure testing was performed.

Do not claim deployment continuity, multi-replica ownership, durable acceptance, or financial production readiness before their implementations and failure tests exist. Further implementation requires choosing the next scope; the dependency restriction remains in force.
