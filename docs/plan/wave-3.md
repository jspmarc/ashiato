# Wave 3 — the ingest pipeline

Read `AGENTS.md` first; it wins over anything here.

**Depends on:** all of `wave-2.md` (the six clients), `wave-2.5.md` (shared HTTP transport), and on Wave 1's ledger functions
(`find_or_create_lexeme/3`, `record_encounter/1`, `chrome_ratio/2`). Do not start this card until both
exist — the pipeline has nothing to call otherwise.

## How to work this card

- **This card owns `lib/ashiato/ingest*` and `test/ashiato/ingest_test.exs`.** It changes no other
  module except to read from them.
- Gate: `mix format` → `mix compile --warnings-as-errors` → `mix test` → `mix precommit`.
- Tests only for public functions, per `AGENTS.md`.
- No new dependencies: `Oban` is already in `mix.exs`.
- Do not edit `priv/repo/migrations/`.

## Model

Use `neuralwatt/qwen3.6-35b-flex`. This card is a state machine with concurrency and a fencing token —
exactly the kind of work that fails quietly on a weaker model, and a wrong fence silently corrupts pages.

---

## W3-1 — Oban worker and page status machine

States must be exactly the CHECK values on `pages.status`:

```
uploaded → detecting → text_ready → translating → ready
                ↘           ↘            ↘
                          failed
```

`text_origin = "embedded"` (a text-layer PDF) skips `detecting` and goes straight to `text_ready`.

### Required behaviour, each with its own test

**1. Revision fencing.** The job reads `pages.revision` when it starts and carries it. Every write is
conditional:

```sql
UPDATE pages
   SET status = ?, accepted_text = ?, ...
 WHERE id = ? AND revision = ?
```

Zero rows affected means a correction landed while the job was working: the job **discards its own
result** and logs that it was superseded. It must never overwrite newer work, and it must never raise.

**2. Tokenise and translate run concurrently.** Both depend only on `accepted_text`; only OCR is a hard
predecessor. Run them with `Task.async`/`Task.await` (or `Task.async_stream`) and prove the concurrency
with a fake that refuses to return until the other has started.

**3. Every token is validated.** Drop particles, auxiliaries and anything absent from the dictionary.
Content words become encounters through `Ledger.record_encounter/1`. Do not write to the encounters
table directly — the ledger owns that identity.

**4. Nothing is marked confirmed by the pipeline** unless it was actually verified. R2.8 says unconfirmed
counts toward nothing; the pipeline must not defeat that by defaulting to `true`.

**5. Progress events** on `Ashiato.PubSub` as each stage completes and as each translated line lands, so
the UI can fill in rather than block on the slowest step.

**6. Failure is contained.** A stage failure leaves the page in `failed` with prior artefacts intact, and
never rolls back encounters already written. An OCR failure must not lose the uploaded image.

### Acceptance

Tests that drive the fakes through three paths:

- the happy path, asserting the final `status` and the encounters written
- a **superseded** path: bump `revision` mid-flight, assert the job discarded its result and the page
  kept the newer text
- an **OCR failure** path: assert `status = failed`, the prior artefacts survive, and no encounters were
  rolled back

Prefer calling `perform/1` directly over `Oban.Testing` unless the latter is already configured; either
way the assertions are about pages and encounters, not about Oban internals.

---

## Definition of done

```
mix format
mix compile --warnings-as-errors
mix test
mix precommit
```

The concurrency test is the one that matters: if it would still pass with the two calls run
sequentially, it is not testing anything.
