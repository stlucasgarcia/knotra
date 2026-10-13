# KnotraBots

A runnable example host for [Knotra](../../README.md): a Phoenix LiveView dashboard
that visualizes durable bot executions.

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

The only side effect is a fake append-only notice file. Nothing is sent anywhere.
The [library documentation](../../README.md) stays authoritative for the full
contract; this README is a tour of the demo.

## Quickstart

```sh
cd examples/knotra_bots
mix setup                        # deps.get + host-applied migration
export GOOGLE_API_KEY=...        # or: cp .env.example .env and fill in one key
mix phx.server                   # http://localhost:4000
```

Then choose a bot, type a message and press **Run**.

`.env` (copied from `.env.example`) is loaded in `config/runtime.exs` when present.

## Models: Gemini or offline fake

The default model is `google:gemini-2.5-flash` through `Knotra.Models.ReqLLM`.
`GOOGLE_API_KEY` is ReqLLM's provider default; if only `GEMINI_API_KEY` is set it is
forwarded as the adapter's runtime `api_key:` option (an empty `GOOGLE_API_KEY` counts as
unset, so a half-filled `.env` still works).

Set `KNOTRA_BOTS_MODEL=fake` (or run `MIX_ENV=test mix test`) to use
`KnotraBots.Models.Fake`, a deterministic offline model that needs no key and makes no
network call. The test suite uses it.

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

## What the UI shows

- **New execution form** — bot selector (`assistant` / `concierge`) and a message. The
  execution is submitted with a unique key and an observer pointed at the LiveView.
- **Execution cards** — short id (full id in `title`), status badge, definition version,
  turn/tool/retry/step counts, output or error, and the event timeline
  (sequence, type, elapsed ms).
- **Pending interaction** — a clarification prompt with an answer field, or an approval
  with the operation name and its validated arguments plus approve/reject buttons.
- **Live updates** — the observer sends `{:knotra, snapshot}` to the LiveView; a bounded
  ~1s refresh covers executions submitted by another session or resumed after a restart.
  There is also a manual **Refresh** button.

## Offline tests

```sh
cd examples/knotra_bots
mix test
```

No API key and no network are used: the tests force the fake model and cover the
concierge round-trip (clarify → approve `notify` → one notice line), the assistant
lookup leg (no notice), restart survival through the UI, and rejection (no notice).

## POC boundaries

- **Fake effect only.** `notify` appends a line to a local file. Do not allowlist a
  production operation.
- **SQLite, one instance.** Durable ownership is single-instance; this is not a
  distributed takeover protocol.
- **Migrations are host-run.** `mix knotra_bots.migrate` applies
  `Knotra.Persistence.Migration` through the host's own workflow, as ADR 0001 requires;
  the application never migrates automatically. A real host folds this into its
  deployment migration step with a host-chosen version.
- **Host-owned identities.** Knotra's public API has no list function, so the dashboard
  reads `id`/`status` from the host-owned `knotra_executions` table and then calls
  `Knotra.snapshot/3` per id. A real host keeps its own identity/conversation table
  instead of reaching into the persistence table.
- **Demo access policy.** `KnotraBots.Access` allows only the `demo` tenant and derives
  the responder reference from `USER`. A real host derives tenant and responder from
  authenticated request data.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `GOOGLE_API_KEY` | — | ReqLLM's Gemini provider key |
| `GEMINI_API_KEY` | — | Used only when `GOOGLE_API_KEY` is unset |
| `KNOTRA_BOTS_MODEL` | `google:gemini-2.5-flash` | Model string; `fake` is offline |
| `KNOTRA_BOTS_PORT` | `4000` | HTTP port |
| `KNOTRA_BOTS_DB` | `_build/knotra_bots-<env>.sqlite3` | SQLite database path |
| `SECRET_KEY_BASE` | dev default | Cookie/session signing key |

The notice file lives next to the database under `_build/`; tests override
`config :knotra_bots, :notices_path` per test. Real environment variables take
precedence over `.env` values, so `KNOTRA_BOTS_PORT=5000 mix phx.server` works even
when `.env` has an empty `KNOTRA_BOTS_PORT=`.

## Troubleshooting

- **Execution fails at the model step** (`plugin_exception` / `model_error`) — Knotra
  redacts raw exception text from public records, so run `mix knotra_bots.check`. It
  prints the model status, the adapter result and the raw provider reason, e.g.
  `API key not valid` (400), API not enabled for the key/project (403), quota (429) or
  an unknown model. The server log also records raised exceptions and stacktraces.
  Common causes: an unfilled `.env` copied from `.env.example`, no `GOOGLE_API_KEY` /
  `GEMINI_API_KEY`, or a bad `KNOTRA_BOTS_MODEL`. The submit form refuses to start
  while the model is not configured, so this is usually visible before acceptance.
- **Offline** — set `KNOTRA_BOTS_MODEL=fake` to run everything without a key.
- **Migrations** — run `mix setup` (or `mix knotra_bots.migrate`) before the server.
  If you delete the SQLite file under `_build/`, run it again.
- **Port already in use** — set `KNOTRA_BOTS_PORT`.
