# Restart-safe approval validation

Status: **bounded integration evidence; responder audit implemented**. This is the
evidence for [issue #9](https://github.com/stlucasgarcia/knotra/issues/9), against
[the parent spec](https://github.com/stlucasgarcia/knotra/issues/2).

The original 19-scenario validation at `ede28ef` passed within the SQLite/fake
scope, but found missing authenticated-responder provenance. The follow-up below
implements that contract and turns its diagnostic into a passing self-check.
The original results remain historical evidence, not the latest regression gate
or production certification. Parent closure remains the owner's decision.

## Scope and environment

Validated on 2026-10-07 with Elixir 1.20.4, OTP 29, Linux, Ecto 3.14.2,
Ecto SQL 3.14.0 and ReqLLM 1.24.0, using the locked test dependencies.
The original runtime under test was the implementation through `4b86301`;
`ede28ef` added validation-only checks. The responder-audit follow-up changes only
host-access result validation and the existing atomic decision record, with no
new dependency or database schema.

[ADR 0001](adr/0001-ecto-sqlite-persistence.md) authorizes this integration:

- Host-owned Ecto Repos, private unique directories under
  `_build/persistence-tests/`, on a writable local Btrfs filesystem.
- File-backed execution database and **separate** fake-effect ledger database;
  committed transactions, not `:memory:` or rollback-only Sandbox tests.
- The fixture configures WAL, `synchronous: :full`, foreign keys and a
  5-second busy timeout for both Repos, with two execution-Repo connections
  for competing transitions.
- Execution/Repo shutdown and reconnection to the same files, plus child BEAM
  invocations. The ledger survives independently; cleanup is scenario-owned.

Setup and controls are in [durable tests](../test/durable_test.exs) and
[the test host](../test/support/durable_fixtures.ex). D:1950, `SQLite durability
fixture uses committed WAL files and separate effect storage`, asserts effective
execution-Repo WAL, FULL synchronization and foreign keys only. The busy timeout
is configured, not asserted there; Exqlite's cancellation-aware handler reports
zero through `PRAGMA busy_timeout`. Effective ledger PRAGMAs are also not asserted.
Those configured settings remain unverified by this check. SQLite writer
serialization is not a PostgreSQL or distributed-ownership proof.

## Acceptance matrix

**PASS** below means the cited assertions passed in the historical 110-test run
at `ede28ef`, not that every production interpretation is supported.
`D:<line>` selects `test/durable_test.exs:<line>` with `mix test`; `K` selects
`test/knotra_test.exs`, and `R` selects `test/req_llm_test.exs`.
These selectors refer to `ede28ef`; use that revision for those exact locations.
Test names are the stable wayfinding aid in the updated tree.

| Parent scenario | Executable checks and asserted boundary | Result |
|---|---|---|
| 1. Existing non-durable behavior and read-only policy | Entire K/R suites; K:195 ordinary read-only work, K:252 tenant authorization, K:285 invented requests, K:227 forged non-dispatch result. | PASS |
| 2. Unsupported durable composition | D:1701 unsupported tool composition; refusal before acceptance. | PASS |
| 3. Acceptance only after commit | D:1757 failed acceptance, D:2008 lost committed acknowledgment, D:2135 caller killed before acceptance. No failed-write acknowledgment or effect. | PASS |
| 4. Tenant submission identity | D:1712 matching/conflicting/other-tenant keys; D:1908 normalized request matching. | PASS |
| 5. Pending → release worker → restart → same execution | D:47 ordinary restart/Repo reconnect, D:1662 stable pending identity, D:1851 fresh BEAM, D:1870 released capacity. | PASS |
| 6. Unchanged approval → one ordinary fake effect | D:47 and D:716; completed output, one independent ledger effect, continued model exchange. | PASS |
| 7. Reject/expire/cancel; late answers cannot revive | D:1640 rejection, D:858 cancellation, D:875 offline expiry, D:1119 fresh-BEAM lifecycle, D:358 terminal idempotent history. | PASS |
| 8. Duplicate/conflicting answers | D:509 eight answer contenders, D:978 approve/reject/cancel contenders; at most one committed disposition/effect. | PASS |
| 9. Stale/binding/permission/tenant refusal | D:487 exact arguments, request identity/version, host permission and tenant; D:897 cancellation isolation. Responder audit identity is a separate unmet requirement below. | PASS |
| 10. Revoked business authority | D:581 revocation after decision/intent, D:1499 fresh recovered authorization; no effect. | PASS |
| 11. Cancellation versus dispatch | D:905 cancellation wins before admission; D:926 admission wins and eventual result survives; D:949 uncertainty survives; D:978 concurrent race. | PASS |
| 12. Crash boundaries | D:2135 before acceptance; D:2008 after acceptance; D:1816 before pending commit; D:1931 after pending commit/before observation; D:538 after decision commit; D:656 before effect; D:81 after independent effect/before result and after result commit. Interrupted decisions conservatively block. | PASS |
| 13. Uncertain-effect fork | D:81/D:387 reliable operation-ID recovery without a second ledger effect; D:469 non-idempotent reconciliation; D:306 weak/removed declarations cannot authorize retry. | PASS |
| 14. Repeated recovery/stale outcomes | D:142 competing explicit recoveries; D:419/D:628 stale result fences; D:81 repeated terminal recovery; D:1238 ready decision resumes once. | PASS |
| 15. Preserved allowances/offline expiry | D:1266 sequential waits with model retries; D:1396 attempt/step limits; D:1316 restart active deadline; D:1475 exhausted active time; D:213/D:263 shared effect/model retry budgets; D:875 offline expiry. | PASS |
| 16. Incompatible/nonrecoverable state | D:1340 unreadable/incompatible checkpoints; D:1801 changed composition; D:1200 legacy format; D:821 unsupported format on answer; D:2122 nonrecoverable continuation; D:1982 nonportable atoms in a fresh BEAM. | PASS |
| 17. Lost observer delivery | D:1931 committed pending state survives observer loss; inspection reconstructs the request without replaying tokens. | PASS |
| 18. Credential/private-state exclusion | D:1499 fresh authority/canary exclusion; D:2172 malformed tool failure excludes private option, authority and failure canaries; D:716 preserves full provider continuation across fresh BEAM; K/R private-failure and provider-continuation cases. | PASS |
| 19. Active/pending admission limits | D:1153 atomic pending capacity; D:1870 waiting releases active capacity; D:1888 durable accepted work respects active capacity; D:1238 ready continuation capacity; D:1564 blocked work still occupies the pending bound. | PASS |

Run a selector, for example, with:

```sh
mix test test/durable_test.exs:47 --warnings-as-errors
```

Fault controls are at existing host access, model, tool and persistence
boundaries. Public submissions, answers, snapshots, checkpoints, cancellation
and recovery supply the assertions; no private execution-process state is
inspected. Trigger failures and revision corruption are test-host fault
injection, not additional public APIs.

## Responder audit follow-up

The parent requires:

> Decision records identify the authenticated responder and result without
> persisting credentials.

The owner authorized the scoped host identity/audit contract after the original
validation reported this gap.

The original [Access](../lib/knotra/access.ex) contract returned only a tenant.
It now requires `{:ok, tenant_id, responder_id}` for `:answer`, with a nonsecret,
host-authenticated binary reference of 1–256 bytes. Missing/malformed identities
and tenant-only answer policies fail closed. Other actions retain tenant-only
support; actor identity never comes from the five-field answer or model arguments.

The existing [decision transition](../lib/knotra/durable.ex) conditionally writes
`approval.responder_id` in both checkpoint and snapshot, plus the same top-level
field on the `:approval_answered` receipt. This is the same revision/deadline
write as the decision, not a subsequent audit update. Duplicate answers, another
responder and recovery preserve the winning identity; later requests retain prior
identities in their receipts. Failed commits publish neither decision nor actor.

The explicit [audit self-check](../test/support/probe_approval_audit.exs)
selects a known fake host principal, observes successful host authorization,
rejects the proposal, and examines the public decision receipt and private
approval checkpoint. It asserts the exact selected principal in both records
and the rejection receipt, with zero effects:

```sh
MIX_ENV=test mix run --no-start test/support/probe_approval_audit.exs
```

Original result at `ede28ef`: `Authenticated responder recorded: false`, then
`UNIMPLEMENTED` and exit 1. Current result: `Authenticated responder recorded:
true; decision: rejected; effects: 0`, **exit 0**.

Regression coverage in [durable tests](../test/durable_test.exs) includes
`trusted responder identity survives decisions, duplicate answers and storage reconnect`
and `answer refuses missing or malformed host responder identities and client actor injection`.
Existing conflicting-answer, failed-decision-commit, sequential-approval and
fresh-BEAM checks now also assert provenance. Private objects, credentials and
captured authorization remain excluded. Historical records without an actor are
not backfilled; see [rollout compatibility](durable-approvals.md#responder-audit-rollout).

## Current follow-up gates

```sh
ERL_FLAGS='+S 2:2' MIX_ENV=test mix compile --warnings-as-errors
ERL_FLAGS='+S 2:2' mix format --check-formatted
ERL_FLAGS='+S 2:2' mix test --warnings-as-errors
ERL_FLAGS='+S 2:2' MIX_ENV=test mix run --no-start test/support/probe_approval_audit.exs
git diff --check
```

- **112 tests PASS**, seed `205230`, 36.8 seconds; the durable suite also passed
  independently (**80 tests**, seed `803116`). Compilation, formatting and
  whitespace pass; the responder self-check exits 0 with zero effects.
- An earlier follow-up full run passed 109/112: existing offline ReqLLM timing
  checks and a Repo-setup checkout failed. Some isolated retries also failed.
  Local measurements showed CPU saturation and 28–43 runnable processes;
  limiting this VM to two schedulers reduced its resource use. The eventual
  passing run does not isolate every intermittent cause or certify reliability.
  No test timeout, pool setting, production code outside this contract or
  unrelated process was changed to obtain the pass.
- SQLite settings and production/ownership limits remain as disclosed above;
  this audit fix does not certify the configured-but-unasserted ledger PRAGMAs
  or effective busy timeout.

## Historical validation at `ede28ef`

```sh
MIX_ENV=test mix compile --warnings-as-errors
mix format --check-formatted
mix test --warnings-as-errors
# This original diagnostic failed at that revision:
MIX_ENV=test mix run --no-start test/support/probe_approval_audit.exs
git diff --check
```

- Compilation, formatting and whitespace: **PASS**.
- Existing offline and SQLite regression/acceptance suites: **110 PASS**,
  seed `626605`, 30.1 seconds. No live provider or production operation ran.
- Original responder audit diagnostic at `ede28ef`: **FAIL / UNIMPLEMENTED**,
  exit 1. The follow-up self-check passes with exact identity assertions. No
  check was substituted with an in-memory durability simulation.
- The first expanded full run had two failures in existing cases: the
  2-second pending-observation assertion at D:1396 and a 4-second connection
  checkout during setup of D:1475. The two cases and both added tests then
  passed together (4/4), followed by the full 110-pass run above. The
  intermittent cause was not isolated; no timeout/pool settings were changed.
  Passing reruns do not establish freedom from timing/setup sensitivity.

The SQLite adapter/native driver and locked dependencies must build on a
runner with a writable local filesystem. This local run does not certify CI,
power-loss durability, throughput or performance superiority.

## Primary comparison, not imported guarantees

Inspected on 2026-10-07, **DeepSeek Harness first**:

1. [DeepSeek approvals at `639ed015397290b3745d163aafe02ffee4aa3f84`][dsh]:
   `ask`/`never`, one-shot decisions, unavailable answerers fail closed, aborted
   requests discard late answers, and asked/decided audit pairs commit within
   an open turn. Its README explicitly defers durable out-of-turn approval;
   the request does not carry tool arguments. Knotra instead tests persisted
   exact-argument binding, worker-free waits and explicit crash recovery. The
   inspected DeepSeek contract does **not** certify these Knotra guarantees.
2. [LangGraph official interrupts documentation][langgraph]: persistent
   checkpointer, stable thread ID and resume command; resuming reruns the node
   from its beginning, so earlier effects must be idempotent or separated.
   Knotra's safe-point/intent/result tests must establish its own effect
   boundary. This source is **unversioned** official documentation, not an
   installed/version-pinned comparative run.
3. [Sagents at `5ff209c972cddece02fcebfe35cf1b7b2d1e1105`][sagents]:
   tool approve/edit/reject, interrupt propagation from children, resume and
   optional state persistence. The README does not establish the specific
   independent-effect-ledger crash fork tested here. Unverified is not absent;
   no comparative Sagents runtime or safety benchmark was run.

[Legion's pinned sandbox guide][legion] remains relevant to later generated
code, not an adopted approval dependency. The existing
[architecture comparison](../ARCHITECTURE.md#what-legion-establishesand-does-not)
keeps its in-host-BEAM sandbox limitation separate from this proof. No other
harness, UI/audio/delegation framework or dependency was introduced.

## Remaining boundaries

The tested scope is allowlisted fake operations, SQLite and one owning Knotra
instance. There is no automatic effect retry, exactly-once remote-effect claim,
distributed lease/takeover, PostgreSQL parity, real-service idempotency
certification or remote rollback. Interrupted model calls/decisions can block;
ready work requires explicit continuation, not an automatic queue drainer.

Public snapshots/observer notifications are not recovery checkpoints.
`checkpoint/3` requires separate host permission and preserves provider
continuation; stored content can still be sensitive. Expiry is materialized on
lifecycle access. Pending bounds are optional configuration, and history
retention is host-owned. Generated-operation admission, conversation ordering,
UI/voice and swarms remain future decisions.

Foundational slices: [storage decision #3](https://github.com/stlucasgarcia/knotra/issues/3),
[persistence #4](https://github.com/stlucasgarcia/knotra/issues/4),
[approval #5](https://github.com/stlucasgarcia/knotra/issues/5),
[lifecycle #6](https://github.com/stlucasgarcia/knotra/issues/6),
[limits/compatibility #7](https://github.com/stlucasgarcia/knotra/issues/7), and
[idempotent fake recovery #8](https://github.com/stlucasgarcia/knotra/issues/8).
The responder-audit follow-up resolves the recorded provenance gap, not the
production and comparative limitations or parent closure.

[dsh]: https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/interaction/user-approval/README.md
[langgraph]: https://docs.langchain.com/oss/python/langgraph/interrupts
[sagents]: https://github.com/sagents-ai/sagents/blob/5ff209c972cddece02fcebfe35cf1b7b2d1e1105/README.md
[legion]: https://github.com/software-mansion/legion/blob/b5d57d326d710b22a6321a9d6c59970a8d6a4bf7/guides/sandboxes.md
