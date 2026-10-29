# KnotraBots

A minimal **agentic chat** POC built on [Knotra](../../README.md): humans and
host-defined agents share channels, work in the open, and ask for approval before
a write tool runs.

- **Channels** hold one shared timeline for people and agents.
- **`@handle` routing** sends a message to the agents you mention; without a
  mention, the channel's default agent answers.
- **Handoffs** let one agent mention a teammate, which starts that teammate's
  durable execution. One hop only, so a handoff cannot loop.
- **Every agent reply is one durable execution** with a status, counters, event
  trace, and an inline clarification or write-approval gate.
- **Restart-safe** approvals and messages: pending work is still there after the
  server or the Knotra runtime restarts.
- **Only write tools wait for a person.** Read-only `lookup` approvals are
  answered by the demo's host policy, while `notify` waits for Approve/Reject.
- The only effect is a fake append-only notice file. Nothing is sent anywhere.

The [library documentation](../../README.md) stays authoritative for the full
contract; this README is a tour of the demo.

## Quickstart

```sh
cd examples/knotra_bots
mix setup                        # deps.get + host-run migrations + seeds
export GOOGLE_API_KEY=...        # or: cp .env.example .env and fill in one key
mix phx.server                   # http://localhost:4000
```

Open `http://localhost:4000` (not `127.0.0.1`; the LiveView socket origin check
expects `localhost`). The landing page opens the seeded multi-agent `#Ops`
channel.

To run the whole demo with no key and no network:

```sh
KNOTRA_BOTS_MODEL=fake mix phx.server
```

`.env` (copied from `.env.example`) is loaded in `config/runtime.exs` when present.
An explicit environment variable wins over the file.

## The offline demo in 60 seconds

With `KNOTRA_BOTS_MODEL=fake`:

1. In `#Ops`, send:

   ```text
   can you check order ord-1?
   ```

   `@concierge` answers “Handing this to @researcher.” A new `@researcher`
   message appears, because the mention became a second durable execution.

2. `@researcher` proposes `lookup` with `%{"query" => "ord-1"}`. The read-only
   request is answered by the chat relay's host policy, so there is nothing to
   click: the same message completes with
   “Done. The result was: Order ord-1 shipped and arrives Tuesday.”

3. Send:

   ```text
   notify ops that order ord-1 shipped
   ```

   `@concierge` proposes `notify` with `%{"to" => "ops", ...}`. Approve it; exactly
   one line (`ops`) is appended to `_build/notices.log`.

4. Send `please clarify the request` to `@assistant`. It asks for a detail inline;
   answer it and the execution resumes and completes.

The fake model also echoes ordinary messages, so every routing path is usable
without a provider. Rejecting an approval records `rejected` and performs no
effect.

## How a message becomes work

1. `KnotraBots.Chat.post/2` stores the human message and inserts one queued agent
   message per target agent.
2. The targets are the mentioned channel members, or the channel's default member
   when there is no mention.
3. A supervised `KnotraBots.Chat` tick submits each queued message through
   `Knotra.submit/6` with the deterministic key `chat-<message_id>`. A retry after
   a crash reuses the accepted execution instead of starting a duplicate.
4. The tick polls `Knotra.snapshot/3` every ~250 ms and records the message status:
   `queued`, `running`, `waiting`, `completed`, `failed`, `rejected`, `blocked`,
   `cancelled`, or `expired`.
5. When an agent reply completes, `Chat` reads its output for `@handle` mentions.
   At most one follow-up hop is queued; those messages cannot chain further.
6. The LiveView renders the stored messages plus each agent execution's public
   snapshot. PubSub carries the relay's transitions and a bounded ~1 s refresh
   covers another session or a restart.

The execution input is the channel transcript so far:

```text
Channel: #Ops
Topic: Order questions and notices. Try: can you check order ord-1?

Human: can you check order ord-1?
Concierge: Handing this to @researcher.
```

Agents therefore see earlier human and completed agent turns. Pending or failed
agent messages are not fed back as completed context.

## Agents

Agents are **host-owned rows**, created and edited at `/agents`:

- **name**, **handle**, **system prompt**, **model**, and **tools** (any subset of
  the read-only `lookup` and the approval-gated `notify`).
- The handle is the `@mention`; it is lowercased and defaults to a slug of the
  name. It must be unique.
- Saving an edit bumps the agent's `revision`, so its durable definition version
  (`agent-<id>-r<revision>`) changes whenever behavior does. Editing an agent with
  a pending approval blocks answering it as an incompatible checkpoint instead of
  silently changing behavior.
- Deleting is refused while a channel lists the agent.

Three agents are seeded when the table is empty, using the configured model
(`KNOTRA_BOTS_MODEL`, default `google:gemini-2.5-flash`):

| Agent | Handle | Tools | Role |
|---|---|---|---|
| Assistant | `@assistant` | none | General questions and clarifications |
| Researcher | `@researcher` | `lookup` | Order research; asks for an order id |
| Concierge | `@concierge` | `notify` | Front desk; hands order questions to `@researcher` |

A `KNOTRA_BOTS_MODEL=fake` (or test) run seeds offline versions, so the demo runs
without a key.

## Channels

Channels are created at `/channels`. Select one or more agents; the first selected
agent (alphabetically) becomes the default responder. A message with no mention
goes to it. Mention one or more handles to address specific agents:

```text
@researcher @concierge can you check ord-2 and notify ops?
```

Typing `@` in the composer lists the channel's agents, filtered as you type.
Use ↑/↓ to move the highlight; Tab, Enter, or a click picks it. Escape dismisses
the list.

Two starter channels are seeded when the table is empty:

- **#Ops** — Concierge (default) and Researcher.
- **#General** — Assistant.

`/` lands on the channel with most agents (`#Ops` in the seeded demo).

Agent replies can mention a teammate to hand work over:

```text
Concierge: Handing this to @researcher.
```

The handoff target must be a member of the same channel. The target reply is
queued as `hop: 1`; its own mentions do not trigger a third agent. This keeps a
misconfigured prompt from creating an unbounded agent-to-agent loop.

## Inline lifecycle

Each agent message shows its live state:

- **Queued / working** — the execution is submitted or running.
- **Needs you** — a pending clarification, or a write approval, is rendered in the
  message.
  - A clarification is an `input_request`; the answer form calls
    `Knotra.answer/5`, and the same execution continues.
  - A write approval shows the operation name and validated arguments; Approve/Reject
    answer the bound request.
- **Done** — the durable output.
- **Failed / blocked / rejected / cancelled / expired** — the terminal status and
  a safe error detail.
- The **trace** disclosure shows turn/tool/retry counts, the event sequence and
  elapsed milliseconds, and the pinned definition version.

## Tool approval policy

Knotra's durable path records a bound approval before every tool call; that is the
runtime contract, not a demo setting. On top of it, `KnotraBots.Chat` applies a host
policy: when a pending approval names a tool the agent offers with
`read_only: true`, the relay answers it immediately with the `policy:read-only`
responder. The gate and its `approval_answered` event remain in the execution trace,
but a human is never asked.

Write tools are not auto-answered. `notify` is `read_only: false`, so its message
shows the operation name and validated arguments and waits for Approve/Reject.
Rejecting records `rejected` and performs no effect. `notify` appends one line to
`_build/notices.log`; it performs no network or real messaging operation.

Read-onlyness is a trusted tool declaration, not a sandbox. A production host should
derive the responder from its authenticated approver and keep consequential
operations human-gated.

## Models

`Knotra.Definition` pins the model adapter per agent message. The catalog is:

| Model | Notes |
|---|---|
| `google:gemini-2.5-flash`, `google:gemini-2.5-pro` | `GOOGLE_API_KEY` (or `GEMINI_API_KEY`) |
| `openai:gpt-4o-mini` | `OPENAI_API_KEY` |
| `xai:grok-4.6` | `XAI_API_KEY` |
| `anthropic:claude-sonnet-4-5` | `ANTHROPIC_API_KEY` |
| `fake` | offline deterministic model, no key |

An agent's **system prompt** is passed to ReqLLM as the `system_prompt` model option.
A send does not start an agent whose key is missing: `Chat.post/2` records a
failed message with `Model not ready: ...` instead of accepting work that would
become a redacted `plugin_exception`.

`KnotraBots.Models.ChatFake` drives the offline paths:

- an order id (`ord-1`) becomes a `lookup` call;
- a `notify`/`send`/`notice` request becomes a `notify` call when the agent has it;
- a prompt containing `hand off to @handle` produces that mention for order
  questions;
- `clarify` asks for a detail;
- anything else echoes the latest human line.

## Restart survival

Messages and durable executions live in SQLite. Stop the server (`Ctrl+C`) or the
Knotra runtime with a pending approval, start it again, and reload the channel:

- The human and agent messages are still listed.
- The pending approval or clarification is rebuilt from the durable snapshot.
- Answering it resumes the same execution with preserved counters and budgets.
- A pending read-only approval is answered by the relay's host policy on its next
  tick; a pending write approval still waits for you.
- A queued agent message without an execution is submitted again with its
  deterministic key; the durable store deduplicates it.

A running execution is owned by Knotra and finishes on its own unless its deadline
expires. The chat relay is a supervised process; it starts on boot and finds any
non-terminal messages.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `GOOGLE_API_KEY` | — | ReqLLM's Gemini provider key |
| `GEMINI_API_KEY` | — | Used only when `GOOGLE_API_KEY` is unset |
| `KNOTRA_BOTS_MODEL` | `google:gemini-2.5-flash` | Model string for seeded agents; `fake` is offline |
| `KNOTRA_BOTS_PORT` | `4000` | HTTP port |
| `KNOTRA_BOTS_DB` | `_build/knotra_bots-<env>.sqlite3` | SQLite database path |
| `SECRET_KEY_BASE` | dev default | Cookie/session signing key |

`KNOTRA_BOTS_MODEL` sets the model seeded into the default agents; individual
agents can use any catalog model. The notice file lives next to the database under
`_build/`; tests override `config :knotra_bots, :notices_path` per test.

## Migrations and the upgrade from the older demo

Migrations are host-run, as [ADR 0001](../../docs/adr/0001-ecto-sqlite-persistence.md)
requires:

```sh
mix setup                        # deps.get + knotra_bots.migrate
mix knotra_bots.migrate          # just the migrations and seeds
```

This cut applies:

1. `Knotra.Persistence.Migration` (v1) — `knotra_executions`.
2. `KnotraBots.Persistence.Migration` (v2) — the original bot-to-bot tables.
3. `KnotraBots.Persistence.MigrationV3` — **POC cutover**: drops `bots`,
   `conversations` and `conversation_turns`, then creates `agents`, `channels`,
   `channel_agents` and `messages`. The demo database is disposable; delete it
   instead of preserving old demo data.
4. `KnotraBots.Persistence.MigrationV4` — idempotently repairs an older
   `knotra_executions` table that is missing the `inserted_at` column and the
   status/tenant indexes. Fresh databases already have them.

Knotra does not migrate on boot. A server started before `mix knotra_bots.migrate`
has no tables to seed; the chat relay tolerates that boot order and starts working
after the migration.

## Verification

```sh
cd examples/knotra_bots
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

No API key and no network are used: tests force the fake model and cover:

- default routing, explicit mentions, and one-hop handoffs;
- the @ mention picker listing channel agents and inserting the chosen handle;
- the concierge → researcher lookup completing without a human gate;
- read-only auto-approval recorded against the `policy:read-only` responder;
- approve and reject for `notify`, including exactly one notice line;
- inline clarification answer and completion;
- a pending approval surviving a Knotra runtime restart;
- agent create/edit/delete and handle derivation;
- channel creation with selected agents;
- a missing provider key failing visibly instead of starting an execution.

## POC boundaries

- **Fake effect only.** `notify` appends to a local file. Do not allowlist a
  production operation.
- **Channels and executions are single-instance SQLite.** Durable ownership is
  not a distributed takeover protocol.
- **One handoff hop.** More hops need an explicit budget/routing policy; the
  current bound keeps a prompt loop from spawning executions forever.
- **Approvals are host policy for reads.** The durable runtime still publishes a
  bound approval for every tool call; the chat relay auto-answers read-only ones.
  Read-onlyness is a trusted declaration, not enforcement, so a tool that lies
  about being read-only would be auto-approved.
- **No threads, reactions, files, images, voice, or streaming tokens.** An agent
  message appears with a working state and updates when the execution reaches a
  gate or terminal status.
- **Transcript replay, no compaction.** Each execution receives the channel
  history; long channels grow the prompt.
- **Demo access policy.** `KnotraBots.Access` allows only the `demo` tenant and
  uses a host-supplied responder or `USER`. The read-only policy scope supplies
  `policy:read-only`. A real host derives tenant and responder from authenticated
  request data.
- **Host-owned identities.** Channels and messages are host tables; each agent
  message references a Knotra execution id. A real host keeps such tables instead
  of reaching into Knotra's persistence schema.

## Troubleshooting

- **A reply failed at the model step** (`plugin_exception` / `model_error`) —
  Knotra redacts raw exception text from public records, so run
  `mix knotra_bots.check`. It prints the model status, the adapter result and the
  raw provider reason. Common causes: an unfilled `.env`, no `GOOGLE_API_KEY` /
  `GEMINI_API_KEY`, or an agent configured with a model whose key is missing.
- **The page does not update and the server logs “Could not check origin”** — open
  `http://localhost:<port>`, not `127.0.0.1`, or configure `check_origin` for the
  endpoint.
- **Offline** — set `KNOTRA_BOTS_MODEL=fake` to run everything without a key.
- **Migrations** — run `mix setup` (or `mix knotra_bots.migrate`) before the
  server. If you delete the SQLite file under `_build/`, run it again.
- **An old demo database** — `mix knotra_bots.migrate` applies the v3 cutover; old
  bot-to-bot tables are dropped and the database is re-seeded. If
  `knotra_executions` predates `inserted_at`, v4 repairs it.
- **Port already in use** — set `KNOTRA_BOTS_PORT`.

See [the architecture and future workflow scenarios](../../ARCHITECTURE.md),
[the milestone-1 design](../../docs/design.md), and
[the historical alternatives research](../../docs/research/elixir-agent-alternatives.md).
