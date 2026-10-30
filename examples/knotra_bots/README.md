# KnotraBots

An **agentic e-commerce** POC built on [Knotra](../../README.md): humans and
host-defined agents share channels, work in the open, read a mocked storefront,
and ask for approval before a consequential write.

The default landing page opens **#storefront-ops**, a guided tour of four
e-commerce specialists:

- **Concierge** triages and routes work by `@mention`.
- **Order Desk** reads orders, tracking and customer history.
- **Returns** checks the return policy and proposes refunds.
- **Inventory** checks stock and proposes restocks.

The data is deliberately mocked in `KnotraBots.Commerce`: five SKUs, seven
orders and four customers. No payment provider, inventory system or network
effect is involved. The point is the agent workflow: routing, handoffs, typed
read-only tools, approval-gated writes, durable execution records, and swarms.

## Quickstart

```sh
cd examples/knotra_bots
mix setup                        # deps.get + host-run migrations + seeds
export GOOGLE_API_KEY=...        # or: cp .env.example .env and fill in one key
mix phx.server                   # http://localhost:4000
```

To run with no key and no network, set the model before the first `mix setup`:

```sh
KNOTRA_BOTS_MODEL=fake mix setup
KNOTRA_BOTS_MODEL=fake mix phx.server
```

Seeding writes the configured model into the agent rows. If the agents were
already seeded with an online model, edit them at `/agents` and choose `fake`, or
delete the demo database and re-run setup.

`.env` (copied from `.env.example`) is loaded in `config/runtime.exs`. An explicit
environment variable wins over the file. Development reloads changed modules and
plain CSS/JS; there is no asset build step.

## The offline tour in 60 seconds

With `KNOTRA_BOTS_MODEL=fake`, on `http://localhost:4000`:

1. **Route and hand off.** Send:

   ```text
   can you check order ord-3?
   ```

   `@concierge` answers “Handing this to @orders.” The mention becomes a second
   durable execution. `@orders` calls the read-only `order_lookup` tool and
   completes with the mocked order, customer tier, items, total and tracking.

2. **Check policy.** Send:

   ```text
   @returns is ord-3 eligible for a return?
   ```

   `@returns` calls `return_policy` and reports the 30-day window, days left and
   refund amount. Read-only approvals are answered by the relay's host policy;
   nothing is clicked and no effect happens.

3. **Approve a write.** Send:

   ```text
   refund ord-3 because it arrived late
   ```

   `@returns` proposes `refund` with `%{"order" => "ord-3", "reason" => ...}`.
   Approve it: exactly one line is appended to `_build/effects.log`. Reject it:
   the execution records `rejected` and nothing is written.

4. **Approve a restock.** Send:

   ```text
   restock sku-tee-01
   ```

   `@inventory` proposes `restock` (+24 units). Approve to append one ledger
   line. The mocked stock does not change; the approval gate is the point.

5. **Ask for a detail.** Send `please clarify the request` to any agent. It asks
   one inline question; answer it and the same execution resumes.

The fake model also echoes ordinary messages, so every routing path is usable
without a provider.

## How a message becomes work

1. `KnotraBots.Chat.post/2` stores the human message and inserts one queued agent
   message per target agent.
2. Targets are the mentioned channel members, or the channel's default member
   when there is no mention.
3. A supervised `KnotraBots.Chat` tick submits each queued message through
   `Knotra.submit/6` with the deterministic key `chat-<message_id>`. A retry after
   a crash reuses the accepted execution instead of starting a duplicate.
4. The tick polls `Knotra.snapshot/3` every ~250 ms and records the message status:
   `queued`, `running`, `waiting`, `completed`, `failed`, `rejected`, `blocked`,
   `cancelled`, or `expired`.
5. When an agent reply completes, `Chat` reads its output for `@handle` mentions.
   At most one follow-up hop is queued; those messages cannot chain further.
6. The LiveView renders stored messages plus each execution's public snapshot.
   PubSub carries the relay's transitions; a bounded ~1 s refresh covers another
   session or a restart.

The execution input is the channel transcript so far:

```text
Channel: #storefront-ops
Topic: Agentic storefront: orders, returns and inventory. Try a guided prompt.

Human: can you check order ord-3?
Concierge: Handing this to @orders.
```

Agents see earlier human and completed agent turns. Pending or failed agent
messages are not fed back as completed context.

## The mocked storefront

`KnotraBots.Commerce` is the host-owned data the tools read. It is a module, not
a database:

| Entity | Examples |
|---|---|
| Products | `sku-tee-01` Everyday Tee (4 in stock, reorder at 12), `sku-hood-02` Summit Hoodie, `sku-mug-03` Camp Mug (out of stock), `sku-cap-04`, `sku-sock-05` |
| Customers | `cus-1` Maya Chen (gold, LTV $1,840), `cus-2` Liam Ortiz, `cus-3` Priya Nair (at churn risk), `cus-4` Noah Park |
| Orders | `ord-1` shipped, `ord-2` processing, `ord-3` delivered 12 days ago, `ord-4` delayed, `ord-5` delivered 3 days ago, `ord-6` cancelled, `ord-7` delivered 45 days ago |

Return eligibility is deterministic: delivered inside the 30-day window is
eligible; an order in transit is not yet eligible; a cancelled order cannot be
returned. This gives both a positive case (`ord-3`, `ord-5`) and a negative case
(`ord-7`) for demos and tests.

### Tools

| Tool | Kind | What it does |
|---|---|---|
| `order_lookup` | read-only | Order by id, or a customer's recent orders by email/name |
| `customer_lookup` | read-only | Customer tier, LTV, contact and recent orders |
| `stock_lookup` | read-only | Stock by SKU/name, or the `low`/`out` exception list |
| `return_policy` | read-only | Eligible/not, days left, refund amount |
| `refund` | **write** | Approval-gated refund; appends one effects-ledger line |
| `restock` | **write** | Approval-gated restock proposal; appends one ledger line |
| `notify` | **write** | Approval-gated internal notice; appends one line to `_build/notices.log` |

Tool arguments are validated and authorized by host code before execution.
Read-onlyness is a trusted declaration, not a sandbox.

## Agents

Agents are host-owned rows, created and edited at `/agents`: name, handle,
system prompt, model, and any subset of the tools above.

- The handle is the `@mention`; it is lowercased and defaults to a slug of the
  name. It must be unique.
- Saving an edit bumps `revision`, so the durable definition version
  (`agent-<id>-r<revision>`) changes whenever behavior does. Editing an agent with
  a pending approval blocks answering it as an incompatible checkpoint.
- Deleting is refused while a channel lists the agent.

Seeded agents (using `KNOTRA_BOTS_MODEL`, default `google:gemini-2.5-flash`):

| Agent | Handle | Tools | Role |
|---|---|---|---|
| Concierge | `@concierge` | `notify` | Front desk; routes order/return/stock work |
| Order Desk | `@orders` | `order_lookup`, `customer_lookup` | Order status, tracking, customer context |
| Returns | `@returns` | `order_lookup`, `return_policy`, `refund` | Eligibility and refund proposals |
| Inventory | `@inventory` | `stock_lookup`, `restock` | Stock checks and reorder proposals |
| Pricing Strategist | `@pricing` | `stock_lookup` | Growth-lab debate: margin and elasticity |
| Retention Analyst | `@retention` | `customer_lookup` | Growth-lab debate: LTV and churn |
| Brand Voice | `@brand` | none | Growth-lab debate: tone and trust |

## Channels

Channels are created at `/channels`; select agents and the first selected agent
(alphabetically) becomes the default responder. Mention one or more handles to
address specific agents:

```text
@orders @returns can you check ord-3 and its return policy?
```

Typing `@` lists the channel's agents, filtered as you type. ↑/↓ moves the
highlight; Tab, Enter or a click picks it; Escape dismisses the list.

Seeded channels:

- **#storefront-ops** — Concierge (default), Order Desk, Returns, Inventory. This
  is the landing channel and carries the guided-tour note.
- **#growth-lab** — Pricing Strategist (default), Retention Analyst, Brand Voice.
  Built for debate and fan-out strategy scenarios.
- **#fulfillment** — Order Desk (default), Returns. Built for the shared-board
  backlog scenario.

`/` lands on the channel with the most agents (`#storefront-ops`).

Agent replies can mention a teammate to hand work over. The target must be a
member of the same channel; the follow-up is queued as `hop: 1`, and its own
mentions cannot trigger a third agent. This bounds a prompt loop.

## Swarms

`/swarm` runs one goal across a channel's agents. The page now offers three
one-click e-commerce scenarios plus the manual controls:

| Scenario | Mode | What it shows |
|---|---|---|
| **Late-delivery recovery** | Debate | Three specialists answer one retention question; the strongest attempt is selected (others stay inspectable) |
| **Launch plan** | Fan out | Three independent decisions run in parallel and merge into one brief |
| **Order backlog** | Shared board | Agents claim order checks from a shared board; no coordinator assigns work |
| **Coordinator plan** | Coordinator | Creates a Refund Specialist and a Stock Specialist, assigns four tasks, approves the in-policy writes and escalates the over-limit refund |

| Mode | What happens |
|---|---|
| **Debate** | Every agent answers the same goal independently; the selector keeps the strongest attempt |
| **Fan out** | The goal splits on commas, semicolons or newlines; agents run the parts concurrently and merge the results |
| **Shared board** | Members claim parts from a shared board and self-select until it is empty; no coordinator assigns work |
| **Coordinator** | A planner synthesizes specialists at runtime, assigns their tasks, auto-approves writes inside the host policy and escalates the rest |

The same run is available inside a channel. The members are that channel's
agents, so the seeded examples name the room that has the right specialists:

```text
# in #fulfillment
/swarm board check order ord-3, check order ord-4, check order ord-7

# in #growth-lab
/swarm debate choose the best late-delivery recovery offer
/swarm fanout choose the apology email tone; choose the hoodie launch price; choose the retention offer for a late gold customer
```

The outcome is posted as a system note. The page (and the note) report the
conversation id, per-part turns/tools/elapsed time, and the agent that handled
each part. A failed attempt stays inspectable; debate selects only completed
attempts. If every attempt fails, the run reports `:no_attempts` and the page
explains each part. A `:model_error` means the provider call failed — run
`mix knotra_bots.check`; an `:incomplete_response` usually means the output
budget ended the turn before any text. Ordinary swarm modes are non-durable
executions that may dispatch only declared read-only tools. Coordinator mode may
dispatch declared write tools through the host policy; an out-of-policy write is
escalated and performs no effect, and none of these paths is a durable approval.

The **Coordinator** mode passes a host `:plan` to `Knotra.Swarm`. The demo planner
creates two ephemeral agents from the tool registry, assigns four tasks by name,
and supplies a write policy: `notify` is approved, a refund at or below $50 on an
eligible order is approved, a larger refund escalates, and a restock at or below
24 units is approved. Escalated calls are listed on the result and in the UI; they
perform no effect. The planner uses the configured model online and a fixed
offline plan under `KNOTRA_BOTS_MODEL=fake`.

The coordinator result is inspectable in the page: every member shows its
`created`/`existing` badge, tool list, definition version, a visible initial-prompt
preview and the full prompt, while the task table shows the iteration, status,
turn/tool counts and elapsed time. Escalated writes are listed separately.

For a terminal version of the same shapes outside Phoenix:

```sh
mix run examples/swarm_showcase.exs
```

It runs a catalog audit (fan-out), an order backlog (board), a retention debate
(debate) and a coordinator run with one approved and one escalated write.

## Inline lifecycle

Each agent message shows its live state:

- **Queued / working** — submitted or running.
- **Needs you** — a pending clarification or write approval, rendered inline.
  - A clarification is an `input_request`; answering calls `Knotra.answer/5` and
    the same execution continues.
  - A write approval shows the operation name and validated arguments;
    Approve/Reject answer the bound request.
- **Done** — the durable output.
- **Failed / blocked / rejected / cancelled / expired** — terminal status and a
  safe error detail.
- The **trace** disclosure shows turn/tool/retry counts, event sequence, elapsed
  milliseconds, and the pinned definition version.

## Observability

`http://localhost:4000/observability` mounts `Knotra.Dashboard.Live`. It shows
the agents that have run, their models and tools, live and completed executions,
the conversation topology across handoffs, a message feed spanning every
execution, and a **Swarms** tab. Select a coordinator run there to see the
planner's input and output, the created agents with prompts/tools, assigned
tasks, escalations, member executions, and a merged coordinator + member
timeline. Select an execution to inspect its full timeline: input, model
requests and replies, tool calls and results, clarification and approval gates,
usage, and terminal errors. The detail pane reports total run duration and a
per-turn table with model latency, tool time, other overhead, and call counts.

Every chat submission annotates its durable execution with the agent name,
channel, conversation root, hop and message id, so handoffs appear as connected
conversation steps and agent-to-agent edges. Each swarm member is traced under
the swarm's conversation with `mode`/`part` labels.

The dashboard reads the instance's bounded in-memory store: it covers work since
this BEAM started, not durable history from before a restart. It renders message
text and tool arguments, so the demo mounts it behind
`KnotraBotsWeb.DashboardAuth`: loopback requests are allowed; non-loopback
requests need `KNOTRA_BOTS_DASHBOARD_TOKEN` as a `token` query parameter or an
`x-dashboard-token` header. The same module is the route's `on_mount` hook, so a
reconnect is re-authorized too.

## Approval policy

Knotra's durable path records a bound approval before every tool call. This
demo's host policy answers approvals for tools the agent offers with
`read_only: true` immediately, using the `policy:read-only` responder. The gate
and `approval_answered` event remain in the trace, but a human is never asked.

Write tools are not auto-answered. `refund`, `restock` and `notify` are
`read_only: false`: their messages show the validated arguments and wait for
Approve/Reject. Rejecting records `rejected` and performs no effect. The only
effects are local appends:

- `_build/effects.log` for refunds and restocks.
- `_build/notices.log` for notices.

Read-onlyness is a trusted tool declaration, not a sandbox. A production host
should derive the responder from its authenticated approver and keep
consequential operations human-gated.

## Models

The catalog is:

| Model | Notes |
|---|---|
| `google:gemini-2.5-flash`, `google:gemini-2.5-pro` | `GOOGLE_API_KEY` (or `GEMINI_API_KEY`) |
| `openai:gpt-4o-mini` | `OPENAI_API_KEY` |
| `xai:grok-4.6` | `XAI_API_KEY` |
| `anthropic:claude-sonnet-4-5` | `ANTHROPIC_API_KEY` |
| `fake` | offline deterministic model, no key |

An agent's **system prompt** is passed to ReqLLM as the `system_prompt` model
option. A send does not start an agent whose key is missing: `Chat.post/2`
records a failed message with `Model not ready: ...` instead of accepting work
that would become a redacted `plugin_exception`.

Seeded Gemini 2.5 agents use `max_tokens: 2048` and `google_thinking_budget: 0`.
Gemini counts hidden thinking against the output budget; with a small budget a
short reply can finish as `:incomplete_response` before emitting text. The demo
does not need visible reasoning, so thinking is off. Other models keep their
provider defaults.

`KnotraBots.Models.ChatFake` drives the offline paths:

- an order id or customer mention becomes `order_lookup` / `customer_lookup`;
- a return-eligibility question becomes `return_policy`;
- a refund or restock request becomes an approval-gated proposal;
- a notify request becomes an approval-gated `notify`;
- a `Routing: order=@orders, return=@returns, ...` prompt line (or the legacy
  `hand off to @handle` phrasing) produces a handoff mention;
- a growth persona with `Argue from …` answers a strategy question with a
  deterministic position, so debates produce distinct attempts;
- anything else echoes the latest human line.

## Restart survival

Messages and durable executions live in SQLite. Stop the server or the Knotra
runtime with a pending approval, start it again, and reload the channel:

- Human and agent messages are still listed.
- The pending approval or clarification is rebuilt from the durable snapshot.
- Answering it resumes the same execution with preserved counters and budgets.
- A pending read-only approval is answered by the relay's host policy on its next
  tick; a pending write approval still waits for you.
- A queued agent message without an execution is submitted again with its
  deterministic key; the durable store deduplicates it.

A running execution is owned by Knotra and finishes on its own unless its
deadline expires. The chat relay is supervised and finds any non-terminal
messages on boot.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `GOOGLE_API_KEY` | — | ReqLLM's Gemini provider key |
| `GEMINI_API_KEY` | — | Used only when `GOOGLE_API_KEY` is unset |
| `KNOTRA_BOTS_MODEL` | `google:gemini-2.5-flash` | Model string for seeded agents; `fake` is offline |
| `KNOTRA_BOTS_PORT` | `4000` | HTTP port |
| `KNOTRA_BOTS_DB` | `_build/knotra_bots-<env>.sqlite3` | SQLite database path |
| `KNOTRA_BOTS_DASHBOARD_TOKEN` | — | Required for non-loopback access to `/observability` |
| `SECRET_KEY_BASE` | dev default | Cookie/session signing key |

The effects and notice files live next to the database under `_build/`; tests
override their paths per test. The mocked commerce data is compiled into
`KnotraBots.Commerce`, so changing it is a code change, not a migration.

## Migrations and upgrade

Migrations are host-run, as [ADR 0001](../../docs/adr/0001-ecto-sqlite-persistence.md)
requires:

```sh
mix setup                        # deps.get + knotra_bots.migrate
mix knotra_bots.migrate          # just the migrations and seeds
```

This cut applies:

1. `Knotra.Persistence.Migration` (v1) — `knotra_executions`.
2. `KnotraBots.Persistence.Migration` (v2) — the original bot-to-bot tables.
3. `KnotraBots.Persistence.MigrationV3` — drops the old tables, creates `agents`,
   `channels`, `channel_agents` and `messages`.
4. `KnotraBots.Persistence.MigrationV4` — idempotently repairs an older
   `knotra_executions` table missing `inserted_at` and indexes.
5. `KnotraBots.Persistence.MigrationV5` — idempotently adds the frozen `input`
   and `definition_snapshot` columns to `messages`.

Seeding is idempotent: missing seed agents and seed channels are added on every
`mix knotra_bots.migrate`, and existing rows are left alone. An older demo
database therefore gains the three e-commerce channels and agents without losing
its #Ops/#General history. To start from a clean seed set, delete the demo
database and run `mix setup` again.

## Verification

```sh
cd examples/knotra_bots
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

No API key and no network are used: tests force the fake model and cover:

- default routing, explicit mentions and one-hop handoffs;
- the order desk reading mocked orders, and returns checking the 30-day policy;
- read-only auto-approval recorded against `policy:read-only`;
- approve/reject for `notify`, `refund` and `restock`, with exactly one ledger line;
- an ineligible refund failing closed before any approval;
- inline clarification answer and completion;
- a pending approval surviving a Knotra runtime restart;
- the `/swarm` page running debate, fan-out, board and coordinator, and loading scenarios;
- coordinator-created agents, in-policy writes executing once, and out-of-policy
  writes escalating without an effect while unrelated work continues;
- the in-chat `/swarm` command and its missing-goal error;
- the @ mention picker;
- agent create/edit/delete and handle derivation;
- channel creation, and a missing provider key failing visibly.

## POC boundaries

- **Mock effect only.** Refunds and restocks append to a local file; notices append
  to another. No payment, inventory or messaging integration exists. Do not
  allowlist a production operation.
- **Mocked commerce data.** Stock is not decremented, refunds do not mutate
  orders, and customer records do not change. A real host owns those writes.
- **Single-instance SQLite.** Durable ownership is not a distributed takeover
  protocol.
- **One handoff hop.** More hops need an explicit budget/routing policy.
- **Read-only approvals are host policy.** The runtime still publishes a bound
  approval for every tool call; the relay auto-answers read-only ones. A tool
  that lies about being read-only would be auto-approved.
- **No threads, reactions, files, images, voice or streaming tokens.** An agent
  message appears with a working state and updates at a gate or terminal status.
- **Transcript replay, no compaction.** Each execution receives channel history;
  long channels grow the prompt.
- **Demo access policy.** `KnotraBots.Access` allows only the `demo` tenant and
  derives the responder from host code or `USER`. A real host derives tenant and
  responder from authenticated request data.
- **Host-owned identities.** Channels and messages are host tables; an agent
  message references a Knotra execution id.

## Troubleshooting

- **A reply failed at the model step** (`plugin_exception` / `model_error`) —
  Knotra redacts raw exception text, so run `mix knotra_bots.check`. It prints the
  model status, adapter result and raw provider reason. Common causes: an unfilled
  `.env`, no `GOOGLE_API_KEY` / `GEMINI_API_KEY`, or an agent whose model key is
  missing.
- **The page does not update and the server logs “Could not check origin”** —
  development disables the socket origin check; restart the server if old config
  is still loaded. A non-dev deployment must configure `check_origin`.
- **Offline** — set `KNOTRA_BOTS_MODEL=fake` to run everything without a key.
- **Migrations** — run `mix setup` (or `mix knotra_bots.migrate`) before the
  server. If you delete the SQLite file under `_build/`, run it again.
- **Port already in use** — set `KNOTRA_BOTS_PORT`.

See [the architecture and future workflow scenarios](../../ARCHITECTURE.md),
[the milestone-1 design](../../docs/design.md), and
[the historical alternatives research](../../docs/research/elixir-agent-alternatives.md).
