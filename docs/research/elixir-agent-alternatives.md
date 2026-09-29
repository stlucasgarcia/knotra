# Research: Elixir agent alternatives and Knotra

## Executive recommendation

**Build only the narrow execution-control layer that the finance workflow needs; do not build another general agent framework.** Existing libraries already supply embedded loops, replaceable strategies, tools, checkpoints, approvals, telemetry, and testing. None of the inspected evidence establishes Knotra's entire intended combination of durable acceptance, tenant-scoped deduplication, database-fenced ownership, pinned compositions, compatible recovery, and host-controlled retention. That is a reason to validate a small control layer—not proof of a market gap.

First compare a plain ReqLLM-backed read/lookup/draft pipeline against an **Alloy loop adapter**. Evaluate **LangEx** only if durable graph/HITL behavior is actually needed; **Jido.AI's standalone ReAct runtime** is the strongest alternative when strategy extensibility matters. Sagents is particularly credible if interactive sessions become central. Legion is the closest embedded application-agent positioning threat, but generated-code execution is unnecessary for the initial receipt workflow. Do not adopt Synapse solely because it advertises Postgres persistence.

Knotra currently has generated hello code only. Every Knotra guarantee below is **agreed design, not implemented differentiation**.

## Method and provenance

Retrieval session: **2026-09-29**, using the supplied session date; no independent wall-clock check. The live Hex response for BeamWeaver includes a release timestamp on 2026-09-29. The resumed attempt successfully used registered `web_search`, `fetch_content`, `get_search_content`, and `source_check`; the earlier blocked attempt contributed no evidence.

Read local `docs/agents/domain.md` and `CONTEXT.md`. No implementation, dependency changes, or commands were run. GitHub fetches produced temporary repository snapshots; selected source, tests, guides, manifests, and Git refs were read. Tests were **inspected, not executed**. Hex versions below are registry observations, not assertions that every inspected default-branch feature ships in those versions. Commit IDs come from the fetched repositories' `origin` refs; source links pin those snapshots where practical.

Evidence labels: **S** = source/test inspected; **D** = primary documentation or registry metadata; **N** = not established in this bounded inspection; **I** = researcher inference/recommendation. S is not an audit or proof of production behavior. Two `source_check` calls retrieved passages but returned `unclear` because automated semantic assessment was unavailable; decision-critical conclusions therefore rest on manually inspected originals. No performance or cost-saving benchmark is asserted.

## Identity, versions, licenses, and maintenance signals

All thirteen descriptions resolve to the projects below. “Official” means the project's own repository/package, not endorsement by the underlying protocol organization. Version/date/license entries come from the linked Hex API; dates are publication dates of the named release, not last code activity. Latest prerelease is distinguished from stable.

| Name | Project repository / inspected commit | Hex observation | Declared license; maintenance signal |
|---|---|---|---|
| A2A | [actioncard/a2a-elixir](https://github.com/actioncard/a2a-elixir/tree/ea71190bf7992c27670f68d40358e5741af49646) | [a2a 0.3.0](https://hex.pm/api/packages/a2a), 2026-09-23 | Apache-2.0; pre-1.0 API warning, tests/CI present |
| A2UI | [actioncard/a2ui-elixir](https://github.com/actioncard/a2ui-elixir/tree/115041255656d753139f08f8626d56dc123583d2) | [a2ui 0.3.0](https://hex.pm/api/packages/a2ui), 2026-09-23 | Apache-2.0; pre-1.0, LiveView renderer |
| Bazaar | [georgeguimaraes/bazaar](https://github.com/georgeguimaraes/bazaar/tree/ce659ed81551a37f3137a68e652af4c2d855f0fa) | [bazaar 0.3.0](https://hex.pm/api/packages/bazaar), 2026-09-17 | Apache-2.0; recent UCP work; ACP explicitly in progress |
| Alloy | [alloy-ex/alloy](https://github.com/alloy-ex/alloy/tree/6250ec6cdab0d66a44e54a4a431cc8cacaa63d4b) | [alloy 0.12.4](https://hex.pm/api/packages/alloy), 2026-07-03 | MIT; runtime-package extraction announced; tests/CI present |
| BeamWeaver | [caudena/beam_weaver](https://github.com/caudena/beam_weaver/tree/7d115a651aea6e0575c814e667114c5f17f504e7) | [beam_weaver 0.1.30](https://hex.pm/api/packages/beam_weaver), 2026-09-29 | Apache-2.0; frequent recent releases, API reports no published HexDocs for this release |
| Jido | [agentjido/jido](https://github.com/agentjido/jido/tree/90b163eef87ace89a153e94f114c8dc736be2ccd) | [jido](https://hex.pm/api/packages/jido): stable 2.3.3, 2026-08-10; 3.0.0-beta.1, 2026-09-14 | Apache-2.0; active major-version transition; do not assume main equals stable |
| Jido.AI | [agentjido/jido_ai](https://github.com/agentjido/jido_ai/tree/01b7dca0f8897980097260c6cd15515658c56676) | [jido_ai 2.3.0](https://hex.pm/api/packages/jido_ai), 2026-08-05 | Apache-2.0; separate package coupled to Jido/ReqLLM |
| LangEx | [freshaengineering/lang_ex](https://github.com/freshaengineering/lang_ex/tree/695b99d75d593250cce3b06c7bd026eb8d361bdc) | [lang_ex 0.13.0](https://hex.pm/api/packages/lang_ex), 2026-08-24 | MIT; Hex/README name `surgeventures/lang_ex`, discovery URL uses Fresha; ownership-name mismatch recorded |
| Legion | [software-mansion/legion](https://github.com/software-mansion/legion/tree/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7) | [legion 0.5.1](https://hex.pm/api/packages/legion), 2026-09-26 | MIT; recent releases, recovery/sandbox tests present |
| LangChain | [brainlid/langchain](https://github.com/brainlid/langchain/tree/d113a009122069bd8f04c1fe18174d40ac0f18b9) | [langchain 0.14.3](https://hex.pm/api/packages/langchain), 2026-09-24 | Apache-2.0; release history starts in 2023; Elixir project, not Python/JS parity |
| Sagents | [sagents-ai/sagents](https://github.com/sagents-ai/sagents/tree/5ff209c972cddece02fcebfe35cf1b7b2d1e1105) | [sagents 0.15.3](https://hex.pm/api/packages/sagents), 2026-09-24 | Apache-2.0; migration guides and recent releases; 0.15.0 retired for oversized package |
| SwarmEx | [nrrso/swarm_ex](https://github.com/nrrso/swarm_ex/tree/596f6eb37289d6414bc21ea0e53ea3640df8983a) | [swarm_ex 0.2.0](https://hex.pm/api/packages/swarm_ex), 2024-10-31 | Apache-2.0; substantially older published release; abandonment not established |
| Synapse | [nshkrdotcom/synapse](https://github.com/nshkrdotcom/synapse/tree/bc43df9671b1e4974054e1ce0109f3e37733e9f4) | [synapse 0.1.1](https://hex.pm/api/packages/synapse), 2025-11-30 | MIT; two registry releases; comparatively old published snapshot |

The Synapse Hex response explicitly links `nshkrdotcom/synapse` and describes Postgres-backed agent workflows. It is **not** the similarly named BEAM distributed registry. A2A here is Actioncard's implementation, not `a2a_ex`; that alternative also exists but does not match the supplied fleet/skills description as directly.

## Findings: closest alternatives

### 1. Alloy — best small-loop reuse candidate

**Claim (S, high):** the loop is a callable function, with middleware/provider seams, pre-turn limits, and telemetry; it does not require a long-lived GenServer. [Turn source](https://github.com/alloy-ex/alloy/blob/6250ec6cdab0d66a44e54a4a431cc8cacaa63d4b/lib/alloy/agent/turn.ex) checks `max_turns`, then accumulated `estimated_cost_cents`, and carries a single retry deadline. **Interpretation:** `max_budget_cents` is not a hard upper bound on the next provider invoice; a request can consume more than the remaining budget. README wording “before overspending” is stronger than this check alone establishes.

**Fit:** embed behind Knotra's loop behaviour, map messages/results, supply a ReqLLM-backed provider adapter if retaining ReqLLM is mandatory, and expose only the authorized receipt tool. Kernel admission, identity, durable acceptance, ownership, and retention remain outside. **N:** interchangeable internal loop behaviour, database ownership, composition-pinned recovery, and durable acceptance are not established. Replacing Alloy wholesale behind Knotra's seam is different from replacing Alloy's own loop.

[Testing source](https://github.com/alloy-ex/alloy/blob/6250ec6cdab0d66a44e54a4a431cc8cacaa63d4b/lib/alloy/testing.ex) scripts provider responses with no HTTP. This is useful harness testing, **not automatically complete offline replay**: tool functions can still execute. Stub tool outcomes separately. [README](https://github.com/alloy-ex/alloy/blob/6250ec6cdab0d66a44e54a4a431cc8cacaa63d4b/README.md) documents provider prompt caching, not application answer/tool-result caching, and says persistence/scheduling/tenancy belong to the application.

Cost: modest adapter work but nontrivial checkpoint-boundary integration; wrapping a whole `run` call does not create safe mid-run checkpoints. [Manifest](https://github.com/alloy-ex/alloy/blob/6250ec6cdab0d66a44e54a4a431cc8cacaa63d4b/mix.exs) has Req/Jason/Telemetry as mandatory runtime dependencies and optional PubSub. The documented move of agent/session functionality to `alloy_agent` is a migration risk; this README says that wrapper is not yet published, so do not assume otherwise from search summaries.

### 2. Jido + Jido.AI — strongest modularity threat

**Claim (S, high):** loop/strategy replacement is already real, not a Knotra invention. [Jido.Agent.Strategy](https://github.com/agentjido/jido/blob/90b163eef87ace89a153e94f114c8dc736be2ccd/lib/jido/agent/strategy.ex) defines command/init/tick/snapshot contracts; snapshot provides a stable result view independent of strategy internals. [Storage behaviour](https://github.com/agentjido/jido/blob/90b163eef87ace89a153e94f114c8dc736be2ccd/lib/jido/storage.ex) separates checkpoint overwrites from ordered thread appends with `expected_rev` conflict semantics. [Conformance guide](https://github.com/agentjido/jido/blob/90b163eef87ace89a153e94f114c8dc736be2ccd/guides/storage-conformance.md) specifies reusable adapter suites and concurrent-writer tests.

**Claim (D, high):** [multi-tenancy documentation](https://github.com/agentjido/jido/blob/90b163eef87ace89a153e94f114c8dc736be2ccd/guides/multi-tenancy.md) already partitions registry identity, persistence, lineage, and telemetry, with Pod-oriented durable teams. **Interpretation:** namespace isolation is meaningful overlap, but does not itself prove authorization for a host receipt query. Optimistic journal revision is not a lease/fencing protocol for all execution effects.

[Jido.AI standalone ReAct](https://github.com/agentjido/jido_ai/blob/01b7dca0f8897980097260c6cd15515658c56676/guides/user/standalone_react_runtime.md) documents running without the Agent macro, checkpoint tokens, cross-process/node resume, configuration fingerprints, iteration/tool concurrency/retry limits, effect allowlists, and scripted model tests. **D, high:** this substantially overlaps embedding, compatibility checking, budgets, and fixture testing. The same guide says tools still run in scripted tests.

**Recovery distinction (S, high):** [Agent checkpoint sanitization](https://github.com/agentjido/jido_ai/blob/01b7dca0f8897980097260c6cd15515658c56676/lib/jido_ai/checkpoint.ex) removes process-local handles, marks interrupted streams failed, and resets active ReAct strategy state to idle. Do not confuse restoring an Agent snapshot with continuing a standalone ReAct checkpoint token. **N:** end-to-end database-fenced ownership and Knotra-style durable deduplicated admission across replicas.

Reuse seam: standalone ReAct as a loop plugin, or Jido actions as tool adapters. Costs: Jido-specific action/schema/directive/thread concepts and version coupling, not just ReqLLM. [Jido manifest](https://github.com/agentjido/jido/blob/90b163eef87ace89a153e94f114c8dc736be2ccd/mix.exs) and [AI manifest](https://github.com/agentjido/jido_ai/blob/01b7dca0f8897980097260c6cd15515658c56676/mix.exs) show the broader ecosystem. Borrow conformance tests and stable snapshots now; do not adopt Pods/sensors/skills simply for one background execution.

### 3. LangEx — strongest durable graph alternative

**Claim (S, high):** recovery is more precise than “checkpoints exist.” [Journal source](https://github.com/freshaengineering/lang_ex/blob/695b99d75d593250cce3b06c7bd026eb8d361bdc/lib/lang_ex/graph/journal.ex) records successful work keyed to a checkpoint anchor and step; on continuation it reuses completed results, while failures/interrupts are not journaled. Backends without journal callbacks fall back to whole-super-step durability. Fresh runs do not reuse abandoned journals.

[Durability tests](https://github.com/freshaengineering/lang_ex/blob/695b99d75d593250cce3b06c7bd026eb8d361bdc/test/lang_ex/checkpoint/durability_test.exs) explicitly assert that a completed sibling node does not rerun when another crashes. These inspected tests use the memory checkpointer; they are not evidence of a successful multi-node Postgres fault-injection run. [Postgres implementation](https://github.com/freshaengineering/lang_ex/blob/695b99d75d593250cce3b06c7bd026eb8d361bdc/lib/lang_ex/checkpoint/postgres.ex) supports host Repo configuration, checkpoint namespaces, per-task journal writes, and blob deduplication.

**Interpretation:** an external effect completed before its successful result is recorded can still repeat. Checkpoint version fields and compiled graph shape do not alone prove compatibility with changed code. The inspected writes are checkpoint/journal upserts, not evidence of stale-owner fencing. **N:** a complete multi-replica claim/lease/fence protocol and tenant authorization.

[README](https://github.com/freshaengineering/lang_ex/blob/695b99d75d593250cce3b06c7bd026eb8d361bdc/README.md) documents interrupt/resume, graph functions rather than a GenServer per conversation, retries/timeouts, call budgets, encrypted checkpoints, node caches, and telemetry. These are substantial overlaps. Replacing node/model/checkpointer is supported; replacing the whole graph scheduler is not established. Reuse seam: graph runtime plugin; cost: translating Knotra lifecycle into thread/namespace/checkpoint semantics without two competing recovery owners. [Manifest](https://github.com/freshaengineering/lang_ex/blob/695b99d75d593250cce3b06c7bd026eb8d361bdc/mix.exs) keeps Redis/Postgres/Ecto/OTel integrations optional.

### 4. Legion — closest embedded-app positioning

**Claim (S, high):** [Postgres store](https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/lib/legion/store/postgres.ex) uses the host Ecto Repo, saves compressed Erlang-term conversation snapshots, supports turn/default or step persistence, and tracks running/idle status. Its inspected save path performs partial upserts by agent ID without an owner epoch predicate.

[Startup recovery](https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/lib/legion/recovery.ex) scans a bounded number of records, selects running **root** agents, bounds concurrent recoveries, then exits. It deliberately does not independently recover children because parent replay could dispatch them again. **Interpretation:** this is bounded startup recovery, not proven continuous takeover or exactly-once effects. Filtering after `list(limit)` also means a scan is not a guarantee that every interrupted root is discovered. Multi-replica exclusive recovery remains **N**.

[Sandbox guide](https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/guides/sandboxes.md) describes same-node Lua VM isolation, explicit tool bridges, resource limits, and the larger attack surface of Elixir AST allowlisting. **D, high; not independently security-audited.** Sandbox isolation does not authorize host business operations; exposed tools remain responsible. The guide also documents lossy Lua/Elixir conversion—important adapter cost, not a transparent replacement for ordinary tool calls.

The [manifest](https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/mix.exs) includes ReqLLM, Ecto/Postgrex, Lua, Vault, Jason, and Telemetry. Store/sandbox/rate-limit seams are present; a fully replaceable execution loop is **N**. Borrow explicit recovery boundaries and root/child replay reasoning; defer code generation and sandbox machinery. `EvalGuard` is evaluation-of-generated-code policy, not by its name an offline model-quality evaluation suite.

### 5. Sagents — substantial overlap beyond LiveView

**Claim (S, high):** [AgentExecution](https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/lib/sagents/modes/agent_execution.ex) implements LangChain's mode behaviour as a pipeline: call budget, model, pause/HITL, tools, state propagation, termination. This is real loop composition. It prevents execution of truncated tool calls; its comments distinguish approval resume paths with retained versus fresh call budgets. **Interpretation:** Knotra should bound the whole execution across resumes, not accidentally reset its aggregate budget.

[Persistence guide](https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/docs/persistence.md) documents generated scope-filtered persistence and fresh caller scope on restore. [Serializer source](https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/lib/sagents/persistence/state_serializer.ex) excludes model/tools/middleware configuration and runtime identifiers, serializes conversation state, and migrates formats. **S/D, high:** a credible pattern for separating secrets/configuration from persisted records. **Interpretation:** restoring with current code differs from pinning the old composition; Knotra needs explicit compatibility checking rather than assuming either policy is universally correct.

[Deployment guide](https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/docs/deployment.md) explicitly says host drain/readiness wiring must precede supervision teardown. [README](https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/README.md) documents optional Horde distribution, middleware, approvals, delegation, and a separate debugger. That is not evidence of database-only ownership without BEAM distribution.

Reuse seam: execution mode or a whole session subsystem if product scope changes. Cost: [LangChain, PubSub, Ecto; optional Phoenix/Horde](https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/mix.exs), conversational lifecycle, generated host code. Borrow scope rehydration and drain contract now; avoid adopting UI/session infrastructure for headless receipt work.

### 6. Synapse — persistence is real; resumable ownership is not established

**Claim (S, high):** [Postgres adapter](https://github.com/nshkrdotcom/synapse/blob/bc43df9671b1e4974054e1ce0109f3e37733e9f4/lib/synapse/workflow/persistence/postgres.ex) stores snapshots via `Synapse.Repo`, with conflict replacement by `request_id`. This is neither tenant-scoped acceptance nor an owner-fenced commit. [Engine source](https://github.com/nshkrdotcom/synapse/blob/bc43df9671b1e4974054e1ce0109f3e37733e9f4/lib/synapse/workflow/engine.ex) initializes fresh results/completed sets in `execute`, persists pending state, evaluates ready steps sequentially, and emits telemetry/audit data.

The [workflow guide](https://github.com/nshkrdotcom/synapse/blob/bc43df9671b1e4974054e1ce0109f3e37733e9f4/docs_new/workflows/engine.md) calls pause/resume a future implementation. **N:** automatic continuation, deployment compatibility enforcement, multi-replica ownership. Do not elevate the README's persistence claim into those guarantees.

Reuse seam: workflow spec/audit concepts, not adoption of its whole signal runtime. [Manifest](https://github.com/nshkrdotcom/synapse/blob/bc43df9671b1e4974054e1ce0109f3e37733e9f4/mix.exs) includes Jido packages, Ecto/Postgrex, Bandit, DNS clustering, LineageIR, Work, and optional Altar.AI: a much wider integration surface than the initial workflow. Generic signal-bus orchestration is misaligned with Knotra's no-general-event-mutation-bus decision. **I, medium confidence:** lowest-priority adoption candidate among the closest six.

## Remaining seven: category and relevant overlap

| Project | Primary evidence and comparison | Knotra action |
|---|---|---|
| A2A | **D:** [README](https://github.com/actioncard/a2a-elixir/blob/ea71190bf7992c27670f68d40358e5741af49646/README.md) confirms GenServer agents, JSON-RPC/SSE, skills registry, fleet supervisor, ETS-backed TaskStore seam, and task access callback. Protocol task state is not automatically a durable background harness. | Defer to a host protocol adapter if remote-agent interoperability is required. Do not confuse protocol “skills” with learned/persistent agent skills. |
| A2UI | **D:** [README](https://github.com/actioncard/a2ui-elixir/blob/115041255656d753139f08f8626d56dc123583d2/README.md) confirms v0.9 JSONL, native LiveView components, two-way bindings, actions, and transport behaviours. | Not a harness competitor. Defer UI adapter; no Phoenix renderer in core. |
| Bazaar | **D:** [README](https://github.com/georgeguimaraes/bazaar/blob/ce659ed81551a37f3137a68e652af4c2d855f0fa/README.md) supports UCP commerce endpoints, merchant callbacks, idempotent protocol replay, signatures, and host storage. ACP is in progress, not established full support. | Defer unless host exposes commerce protocols. HTTP idempotent replay is not execution ownership or exactly-once charging. |
| BeamWeaver | **D:** [composition guide](https://github.com/caudena/beam_weaver/blob/7d115a651aea6e0575c814e667114c5f17f504e7/docs/agent_harness.md) uses one agent/graph runtime with opt-in planning, tools, filesystems, HITL, skills, memory, subagents. [README](https://github.com/caudena/beam_weaver/blob/7d115a651aea6e0575c814e667114c5f17f504e7/README.md) claims Ecto checkpoints, pending writes, replay transports and redaction. No ownership/security audit performed. | Broadest emerging feature-bundle threat. Borrow positive capability declarations; require focused source validation before recommending adoption. |
| Jido.AI | Covered separately in identity table and jointly with Jido above: AI/model/reasoning layer, not synonymous with the core runtime. | Standalone runtime experiment before adopting full agent topology. |
| LangChain | **D:** [README](https://github.com/brainlid/langchain/blob/d113a009122069bd8f04c1fe18174d40ac0f18b9/README.md) explicitly rejects Python/JS parity and documents ReqLLM and provider integrations. [Evaluation guide](https://github.com/brainlid/langchain/blob/d113a009122069bd8f04c1fe18174d40ac0f18b9/guides/evaluation.md) distinguishes outcome, tool trajectory, and LLM-judge evaluation. | Viable loop/component substrate, especially with Sagents. ReqLLM adapter weakens any claim that Knotra uniquely combines Elixir orchestration and ReqLLM. No complete durable admission/fencing established here. |
| SwarmEx | **D:** [README](https://github.com/nrrso/swarm_ex/blob/596f6eb37289d6414bc21ea0e53ea3640df8983a/README.md) supports lightweight orchestration, tools, and telemetry. Registry's latest release is from 2024. | Do not prioritize over more directly evidenced candidates; current provider compatibility and durable semantics remain N, not proven absent. |

## Cross-cutting guarantees: what overlaps, what remains unverified

| Dimension | Evidence-backed overlap | Implication for Knotra |
|---|---|---|
| Replaceable behavior | Jido strategies/storage; Sagents execution modes; Alloy providers/middleware; LangEx nodes/checkpointers; Legion sandboxes/stores | “Plugins” and “replaceable loop” are not differentiation. No inspected package establishes interchangeable admission, fencing, recovery and evaluation with one enforced safety contract. |
| Embedding/headless | Alloy function loop, LangEx function graphs, Jido.AI standalone runtime, Legion embedded tools, Synapse headless runtime | Embedded Elixir/OTP is crowded positioning. Processes should remain a runtime choice, not one per plugin. |
| Durability/recovery | LangEx successful-task journal replay; Legion turn/step snapshots; Jido storage/tokens; Sagents conversation restore; Synapse snapshot/audit records | Specify the exact recovery boundary, acceptance transaction, and partial-effect window. Persistence is neither scheduling nor exclusive ownership. |
| Deployment compatibility | Jido.AI token config fingerprints; Sagents versioned serialization and host drains | Pinning and compatibility checks are not novel individually. Record composition IDs/versions; keep credentials outside; block incompatible resumes visibly. |
| Replica ownership | Jido journal optimistic revisions; Legion/LangEx/Synapse inspected upsert paths; Sagents optional Horde | No reviewed evidence proves the full requested database-only lease/epoch/stale-owner contract. This is an unresolved candidate gap, not a universal feature-absence claim. |
| Tenant safety/HITL | Jido partitions; Sagents caller scopes and approvals; A2A task authorization; LangEx interrupts; Legion tool bridges | Authorization must happen inside the host tool boundary on every call/resume. Model arguments, partition names and human approval alone are not authority. Initial output remains a proposal, not a send/payment. |
| Budgets | Alloy turn/spend checks and retry deadline; Jido.AI iterations/tool concurrency/timeouts; LangEx call/retry policies; Sagents call budget; Legion evaluation resource limits | Separate spend estimate, model output-token limit, execution deadline, admission concurrency, and retry/turn counters. Persist aggregate counters across recovery; do not promise a hard invoice cap without reservation/accounting. |
| Records/telemetry/evaluation | Telemetry is common; LangChain trajectory evaluation and Alloy/Jido scripted responses already exist | Keep production execution records, operational telemetry, fixed-output model+tool replay, and fresh-model scenario evaluation separate. Scripts that still run real tools are not isolated replay. |
| Cache meaning | Alloy/LangChain provider prompt caching; LangEx node cache and storage blob deduplication; BeamWeaver model/cache/replay surfaces | Prompt-prefix caching is not answer caching; journal replay is not memoization; blob deduplication is not model-result reuse. Keep answer/tool/projection cache deferred. |
| Retention/privacy | Sagents omits code-defined config/scope from persisted state; Jido.AI supports redaction options; LangEx documents encryption | No inspected evidence proves Knotra's exact host-controlled sensitive-data lifecycle. Encryption is not authorization or deletion. Keep credentials out and sanitize evaluation fixtures explicitly. |

These comparisons are interpretation of the individually linked evidence, not verified interoperability or performance results.

## Ranked reuse / borrow / defer decisions

1. **NOW — avoid a framework dependency until the deterministic pipeline stops holding.** Host email trigger → durable accepted execution → authorized read-only receipt lookup → ReqLLM draft → proposed reply. Seam: model and tool behaviours. Cost: own execution contracts; benefit: no graph/session/sandbox machinery. A tool-selecting loop is optional for this first workflow, not a prerequisite. **I, high.**
2. **NOW — compare Alloy adapter with the minimal ReqLLM loop.** Seam: Knotra loop interface, provider/message translation, authorized tool wrapper. Acceptance criterion: checkpointable step outcomes and kernel-controlled boundaries without a fork. Cost: duplicated provider concepts if ReqLLM stays, and adapters/tests. Reject adoption if the opaque loop forces unsafe persistence hooks. **I, medium.**
3. **NOW — borrow Jido's executable conformance-suite approach and stable strategy snapshots.** Seam: plugin certification for persistence, ownership, admission, loop outcomes. Costs: focused tests, not a universal plugin registry. Each adapter must prove stale writes fail and durable acceptance survives process death. This directly protects substitutability. **I, high.**
4. **NOW — borrow Sagents' fresh authorization scope and explicit drain sequencing.** Seam: host-auth resolver, state serializer, admission close/drain API. Cost: host deployment integration and clear compatibility metadata. Do not persist a caller's authority as reusable authorization. **I, high.**
5. **NOW — borrow LangEx's anchored successful-step journal idea, only as needed.** Seam: checkpoint/tool-result boundary. Cost: schema/ordering/error handling. For one receipt lookup, a small recorded step outcome may suffice; no generic graph engine is required. Preserve an explicit uncertain-effect state for future writes. **I, medium.**
6. **CONDITIONAL REUSE — Jido.AI standalone ReAct, then LangEx.** The former if several reasoning strategies or resumable loop tokens become requirements; the latter if durable branching/parallel HITL is required. Cost: action/config/token adaptation versus graph/checkpointer adaptation. One component owns recovery; do not stack competing recovery loops. **I, medium.**
7. **DEFER — Legion code execution; Sagents interactive stack; BeamWeaver deep-agent bundle.** Integration seams remain optional loop/runtime adapters. Add only when code batching, live sessions, or broader workflows justify their security and lifecycle costs. **I, high for deferral.**
8. **DEFER — A2A, A2UI, Bazaar, sensors, skills, memory, routers, factory-generated code, dashboards, connectors, Rust.** Host protocol/UI/trigger adapters can be added later. Current task does not require them. **I, high.**
9. **AVOID — a generic event mutation bus, unreviewed default filesystem/shell tools, auto-resuming incompatible state, unfenced upserts presented as ownership, and “exactly once” claims for external effects.** Events may observe; only explicit validated kernel contracts change lifecycle/authority. Trusted plugins can be buggy: replacing behavior must not allow bypassing tenant scope, deadlines, owner epoch, or lifecycle validation. This is contract protection, not a sandbox against malicious in-VM Elixir code. **I, high.**

## Build versus adopt, differentiation, and threats

**Adopt wholesale** if requirements change toward graph-centered workflows (LangEx), autonomous teams/strategies (Jido/Jido.AI), interactive sessions (Sagents), or in-app generated-code execution (Legion). These packages would avoid substantial reinvention in their respective domains.

**Build a small control layer** if the non-negotiable product requirement remains durable, tenant-authorized, database-owned background executions with host retention policy and plugin-neutral lifecycle contracts. Extend/reuse model and loop components inside it. Research does not establish that any candidate removes this layer without additional verification and adaptation.

**Evidence-backed competitive reality:** embedding, OTP, pluggable strategies, Postgres/host Repo integration, approval gates, budgets, tracing, configuration fingerprints, and deterministic model stubs already exist. Do not market those individually as novel. Legion directly occupies embedded business-operation agents; Jido overlaps broad replaceability; LangEx overlaps durable execution; Sagents overlaps factory/session/scoped persistence; BeamWeaver threatens feature-bundle breadth.

**Intended combination only:** narrow kernel + isolated execution + pinned composition + tenant-scoped durable acceptance + replica-fenced database ownership + compatible recovery/blocking + separated record/replay/evaluation and host retention. It may become useful differentiation, but currently there is no implementation or comparative fault-injection evidence.

**Unverified differentiation:** “safer,” “more durable,” “lighter,” “production-ready,” better throughput/cost, stronger privacy, easiest plugin replacement, and superior recovery. No benchmarks or exhaustive competitor security audits support those claims. An adapter layer around an existing runtime may remain the cheapest successful outcome.

## Only design decisions newly worth reopening

1. **Is an autonomous loop needed in milestone one?** The fixed read/lookup/draft path may need only ReqLLM plus authorized host functions. Retain the loop seam, not premature loop complexity.
2. **Loop implementation source:** compare Alloy/Jido.AI adapters before writing provider/tool-loop mechanics. Compatibility with the already-agreed ReqLLM seam is a cost to measure, not a reason to assume custom code wins.
3. **Exact plugin authority boundary:** clarify which kernel invariants cannot be replaced. Admission/ownership plugins implement protocols, but the kernel must require the accepted identity, owner epoch and validated lifecycle outcomes. “Everything replaceable” cannot mean “every safety check optional.”
4. **Compatibility granularity:** Jido.AI fingerprints and Sagents current-code restore illustrate different policies. Decide which model/tool/prompt/plugin changes invalidate a checkpoint, and which migration explicitly certifies compatibility. Avoid blanket “same version” or “restore anything” rules.

No new evidence justifies reopening database-only replica ownership, host-owned triggers, read-only initial tools, no exactly-once external guarantee, or the deferred UI/memory/codegen scope. ADR files were not explored or altered; these are proposals against the supplied agreed design, not claims about an inspected ADR.

## Contradictions and cautions

- **Bazaar:** supplied lead says UCP/ACP; primary README says ACP is in progress. Treat as UCP implementation with unfinished ACP scope.
- **Alloy budget:** README's stronger prevention wording versus source's accumulated-cost check; do not promise no overspend from that check.
- **Alloy runtime wrapper:** search discovery describes `alloy_agent`; inspected README says not yet on Hex. Registry publication of that separate package was not checked.
- **LangEx repository names:** discovery uses Fresha while Hex/README refer to Surgeventures. Commit pin records inspected content; verify canonical redirect before automation.
- **Jido recovery:** standalone resumable tokens and Agent snapshot sanitization have different semantics; neither cancels out the other.
- **Sagents persistence:** excluding behavior config protects secrets but does not freeze prior behavior; that differs from Knotra's intended pinned execution.
- **Synapse:** persistence is implemented; inspected guide describes pause/resume as future. Do not silently upgrade the claim to durable continuation.
- **Documentation lag:** BeamWeaver README installation example says 0.1.19 while Hex reports 0.1.30; LangChain README says 0.9.0 while Hex reports 0.14.3. Default-branch source and published package may differ.

## Licensing

The table records publisher-declared licenses, not a legal opinion or complete dependency-license audit. Inspected Jido.AI `LICENSE` and `LICENSE.md` both contain Apache-2.0. Before copying code, inspect the exact file/commit license and notices, including dependencies and any third-party material.

MIT generally requires retaining copyright and permission notices in substantial copied portions. Apache-2.0 generally adds license/notice and modification-marking obligations and patent terms. Studying architectural ideas and independently implementing them is different from copying implementation or documentation; neither is a blanket guarantee against all IP issues. Prefer dependency reuse or independently written small implementations; keep provenance for adapted tests/code. Seek legal review for actual redistribution questions. No code was copied into Knotra in this research.

## Missing evidence and next steps

- No candidate was installed, compiled, benchmarked, or fault-injection tested. No complete transitive dependency, security, license, maintainer responsiveness, or production-adoption audit was performed.
- A full stale-owner/fencing protocol, admission durability, tenant authorization through every tool path, and effect recovery semantics remain unverified across candidate integrations. Missing evidence is not proof of absence.
- Default-branch features must be checked against an exact chosen release. Jido's stable/prerelease split and rapidly evolving Sagents/BeamWeaver merit particular attention.
- BeamWeaver's wide durability/replay claims need targeted source/tests if it enters the shortlist. SwarmEx needs a current-provider smoke test before adoption.
- Confirm privacy behavior under exceptions/provider error payloads and checkpoint serialization; configuration omission alone is not credential-leak proof.

**Most useful next step:** a separately authorized, bounded comparison of the plain ReqLLM pipeline and one Alloy adapter, with five checks: duplicate tenant request; crash after durable acceptance; old owner writing after takeover; incompatible deployment resume; replay with both model and tool effects disabled. If graphs are required, run the same contract checks around LangEx instead. Choose the smallest candidate that passes, not the one with the longest feature list.

## Sources retained and deprioritized

**Kept:** the thirteen project repositories/commit snapshots and thirteen Hex API responses in the identity table; exact source/guides/tests linked in each finding. They establish identity, release provenance, concrete extension seams, and the limits of persistence/recovery claims. Highest-value evidence: Alloy `Turn`, Jido `Strategy`/`Storage`, Jido.AI checkpoint and standalone-runtime docs, LangEx `Journal`/durability tests/Postgres, Legion `Recovery`/Postgres, Sagents mode/serializer/deployment docs, Synapse engine/Postgres.

**Rejected/deprioritized:** search-result prose as final evidence; `lukaszsamson/a2a_ex` as the identity for this specific A2A lead; unrelated Synapse coding-assistant/registry projects; Python/JS LangChain and LangGraph as evidence for Elixir behavior; promotional benchmark/cost-saving language without measurements; architectural TODO/ADR prose when inspected runtime source gives a narrower guarantee. Supplied DeepSeek/Pi/Hermes findings remain background, not independently revalidated comparative evidence in this pass.
