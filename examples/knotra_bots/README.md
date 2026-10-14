# KnotraBots

A runnable example host for [Knotra](../../README.md): a Phoenix LiveView dashboard
that visualizes durable bot executions and runs two bots in a bot-to-bot
conversation.

It demonstrates, end to end:

- **Durable acceptance** — `Knotra.submit/6` returns a stable execution id after the
  request is committed to SQLite, not a process handle.
- **Clarification (input request)** — a bot asks a question and the execution waits
  without holding a worker slot.
- **Approval binding** — the model proposes one operation, and a human decides the
  exact validated operation and arguments with `Knotra.answer/5`.
- **Responder provenance** — the host records who answered, derived from trusted host
  data, not model text.
- **Preserved budgets** — turn/tool/retry/step counters and active allowance survive
  each wait.
- **Restart recovery visualized** — a pending run is still listed after the server
  restarts and can be answered from the dashboard.
- **Bot-to-bot conversations** — two host-defined bots alternate turns, each turn one
  durable execution, with stop/resume and restart-safe resumption.

The only side effect is a fake append-only notice file. Nothing is sent anywhere.
The [library documentation](../../README.md) stays authoritative for the full
contract; this README is a tour of the demo.

## Quickstart

```sh
cd examples/knotra_bots
mix setup                        # deps.get + host-applied migrations + seed bots
export GOOGLE_API_KEY=...        # or: cp .env.example .env and fill in one key
mix phx.server                   # http://localhost:4000
```

Then choose a bot, type a message and press **Run**, or open **Conversations** to run
two bots against each other.

`.env` (copied from `.env.example`) is loaded in `config/runtime.exs` when present.

## Bots

Bots are **host-owned rows**, created and edited at `/bots`:

- **name** (unique), **system prompt**, **model**, and **tools** (any subset of the
  read-only `lookup` and the approval-gated `notify`).
- Saving an edit bumps the bot's `revision`, so its durable definition version
  (`bot-<id>-r<revision>`) changes whenever behavior does. Knotra pins that version
  and composition, so editing a bot after a run is submitted blocks answering it as an
  incompatible checkpoint instead of silently changing behavior.
- Deleting is refused while a conversation references the bot.

The model `<select>` lists the catalog plus the offline fake, annotated with key
status:

| Model | Notes |
|---|---|
| `google:gemini-2.5-flash`, `google:gemini-2.5-pro` | `GOOGLE_API_KEY` (or `GEMINI_API_KEY`) |
| `openai:gpt-4o-mini` | `OPENAI_API_KEY` |
| `xai:grok-4.6` | `XAI_API_KEY` |
| `anthropic:claude-sonnet-4-5` | `ANTHROPIC_API_KEY` |
| `fake` | offline deterministic model, no key |

A bot's **system prompt** is passed to ReqLLM as the `system_prompt` model option, so
the provider receives a real system instruction (ReqLLM's `Context.normalize` prepends
it). The dashboard and the conversation form refuse to start while the selected
model's key is missing, so a bad configuration is readable instead of becoming a
redacted `plugin_exception` after acceptance.

Two bots are seeded when the `bots` table is empty, using the configured model
(`KNOTRA_BOTS_MODEL`, default `google:gemini-2.5-flash`):

- **Assistant** — the read-only `lookup` tool, a neutral prompt.
- **Concierge** — `lookup` and `notify`, with a prompt that proposes `notify` for
  requests to send a notice.

A `KNOTRA_BOTS_MODEL=fake` (or test) run seeds two offline bots, so the whole demo
runs with no key.

## Conversations

`/conversations` starts two bots on a topic for 2–8 rounds (default 4). Turn order is
bot A, bot B, alternating. Starting refuses with `Model not ready` when either bot's
model is not configured.

Relay mechanics:

- Each turn is **one durable `Knotra.submit/6`** with the deterministic submission key
  `conv-<conversation_id>-turn-<index>`. A retry or resume reuses the already-accepted
  execution instead of starting a duplicate.
- The turn input is the transcript:
  `"Topic: <topic>"` on the first turn, then
  `"Topic: <topic>\n\n<bot name>: <output>\n..."` with every completed turn.
- The runner polls `Knotra.snapshot/3` every ~100 ms until the turn is terminal.
  `completed` records the output and continues; `failed`/`blocked`, a `waiting`
  interaction, or a lost instance marks the turn and sets the conversation
  `interrupted`. There is no auto-answer in this cut.
- **Conversations are tool-free.** Every durable tool call requires a human approval,
  so a relay with tools would stall on the human gate. A bot's tools still apply to
  single dashboard runs. Read-only auto-approval / write pauses are a follow-up.
- **Stop** sets `stopping`; the runner stops before the next turn and sets `stopped`.
  An in-flight turn finishes, because Knotra does not expose cancellation of running
  work by durable id.
- **Resume** (allowed for `interrupted`/`stopped` with turns remaining) re-dispatches
  from the first turn that is not `completed`. A turn accepted but not yet polled keeps
  its deterministic key and execution id; a turn recorded `failed`/`blocked` is retried
  as a fresh attempt, and the unique `(conversation_id, index)` index keeps the turn
  count exact.
- Killing the supervised runner marks the conversation `interrupted`; the in-flight
  durable execution is owned by Knotra and finishes on its own. After a host restart,
  the coordinator's boot sweep marks runner-less `running`/`stopping` conversations
  `interrupted`/`stopped` so **Resume** is available.

Turns are text-only durable work: a zero-call model reply completes the execution with
that output, whether or not the bot exposes tools (Knotra supports a zero-call terminal
reply on the durable path).

## Models: Gemini or offline fake

The default model is `google:gemini-2.5-flash` through `Knotra.Models.ReqLLM`.
`GOOGLE_API_KEY` is ReqLLM's provider default; if only `GEMINI_API_KEY` is set it is
forwarded as the adapter's runtime `api_key:` option (an empty `GOOGLE_API_KEY` counts as
unset, so a half-filled `.env` still works).

Set `KNOTRA_BOTS_MODEL=fake` (or run `MIX_ENV=test mix test`) to use the offline
deterministic models, which need no key and make no network call: the dashboard's
clarify → propose model, and `KnotraBots.Models.ConversationFake` for conversations
(it echoes the last transcript line, so a later turn's output proves it saw earlier
turns). The test suite uses them.

With a real Gemini model, the concierge may call the read-only `lookup` tool and then
propose the approval-gated `notify`; both are allowlisted for this demonstration. Every
durable tool call requires an approval by design, including read-only ones.

## Restart-survival walkthrough

1. Submit a **concierge** execution. With the fake model it asks *"Which order should I look
   up?"*; with Gemini it will ask something similar.
2. Leave the question unanswered. The card shows a `waiting` badge and the answer form.
3. Stop the server with `Ctrl+C` (or restart the BEAM however you like).
4. Start it again with `mix phx.server` and reload the dashboard.
5. The pending execution is still listed from the database (`waiting`), with its form.
   Answer it, then approve the proposed `notify` operation.
6. The execution completes and exactly one line is appended to the notice file
   (`_build/notices.log` by default).

Knotra does not auto-recover on boot. The dashboard is what makes the pending durable
record visible again; answering it resumes the same execution with its preserved
counters.

For a conversation, the same idea applies at the relay level: kill the runner (or
restart the server), the conversation shows `interrupted` with its completed turns, and
**Resume** re-dispatches only the missing turns. On boot the coordinator sweeps any
runner-less `running`/`stopping` conversations into `interrupted`/`stopped`.

## What the UI shows

- **Dashboard (`/`)** — bot selector (populated from `bots`) and a message. Each run is
  submitted with a unique key and an observer pointed at the LiveView.
- **Execution cards** — short id (full id in `title`), status badge, definition version,
  turn/tool/retry/step counts, output or error, and the event timeline
  (sequence, type, elapsed ms).
- **Pending interaction** — a clarification prompt with an answer field, or an approval
  with the operation name and its validated arguments plus approve/reject buttons.
- **Bots (`/bots`)** — list, create, edit (bumps revision) and delete.
- **Conversations (`/conversations`)** — list with progress, and a form to start a new
  run. The detail page shows status, both bots, the topic, the turn timeline (index, bot,
  status, output, execution id) with a link to each execution's dashboard card, and
  Stop/Resume buttons. Live updates arrive via PubSub with a bounded ~1s refresh.
- **Live updates** — the observer sends `{:knotra, snapshot}` to the LiveView; a bounded
  ~1s refresh covers executions submitted by another session or resumed after a restart.
  There is also a manual **Refresh** button on the dashboard.

## Offline tests

```sh
cd examples/knotra_bots
mix test
```

No API key and no network are used: the tests force the fake model and cover the
concierge round-trip (clarify → approve `notify` → one notice line), the assistant
lookup leg (no notice), restart survival through the UI, rejection (no notice), bot
creation/editing, a full two-fake-bot conversation with transcript echo, interruption by
killing the runner followed by resume, stop, and per-model preflight.

## POC boundaries

- **Fake effect only.** `notify` appends a line to a local file. Do not allowlist a
  production operation.
- **Conversations are tool-free.** Adding tools needs read-only auto-approval or write
  pauses, which this cut deliberately leaves out.
- **Deleting a bot is refused while a conversation references it.** A pending single
  run of a deleted bot cannot be answered (the dashboard says so) because the
  definition can no longer be rebuilt; terminal runs stay inspectable.
- **SQLite, one instance.** Durable ownership is single-instance; this is not a
  distributed takeover protocol.
- **Migrations are host-run.** `mix knotra_bots.migrate` applies
  `Knotra.Persistence.Migration` (v1) and `KnotraBots.Persistence.Migration` (v2) through
  the host's own workflow, as ADR 0001 requires; the application never migrates
  automatically. A real host folds this into its deployment migration step with
  host-chosen versions.
- **Host-owned identities.** Knotra's public API has no list function, so the dashboard
  reads `id`/`status` from the host-owned `knotra_executions` table and then calls
  `Knotra.snapshot/3` per id; conversations keep their own `conversations` and
  `conversation_turns` tables and reference executions by id. A real host keeps such
  tables instead of reaching into the persistence table.
- **Demo access policy.** `KnotraBots.Access` allows only the `demo` tenant and derives
  the responder reference from `USER`. A real host derives tenant and responder from
  authenticated request data.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `GOOGLE_API_KEY` | — | ReqLLM's Gemini provider key |
| `GEMINI_API_KEY` | — | Used only when `GOOGLE_API_KEY` is unset |
| `KNOTRA_BOTS_MODEL` | `google:gemini-2.5-flash` | Model string for seeded/single runs; `fake` is offline |
| `KNOTRA_BOTS_PORT` | `4000` | HTTP port |
| `KNOTRA_BOTS_DB` | `_build/knotra_bots-<env>.sqlite3` | SQLite database path |
| `SECRET_KEY_BASE` | dev default | Cookie/session signing key |

`KNOTRA_BOTS_MODEL` sets the model seeded into the default bots; individual bots can use
any catalog model. The notice file lives next to the database under `_build/`; tests
override `config :knotra_bots, :notices_path` per test. Real environment variables take
precedence over `.env` values, so `KNOTRA_BOTS_PORT=5000 mix phx.server` works even
when `.env` has an empty `KNOTRA_BOTS_PORT=`.

## Troubleshooting

- **Execution fails at the model step** (`plugin_exception` / `model_error`) — Knotra
  redacts raw exception text from public records, so run `mix knotra_bots.check`. It
  prints the model status, the adapter result and the raw provider reason, e.g.
  `API key not valid` (400), API not enabled for the key/project (403), quota (429) or
  an unknown model. The server log also records raised exceptions and stacktraces.
  Common causes: an unfilled `.env` copied from `.env.example`, no `GOOGLE_API_KEY` /
  `GEMINI_API_KEY`, or a bot configured with a model whose key is missing. The submit and
  conversation forms refuse to start while the model is not configured, so this is
  usually visible before acceptance.
- **Offline** — set `KNOTRA_BOTS_MODEL=fake` to run everything without a key.
- **Migrations** — run `mix setup` (or `mix knotra_bots.migrate`) before the server.
  If you delete the SQLite file under `_build/`, run it again.
- **Port already in use** — set `KNOTRA_BOTS_PORT`.
