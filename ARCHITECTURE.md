# Knotra architecture: background and interactive agents

Status: agreed direction. The milestone-1 non-durable background path and the opt-in Ecto/SQLite approval demonstration are implemented; neither provides production ownership/recovery certification.
This document records current implementation boundaries and approved future branches, not authorization to implement those branches or a delivery commitment.

Knotra is an embedded agent harness for both autonomous background work and user-interactive workflows. The host application owns identity, channels, and business authority; Knotra coordinates bounded execution. These workflows share safety and lifecycle rules without requiring the same loop strategy.

## Reading and status

- [CONTEXT.md](CONTEXT.md): canonical domain vocabulary, not implementation details.
- [README.md](README.md): non-durable embedding guide and current limitations.
- [Durable approvals](docs/durable-approvals.md): implemented opt-in APIs, recovery safe points and SQLite test evidence.
- [Integrated approval validation](docs/approval-validation.md): executable acceptance mapping, authenticated-responder provenance and bounded proof; no production certification.
- [ADR 0001](docs/adr/0001-ecto-sqlite-persistence.md): approved Ecto/SQLite dependency exception and host-owned persistence.
- [Milestone-1 design](docs/design.md): original implementation scope and constraints.
- [Historical alternatives research](docs/research/elixir-agent-alternatives.md): broader comparison, not current implementation evidence. Its “generated hello code only” statement predates milestone 1.

**Implemented** means present in the repository; **planned** means agreed behavior that still needs implementation and acceptance tests; **exploratory** means a branch with unresolved implementation choices. Future API names, schemas, and storage transitions below are conceptual, not existing functions.

This architecture broadens the background-only product scope in the original design. [ADR 0001](docs/adr/0001-ecto-sqlite-persistence.md) already supersedes the ReqLLM-only restriction specifically for optional Ecto/Ecto SQL and test-only SQLite; a SQLite host supplies its runtime adapter. Other dependencies and framework adoption still require owner authorization. This documentation adds no runtime capabilities. No new ADR is required merely to enumerate future branches; record a separate ADR when selecting a costly-to-reverse integration or isolation mechanism.

## 1. Current execution paths — implemented

The existing non-durable path remains read-only:

```text
host input + trusted authorization context + agent definition
  → Knotra.start/5 → supervised temporary execution process
  → loop requests model/tool operations
  → core checks lifecycle, pending calls, limits and deadline
  → model adapter OR default tool runtime
  → in-memory record → observer → next operation or terminal result
```

The separate opt-in approval demonstration uses a host-owned Repo and trusted access policy:

```text
Knotra.submit/6 → committed acceptance + stable identity
  → model proposal → validated/authorized pending approval → worker exits
  → restart → host-authorized inspection/recovery of the same request
  → Knotra.answer/5 → guarded, explicitly allowlisted fake operation
  → committed result → supported continuation or visible blocked outcome
```

Implementation anchors:

| Boundary | Evidence | Limitation |
|---|---|---|
| Non-durable execution | [Knotra](lib/knotra.ex), [Execution](lib/knotra/execution.ex) | `start/5` returns a local handle; retained terminal handles consume capacity. This path has no restart recovery. |
| Durable acceptance and approvals | [Durable coordinator](lib/knotra/durable.ex), [persistence](lib/knotra/persistence.ex), [public contract](docs/durable-approvals.md) | Stable tenant-scoped identity, committed pending/decision state and worker-free waits; SQLite demonstration, not distributed ownership. Pending admission is bounded only when `max_pending` is configured. |
| Replaceable behavior and recovery | [Contracts](lib/knotra/contracts.ex), [default loop](lib/knotra/loops/default.ex), [checkpoints](lib/knotra/checkpoint.ex) | Non-durable loop/model/tool-runtime/observer substitution remains supported. Durable restoration supports the default loop/runtime and compatible checkpoint-capable models, not arbitrary plugin state or conversation recovery. |
| Host operations | [Default tool runtime](lib/knotra/tool_runtimes/default.ex) | Validate → authorize → execute. `start/5` remains read-only; durable dispatch requires an unchanged approval, fresh authorization and explicit fake-tool allowlisting. No production consequential-operation support. |
| Models | [ReqLLM adapter](lib/knotra/models/req_llm.ex) | Text and local tool calls, including compatible durable continuation; no audio or generated-UI contract. |
| Inspection | Public snapshots and observer; [durable contract](docs/durable-approvals.md) | Non-durable records are in-memory; durable records are queryable after restart. Neither snapshots nor best-effort observer delivery replace private recovery checkpoints. All may contain sensitive content. |

Supported contracts constrain trusted plugins; arbitrary in-VM Elixir can bypass those contracts. Declaring a tool read-only or allowlisting a fake tool is not a sandbox. Durable compatibility is pinned to the definition/composition and checkpoint format; incompatible work blocks visibly. Interrupted model calls are not replayed. Uncertain effects retry only through explicit recovery with a pinned reliable operation-ID contract, current authorization and remaining budgets; otherwise they remain blocked. Killing a task cannot roll back a remote effect or reliably stop independently spawned work.

## 2. Ownership and composition — agreed direction

| Knotra owns | Host application owns |
|---|---|
| Execution identity, lifecycle validation, dispatch, aggregate budgets and cancellation | Authenticated users, tenant scope, authorization policy and business operations |
| Pending interaction identity, answer correlation and lifecycle | Who may answer, notification delivery, UI/audio transport and rendering |
| Recorded operation boundaries and recovery contract | Persistence integration, deployment wiring, retention and access policy |
| Validation of presentation requests and capability requirements | Approved UI components and speech/model provider choices |
| Code-executor contract and mediated host-operation requests | Provisioning approved isolation backends and granting resources |

“Everything is a plugin” means replaceable capabilities, not optional authorization or a process per capability. Keep a narrow kernel; introduce behaviours only when implemented. One component owns recovery for an execution. Do not stack a second harness's recovery loop underneath it without resolving ownership.

Channels are adapters, not authorities. A UI event, transcript, generated program, model argument, or conversation identifier cannot supply a trusted tenant scope. Host checks remain authoritative before every consequential operation and after every wait or recovery.

## 3. Design branches

```text
execution
├── autonomous background
│   ├── model/tool loop [implemented, read-only, non-durable]
│   └── bounded delegation and swarms [planned]
├── human interaction
│   ├── input request → answer → continue same execution [planned]
│   ├── approval → approve / reject / expire / pre-admission cancel [implemented, opt-in fake-operation slice]
│   └── takeover → stop new agent operations → explicit handback [planned]
├── presentation [planned]
│   ├── structured agent-to-UI requests
│   └── voice-only
│       ├── recorded voice messages and spoken replies
│       └── live audio with interruption [exploratory]
└── generated code
    ├── restricted computation → proposed host operations [planned]
    └── general-purpose shell/files/network in external isolation [exploratory]
```

These axes compose: a voice conversation can initiate background work that later requests approval. A UI need not remain connected while work runs. Absence of a human does not grant autonomous permission.

### Conversation versus execution

A conversation contains interaction history and may span multiple executions. Each execution represents one accepted work request with its own identity and limits. An answer to a pending request continues that execution; an independent request starts another. Conversation history is context, not reusable authority or proof that an earlier operation completed.

No conversation store or cross-execution history-ordering/merge contract is implemented. A later scoped design must define append ordering, concurrent submissions, duplicate delivery and where resumed outputs join the history. An execution's ordered events do not establish an order across executions; neither observer arrival nor token-stream arrival may be assumed authoritative.

### Autonomous work, delegation, and swarms — planned

An unattended agent can act only within host-granted capabilities. Child work shares the root execution's aggregate budget and cancellation scope; delegation cannot expand authority or reset counters. A required human decision creates a wait even when no channel is connected.

The agreed swarm direction is independently supervised executions with a shallow, bounded delegation hierarchy. Parent/child relationships track responsibility, not nested OTP supervision. Authorized peers may communicate directly. Reuse the existing execution GenServers, Task.Supervisor and DynamicSupervisor; a small coordinator GenServer per swarm owns admission, budget reservations and child tracking, not all message traffic. No separate process per inbox or topic is required.

Worker failure is isolated by default: unrelated executions continue and the failed work remains inspectable. The root execution cannot report successful completion while required work is failed, blocked or incomplete. Root-wide cancellation, deadlines and shared-budget exhaustion still prevent new dispatch across the swarm; failure isolation does not bypass those limits.

Each swarm has one logical shared board for findings, decisions and artifact references, plus an inbox addressed to each execution for assignments, questions, replies and handoffs. Board content is organized by topic/task and retrieved selectively; do not broadcast every post into every model context. Task ownership and completion are authoritative state, not inferred from messages. Normal inbox messages enter model context at defined turn boundaries; cancellation remains a runtime lifecycle operation.

Accepted swarm work, shared-board posts and inbox messages must survive a host restart. Use the host-owned Repo for task/parent-child identities, queued/runnable state, shared-budget reservations and consumption, board entries, inbox entries and consumption markers, and compatible execution checkpoints. Acknowledge work acceptance or message posting only after commit. A BEAM mailbox is not a durable inbox; process notifications are wakeups, not authoritative state. Address messages by stable execution identities and define acknowledgments and duplicate-safe consumption without claiming exactly-once delivery.

Recovery restores compatible safe checkpoints, prior budgets and existing child identities under fresh host authorization. Never blindly repeat an uncertain operation: use its proven idempotency contract or visibly block for reconciliation. Host authorization governs board/inbox access and tenant/swarm isolation; messages never grant tool authority. Bound delegation depth, spawning, queues, inbox/message sizes and notification fanout. Swarm membership and simultaneous model calls need separate limits.

The capacity requirement is hundreds of simultaneous model calls, not merely hundreds of swarm members. This is a target, not an implemented or benchmarked capability. Model admission must distinguish in-flight concurrency, provider request/token quotas and shared root budgets; execution-count limits alone are insufficient. Quota scope follows the host's provider/account/model configuration and may span multiple swarms. Model I/O remains in supervised tasks, never inside coordinator callbacks. Validate HTTP pool capacity, context/continuation memory, coordinator responsiveness and storage contention under concurrent load before claiming support.

When model-call capacity or provider quotas are exhausted, work waits in a bounded, cancellation-aware queue with fair admission across swarms sharing the quota scope. Reject new work explicitly when the queue is full. Queued work does not hold an in-flight model-call permit. Persist queue admission before acknowledging accepted swarm work and preserve queue bounds across recovery. This is planned swarm behavior, not a change to current `start/5` capacity rejection or non-durable acceptance.

Before implementing concurrent children, budget reservations and parent/child recovery must prevent simultaneous overspend and duplicate dispatch. A replayed parent must not blindly recreate children. Required-work designation, retry/escalation policy, the exact concurrency target, queue bounds/wait deadlines, fairness algorithm, checkpoint/message formats, message ordering/acknowledgment details and retention policy remain open. Hundreds of simultaneous calls alone do not select multi-node deployment or supersede the SQLite-first decision in ADR 0001; expand infrastructure only against measured constraints.

## 4. Durable interaction lifecycle — implemented approval subset, planned expansion

The [opt-in approval contract](docs/durable-approvals.md) implements durable acceptance, waits, answers, pre-admission cancellation, expiry on access, preserved allowances and compatible safe-point restoration. It also supports [explicit idempotent fake-effect recovery](docs/durable-approvals.md#explicit-recovery-of-uncertain-fake-effects), not general interrupted-work replay. Clarification, takeover and distributed ownership remain unimplemented.

The expanded lifecycle below is conceptual, not a list of current Elixir status atoms:

```text
accepted work → runnable → active → completed / failed / cancelled
                           │
                           ├→ waiting for input or approval → runnable
                           │                              └→ rejected / expired outcome
                           ├→ human control → explicit handback → runnable
                           └→ blocked for reconciliation or incompatible recovery
```

Waiting is recorded durably before acknowledging that the interaction exists. It releases active execution capacity; it does not require a live process per waiting user. The implemented `max_pending` option bounds all outstanding durable records in the configured Repo, including blocked work; its default is `:infinity`, so hosts must configure a bound when required. Terminal-history retention remains host-owned. A separate human-response deadline governs waiting; active-work allowances and aggregate counters do not reset on resume. Silence never approves. Expiry is currently materialized on authorized lifecycle access, not by a background sweeper.

An interaction records enough information to recover the question and validate an answer: execution and interaction identity, request version/kind, tenant binding, proposed operation and validated arguments where relevant, expiry, decision provenance, and disposition. Credentials and captured authorization closures are not durable authority. The implemented approval schema and serialization are documented in the [durable contract](docs/durable-approvals.md); future interaction kinds still need scoped formats.

**Implemented responder audit:** the host returns a nonsecret authenticated responder reference for answers; the same conditional write records it with the decision in the snapshot, checkpoint and answer receipt. Duplicate delivery and recovery preserve the winning identity, never restore its authority. See the [audit follow-up](docs/approval-validation.md#responder-audit-follow-up) and [rollout limits](docs/durable-approvals.md#responder-audit-rollout).

### Checkpoints versus snapshots

Public snapshots expose inspectable outcomes, not the private state needed to continue a model exchange. Observer notifications are best-effort copies, not durable truth. Private versioned checkpoints preserve the accepted input, loop position, full provider continuation, pending operation, consumed budgets and remaining active allowance. Configuration credentials, live handles and reusable host authority are excluded; input and model content can still be sensitive. `checkpoint/3` requires separate host permission and is not a frontend payload or an untrusted upload format. See [safe points and recovery limits](docs/durable-approvals.md#safe-points-and-recovery-limits) for the current format, compatibility rules and supported restoration boundaries.

### Answers and authority

On answer, validate authenticated responder permission, tenant, execution, current request version, expiry, and lifecycle. Accept one decision atomically. Duplicate delivery cannot cause another effect; conflicting or stale answers are rejected. Late answers after cancellation, expiry, or supersession cannot revive work. Rehydrate current host authority before resuming.

Input, approval, rejection, and takeover are distinct:

- **Input** supplies information, not permission.
- **Approval** binds to one operation and its arguments; changes invalidate the approval. It is necessary only where host policy requires it, and never sufficient without business authorization.
- **Rejection/expiry** cannot dispatch the proposed operation. The implemented demonstration ends the attempt; a future revised-proposal policy needs an explicit scoped design, not implicit approval.
- **Takeover** stops new agent operations until explicit handback. Dispatch and takeover need an ordered boundary; already-dispatched work may finish. Corrections affect future work, not recorded history.

Production recovery retains the existing requirements: durable acceptance before acknowledgment, tenant-scoped submission deduplication, database-coordinated ownership with stale-owner rejection, recorded step boundaries and aggregate budgets, and pinned composition compatibility. A redeploy may recover compatible work; incompatible work becomes visibly blocked. Supervision alone provides none of these guarantees.

### Effect safety

The planned production operation path extends the existing guarded fake-operation boundary rather than adding a bypass:

```text
validate proposed arguments → check host policy → obtain approval if required
  → revalidate current authorization + approval binding + budget + ownership
  → record dispatch intent → perform operation → record outcome
```

Recording intent does not make a database transaction atomic with an external service. If a remote effect succeeds but its result is lost, retry only under a reliable operation-specific idempotency contract with the same operation identity. Otherwise block for reconciliation. Cancellation, timeout, takeover, and approval do not promise rollback or exactly-once effects.

## 5. Agent-to-UI and voice-only workflows

### Structured UI — planned

The agent proposes validated questions, forms, choices, progress, and results; the host renders approved components. Arbitrary HTML, scripts, and model-selected privileged callbacks are not the presentation contract. UI actions route through authenticated interaction handling, not directly to tools.

Reconnection rebuilds pending interactions from recorded state. Streaming tokens are optional presentation and not the source of truth. An incomplete stream must not leave a user approving only a tool name without its arguments. Competing devices use the same current request/version rules. Any replay cursor or delivery acknowledgment belongs to a concrete transport design, not an assumed guarantee of observers.

### Recorded voice — planned first audio branch

```text
host-authenticated voice message → speech input adapter → execution
  → response or pending interaction → speech output adapter → spoken reply
```

The complete workflow must be usable without a visual display. Before a consequential approval, read back the action and critical details, such as recipient and amount. Require explicit confirmation correlated to that pending action; an ambiguous “yes,” stale reply, changed proposal, or interrupted confirmation does not approve. Voice recognition is not identity verification.

Audio/transcripts are untrusted input and may contain sensitive data. The host defines storage, redaction, deletion, and provider disclosure. A text adapter does not establish support for native audio models; either approach needs a capability declaration and separate tests.

### Real-time voice — exploratory

Live audio adds partial utterances, endpoint detection, speech playback, barge-in, and reconnect ordering. Partial transcripts cannot authorize effects. Interrupting speech output is not necessarily cancelling an execution; the adapter must distinguish those intents and confirm ambiguous commands. Already-started external effects remain subject to reconciliation.

Streaming protocol, latency targets, audio providers, and acceptable confirmation-error thresholds remain open until an audio slice is chosen. Do not present message-based speech support as proof of real-time correctness.

## 6. Generated code and Legion

### Restricted computation — planned

Initial shape: bounded generated computation over explicitly supplied data produces results and proposed host operations. Those operations return through Knotra's validation/authorization/approval/recording path. No direct database credentials, unrestricted host module access, filesystem, or network are implicit grants.

Do not promise serialization of a running language VM across human waits. Record computation results/proposals and continue at harness operation boundaries. Later mediated read bridges, if needed, must consume the same tool budgets and scope checks as ordinary tools. One code evaluation must not hide a thousand uncounted host calls.

Language, executor, conversion rules, and resource controls are not selected. Before adoption, test malformed arguments, result-size limits, CPU/memory exhaustion, secret leakage, and isolation failure. Approval of a snippet is not approval of dynamically generated business operations.

### General-purpose execution — exploratory

Shell commands, package installation, arbitrary languages, files, and network require an approved isolation boundary outside the host BEAM. External execution alone is not sufficient: specify filesystem, network, credentials, resource quotas, process-tree teardown, artifact transfer, and tenant isolation. Missing or insufficient enforcement fails closed rather than silently granting full access.

No container, VM, remote service, or Legion dependency is selected. This branch needs a concrete threat model and security acceptance tests before implementation.

### What Legion establishes—and does not

The inspected Legion code provides Lua execution in an Elixir VM and Elixir evaluation behind AST checks. Both built-in sandboxes share the host BEAM; exposed tools run with host privileges. Its pre-evaluation `EvalGuard` is an allow/deny callback, not a durable human wait. Its runner offers evaluation limits, but these do not establish whole-node or external-effect containment. Borrow explicit tool bridges and resource controls, not an assumption that “sandbox” means hostile-code isolation. Sources: [sandbox guide][legion-sandbox], [Lua bridge][legion-lua], [Elixir evaluator][legion-elixir], [runner][legion-runner], [EvalGuard][legion-guard].

## 7. Comparative design discipline

For each future capability, compare **DeepSeek Harness first**, then the most relevant Elixir and non-Elixir alternatives. Record the exact contract, primary source/version, reuse cost, and Knotra acceptance scenario. A feature list is not evidence of safety, performance, or durability. Missing evidence means unverified, not absent. Existing package adoption still requires dependency authorization.

| Reference | Evidence-backed overlap | Boundary Knotra must test |
|---|---|---|
| **DeepSeek Harness** — primary inspiration | [Plugin architecture][deepseek]; [agent API][dsh-agent] documents sessions, follow-up/steering/cancellation and durable inbox. [Approvals][dsh-approval] fail closed without an answerer and discard aborted late answers. | Documented approval requests require an open turn; durable out-of-turn approval is deferred. Session persistence does not establish crash-surviving human waits. |
| **DeepSeek interaction and sandbox contracts** | [Channel-neutral interaction packages][dsh-interaction]; [approval subsystem][dsh-approval-detail] correlates approval `callId` with previously presented arguments. [Sandbox][dsh-sandbox] specifies same-host file confinement. | A reconnecting/voice client must reconstruct the action binding. File confinement does not establish network/process/syscall/device/credential restrictions; partial enforcement is possible. |
| **Legion (Elixir)** | Generated computation, host-tool bridges, evaluation guard and resource controls. | No hostile-code boundary outside the host BEAM; no established durable mid-snippet approval continuation. |
| **Sagents (Elixir)** | [README][sagents] documents tool approval/edit/reject, resume, child interrupt propagation and PubSub/LiveView interaction. | Pending-approval crash recovery, channel authentication/replay, and hostile generated-code isolation were not established in this inspection. |
| **LangGraph (Python)** | [Interrupts][langgraph-interrupts] use a checkpointer, thread ID and resume command; [streaming][langgraph-streaming] exposes state/tokens/custom data. | Resumption starts the interrupted node again: pre-interrupt effects may repeat. A persistent backend is needed for restart durability; streaming/checkpointing is not code isolation. |

These observations came from primary documentation/source inspection, not installed comparative tests or a security audit. DeepSeek references pin `639ed015397290b3745d163aafe02ffee4aa3f84`; Legion pins `b5d57d326d710b22a6321a9d6c59970a8d6a4bf7`; Sagents pins `5ff209c972cddece02fcebfe35cf1b7b2d1e1105`. LangGraph links are unversioned official docs. Default-branch/package equivalence and production guarantees are not assumed. No benchmark or superiority claim is made.

## 8. Scenario matrix and proof obligations

**Existing**: concrete tests cover the limited stated behavior. **Partial**: tests cover only the identified implemented subset. **Future**: specified acceptance scenario, not implemented or run. **Unresolved**: needs a selected backend/protocol or policy before an executable assertion can be finalized. Expansion cases supplement rather than inherit an existing row's coverage; fake-operation evidence is not production certification.

### Current evidence

| ID | Scenario and asserted outcome | Status / evidence |
|---|---|---|
| E1 | Sanitized email → authorized receipt read → proposed reply; no send operation; isolated ordered record. | Existing: `sanitized email → authorized receipt → proposed reply, with isolated recording` in [harness tests](test/knotra_test.exs). |
| E2 | Model selects another tenant, unknown tool, malformed arguments, duplicate call ID, or loop invents a tool request → no unauthorized host read. | Existing: authorization, malformed-call, invalid-loop and validation-result tests in [harness tests](test/knotra_test.exs). |
| E3 | Exhaust turns/tools/retries/steps; block provider; cancel or expire; queued result arrives late → limits hold and local task stops. | Existing: budget, cancellation, deadline and timer-ordering tests in [harness tests](test/knotra_test.exs). Not durable or delegated limits. |
| E4 | Kill execution → in-flight task dies without automatic replay; retain two terminal handles → capacity remains occupied until release. | Existing: process-death and capacity tests in [harness tests](test/knotra_test.exs). Not recovery coverage. |
| E5 | Replace loop/model/tools/observer; evaluate with fake model and fake tool effects; redact private failure state. | Existing: substitution, isolated-evaluation and credential-canary tests in [harness tests](test/knotra_test.exs). Not malicious-plugin containment. |
| E6 | Offline provider fixtures return incomplete calls, missing usage, or text-only continuation → fail closed where unsupported; unknown usage stays unknown. | Existing: [ReqLLM tests](test/req_llm_test.exs). Not live-model or audio evaluation. |
| E7 | Commit acceptance and pending approval → release worker → restart runtime/Repo or inspect from a fresh BEAM → recover the same identity/request without repeating model work. | Existing: [durable tests](test/durable_test.exs) and [SQLite test lifecycle](docs/durable-approvals.md#verification-and-sqlite-test-lifecycle), including failed commits and tenant-scoped deduplication. |
| E8 | Duplicate/conflicting answers, stale bindings, revoked authority and answer/cancel/expiry races → durable ordering fences dispatch; uncertain fake effects remain visible without blind retry. | Existing: [durable tests](test/durable_test.exs), using an independent fake-effect ledger. Explicit stable-ID recovery is tested against a reliably idempotent fake ledger; no real-write certification. |
| E9 | Sequential approvals, restart and capacity refusal → consumed allowances persist, compatible safe points resume, incompatible work blocks and configured admission limits hold. | Existing: [durable tests](test/durable_test.exs). Not distributed ownership, automatic queue draining or PostgreSQL parity. |

### Expansion acceptance traces

| ID | Given → intervention → required outcome | Status |
|---|---|---|
| F1 | Autonomous parent delegates → children collectively exhaust shared budget or parent is cancelled → no new dispatch or authority escalation; retain already-dispatched outcomes. | Future; concurrent reservation mechanism unresolved. |
| F2 | Agent needs clarification without connected user → save request, stop/restart host, then answer → same execution resumes with prior counters; waiting occupies no active slot. | Future. |
| F3 | Operation needs approval → approve, reject, expire, or edit arguments → only the approved unchanged operation may dispatch after fresh authorization; other paths never silently approve. | Partial: approval/rejection/expiry and changed-binding refusal are tested with fake operations; editing/reproposal remains future. |
| F4 | Crash before pending request commits, after it commits, or after answer commits → recover authoritative state without losing an acknowledged request or executing the decision twice. | Partial: pending/decision commit failures and restart safe points are tested; interrupted decisions conservatively block. Complete boundary validation remains [issue #9](https://github.com/stlucasgarcia/knotra/issues/9). |
| F5 | Two devices answer, old answer is replayed, wrong tenant answers, or authority is revoked while waiting → one valid current decision at most; all invalid answers/effects rejected. | Partial: public-interface answer races, stale bindings, tenant checks and revocation are tested; device/channel integration remains future. |
| F6 | Approval UI stream truncates, disconnects, then reconnects → reconstruct complete pending action from recorded state; no approval based solely on tool name. | Future; transport cursor protocol unresolved. |
| F7 | Human takes over while dispatch races → no operation ordered after takeover starts; disclose any earlier in-flight effect; explicit handback required. | Future. |
| F8 | Voice-only user requests operation → hear action readback → explicit current confirmation → identical approval/authorization boundary as UI, with no screen required. | Future. |
| F9 | Wrong recipient/amount transcription, ambient speech, stale “yes,” or interrupted readback → no approval; clarify and reconfirm corrected proposal. | Future; speech quality thresholds unresolved. |
| F10 | Live user interrupts playback during an operation → distinguish stopping speech from stopping execution; never claim an in-flight write rolled back. | Unresolved live-audio protocol; invariant agreed. |
| F11 | Remote effect commits, execution dies before recording result → reuse reliable idempotency identity or block for reconciliation; never blind retry. | Partial: the fake-service fork proves explicit stable-ID idempotent recovery or blocked reconciliation, without automatic retries. Real service contracts require separate proof. |
| F12 | Generated program attempts forbidden access, malformed output or excessive computation → deny/terminate within the chosen resource/isolation contract without leaking credentials. | Future; executor-specific attack corpus unresolved. |
| F13 | Generated program proposes many operations, or future bridge loops over host calls → each dispatched call consumes shared budget and policy checks; partial effects remain recorded. | Future. |
| F14 | External sandbox backend is absent/insufficient, or evaluator dies while child processes/remote calls run → fail closed; report actual surviving work rather than claiming containment. | Unresolved until backend selection. |
| F15 | Drain/redeploy during human wait; change composition or race old/new owner → compatible work recovers; incompatible work visibly blocks; stale durable writes fail; counters persist. | Partial: compatible pending recovery, incompatible checkpoints, revision fences and counters are tested; deployment draining and cross-instance ownership remain future. |
| F16 | UI proposal contains executable markup or unauthorized action; stale rendered form submits → renderer rejects unsafe content; host interaction boundary rejects invalid action. | Future. |
| F17 | Submit same tenant request twice, then same key in a different tenant → tenant-scoped durable deduplication before acknowledgment without cross-tenant disclosure. | Existing in the SQLite slice: [durable tests](test/durable_test.exs). No cross-backend or distributed-ownership certification. |

### How to turn scenarios into tests

Use the existing ExUnit/fake-model/fake-tool approach. Future deterministic tests should control clocks and inject failures at recording/dispatch boundaries, rather than rely on wall-clock sleeps or real business effects. Persistence adapters need crash/restart and concurrent-owner conformance tests; in-memory fakes cannot prove durability. Audio and sandbox implementations require their own integration checks after selection.

Keep three proof levels separate: deterministic harness behavior with model and tools stubbed; backend/transport/isolation integration tests; explicitly authorized live-model or audio-quality evaluation on sanitized scenarios. No future row becomes “covered” because a prose walkthrough succeeded, and replay must never invoke production tools.

Current baseline command: `mix test --warnings-as-errors`. It runs both the non-durable/ReqLLM suites and the SQLite durable suite covering E1–E9 and the identified expansion subsets; `mix test test/durable_test.exs --warnings-as-errors` runs the durable suite alone. These evidence references describe existing tests, not proof that every expansion trace is complete. This documentation change introduces no runtime tests; report actual command results separately.

## 9. Implementation order and deliberate open choices

1. Preserve the non-durable path and the implemented opt-in approval slice with their regression tests.
2. Complete the integrated real-storage acceptance matrix in [issue #9](https://github.com/stlucasgarcia/knotra/issues/9), preserving the implemented [narrow idempotent-recovery contract](docs/durable-approvals.md#explicit-recovery-of-uncertain-fake-effects). The Ecto/SQLite integration is already authorized by ADR 0001; further dependencies still require approval.
3. Only after that proof, select a scoped clarification/takeover or presentation slice; structured UI and recorded voice must preserve the same approval/authorization boundaries.
4. Add bounded delegation or restricted generated computation only with its shared-budget and failure tests.
5. Select live-audio and general-purpose isolation backends separately; do not pull their complexity into the first interactive slice.

This is sequencing guidance, not approval to implement those slices. The SQLite schema, conditional revisions, checkpoint format and optional pending-admission bound are already implemented. Remaining choices include distributed ownership/deployment protocols, PostgreSQL integration, conversation-history ordering, swarm scheduling, restart-safe swarm/message formats, message ordering/acknowledgment details and retention policy, UI wire schema, audio providers/protocol and quality thresholds, generated language/isolation backend, and operation-specific reconciliation. Future behavioral boundaries do not certify those integrations; each needs a scoped decision and evidence. No speculative behaviours, graph scheduler, frontend framework, or sandbox dependency are added now.

[deepseek]: https://deepseek.com/harness/en/
[dsh-agent]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/core/agent/README.md
[dsh-approval]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/interaction/user-approval/README.md
[dsh-approval-detail]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/docs/subsystems/approval.md
[dsh-interaction]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/interaction/README.md
[dsh-sandbox]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/sandbox/sandbox/README.md
[legion-sandbox]: https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/guides/sandboxes.md
[legion-lua]: https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/lib/legion/sandbox/lua.ex
[legion-elixir]: https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/lib/legion/sandbox/elixir.ex
[legion-runner]: https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/lib/legion/sandbox/runner.ex
[legion-guard]: https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/lib/legion/eval_guard.ex
[sagents]: https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/README.md
[langgraph-interrupts]: https://docs.langchain.com/oss/python/langgraph/interrupts
[langgraph-streaming]: https://docs.langchain.com/oss/python/langgraph/streaming
