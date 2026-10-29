# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

Two visual surfaces, both server-rendered Phoenix LiveView; the library core, persistence and contracts are headless.

- **Embeddable observability dashboard** — `lib/knotra/dashboard/live.ex`, mounted by hosts at their own protected route. Confirmed role: internal debugging tool for developers/operators.
- **Demo host application** — `examples/knotra_bots` (chat, `/agents`, `/channels`, `/observability`, own `priv/static/css/app.css`). It is a POC tour of the library's durable approval slice, runnable offline with `KNOTRA_BOTS_MODEL=fake`; its README states its boundaries and it is not a production surface.

## Users

Primary: Elixir developers building a host application that needs background and user-interactive agent workflows. They add Knotra as a dependency, start a named instance under their own supervision tree, supply agent definitions, tools and authorization scope. The durable path additionally needs a host-owned Repo and host-run migrations.

Secondary: the same developers wearing an operator hat, watching the debugging dashboard while their host app runs.

Confirmed ship form: an open-source library for other Elixir developers (no LICENSE file exists yet; licensing terms are undecided and must not be invented).

## Product Purpose

An embedded, plugin-driven Elixir agent harness for both autonomous background work and user-interactive workflows. The host application owns identity, channels and business authority; Knotra coordinates bounded execution, lifecycle and recovery. Success means a reviewer can verify the production execution contract — durable acceptance, recovery, visible blocking of incompatible work, host-authoritative authorization — from tests and operational evidence rather than prose.

## Positioning

Knotra does not differentiate merely by being embedded, using OTP, offering plugins or a replaceable loop; adjacent projects already provide those. Its claim is the combined production execution contract: committed acceptance before acknowledgement, bounded aggregate budgets preserved across recovery, recovery that pins definition/composition identity, and authorization that never arrives through model arguments. That contract must be demonstrated by tests and operational evidence before it is claimed.

## Operating Context

- Elixir `~> 1.20` Mix library; `ReqLLM ~> 1.24` is the base model dependency.
- Opt-in durable slice via optional `ecto`/`ecto_sql` and a host-owned Repo; `ecto_sqlite3` only in tests. ADR 0001 authorizes exactly this exception — every other dependency or framework adoption still needs owner authorization.
- Canonical vocabulary lives in [CONTEXT.md](CONTEXT.md) (Execution, not "Agent", for one work request; input request vs approval request; swarm, shared board, execution inbox, human takeover, presentation request).
- Verification is offline: `mix test` makes no provider calls and needs no keys; provider behavior is exercised through fixture HTTP responses. Live-model evaluation is explicit, sanitized and separate.
- Issues tracked in GitHub Issues; triage uses the default five roles.
- Hosts protect the dashboard themselves; Knotra provides no access control.

## Capabilities and Constraints

Implemented: non-durable `start/5` read-only path (loop/model/tool-runtime/observer plugins, budgets, deadlines, cancellation, in-memory records); opt-in durable approval and input-request slice with committed acceptance, worker-free waits, pre-admission cancel, expiry, preserved allowances and compatible kind-dependent restoration; bounded in-memory observability store with an embeddable LiveView dashboard.

Planned or exploratory, and not claimable: distributed ownership and multi-replica durability, deployment draining, Postgres integration, human takeover, presentation requests and voice, generated code execution, swarms/delegation with durable board and inbox, and the hundreds-of-simultaneous-model-calls capacity target (unbenchmarked).

Hard limits that future work must preserve: no sandboxing of trusted in-VM plugins; `read_only` is a contract, not enforcement; no exactly-once external effects; cancellation cannot retract dispatched work; no hard monetary cap, answer cache or durable-audit guarantee; ReqLLM 1.24 does not validate map-schema tool arguments locally, so host `validate/1` is mandatory.

Confirmed next milestone: make the durable production contract real (host Postgres/Ecto, recovery, ownership) rather than add new branches.

## Brand Commitments

Name: Knotra. Documentation voice is already established and binding: factual, claim-skeptical, "implemented / planned / exploratory" status labels, no marketing superlatives, limitations stated next to capabilities. No logo, palette or visual identity exists.

## Evidence on Hand

- Working implementation under `lib/`, with offline test suites: `knotra_test.exs`, `durable_test.exs`, `observability_test.exs`, `observability_timing_test.exs`, `req_llm_test.exs`, `dashboard_test.exs`.
- Fixture-backed provider tests for OpenAI, Anthropic and Gemini.
- Executable acceptance mapping in [docs/approval-validation.md](docs/approval-validation.md); SQLite restart/race lifecycle in [docs/durable-approvals.md](docs/durable-approvals.md).
- Demo host application at `examples/knotra_bots`; benchmark script at `bench/observability_bench.exs`.
- Absences future work must not fill: no production Postgres persistence, no live-model evaluation results, no multi-replica or load evidence, no license, no published benchmark results, no customers or testimonials.

## Product Principles

1. The host owns authority. Tenant scope, business permission and access control never come from model arguments, UI events, transcripts or conversation ids.
2. Claims require evidence. Anything unimplemented is labeled implemented/planned/exploratory and never described as production-ready.
3. Narrow kernel, replaceable capabilities. Behaviour enters through configured plugins and validated compositions; no speculative interfaces, discovery frameworks or event buses.
4. Bounded by default. Every execution carries counters, deadlines, capacity and cancellation; exhaustion fails visibly rather than silently degrading.
5. Survive restarts before promising continuity. Durable acceptance precedes acknowledgement, and uncertain work blocks for reconciliation instead of repeating blindly.

## Accessibility & Inclusion

The LiveView dashboard is an internal debugging tool for developers and host operators; no formal accessibility standard has been agreed, and none should be claimed.
