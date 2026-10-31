# ADR 0001 — Elixir + Phoenix as the application stack

**Status:** Accepted
**Date:** 2026-10-31
**Deciders:** Josep Marcello
**Related:** `docs/requirements.md` §7, D1

---

## Context

Ashiato ingests photographed Japanese text, enriches it against a dictionary service, records
vocabulary encounters, and schedules reviews. Four candidate stacks were considered seriously:
Python, Rust, Elixir/Phoenix, and JVM + Spring Boot. A fifth (Node/TypeScript) was considered and
dropped early.

The decision hinges on what the application actually spends its time doing, so start there.

### Workload shape

The app is **overwhelmingly I/O-bound, not compute-bound.** Nothing heavy runs in-process:

| Operation | Where the time goes |
|---|---|
| Ingest one page | 1 image upload, 1–2 OCR calls (seconds each), 1 tokenize call, 10–50 batched dictionary lookups, N translation calls (one per line) |
| Review a card | 1 row read, 1 row write. Sub-millisecond. |
| Coverage report | A handful of aggregate queries |
| Kanji map | One aggregate query |

Every expensive step is a **network round trip to someone else's process.** A single page generates
on the order of 10–50 sequential-ish external calls, each mostly idle. A batch of 40 manga pages
generates well over a thousand.

That ratio — many concurrent, mostly-sleeping operations — is the thing that decides the language.

### What was actually being chosen

Not "which language can do this" (all four can) but:

1. How cheaply can we hold hundreds of in-flight, mostly-idle operations?
2. What happens when one of them fails?
3. How much of the UI do we build ourselves?

---

## Decision

**Elixir 1.18 / OTP 27, Phoenix 1.8, LiveView, Ecto with SQLite in development and Postgres in
production.**

---

## Reasons

**1. The runtime is built for exactly this workload.**
The BEAM runs millions of lightweight processes with preemptive scheduling and per-process garbage
collection. An in-flight OCR call is a process that costs a few hundred bytes and is parked on a
socket. There is no thread-pool to size, no event-loop to starve, and one slow call cannot block
another. In a thread-per-request model the same load forces a queue-sizing decision that is wrong at
every scale except the one you happened to test.

**2. Failure is isolated by construction.**
Ingest is a pipeline of external calls, so partial failure is the normal case: OCR fails on page 7 of
40, the dictionary service times out, a translation returns garbage. A supervised job that crashes is
restarted or dead-lettered on its own, without taking down the request that uploaded the page. In
Python or Java this is exception plumbing you write and maintain; here it is the default behaviour of
`Task.Supervisor` and `DynamicSupervisor`.

**3. Streaming progress is nearly free.**
R1.8/R2.1 need the UI to update as each stage and each line completes. `Phoenix.PubSub` plus LiveView
gives server-pushed incremental updates with no SSE layer, no websocket client, and no client-side
state duplication. The alternative in any other stack is a JS frontend, an API boundary, and
serialisation of state that already exists in the database.

**4. No separate frontend.**
LiveView renders stateful UI on the server. For a data-dense, form-heavy, single-user app this removes
an entire build toolchain, an API contract, and a whole class of client/server state bugs. The app is
one deployable unit.

**5. Ecto has the best dual-database story of the four.**
The requirement is SQLite locally and Postgres in production, with migrations that run unchanged on
both. Ecto's type system does the mapping: `:boolean` → 0/1 or `bool`, `:utc_datetime` → text or
`timestamptz`, `:binary_id` → text or `uuid` (generated client-side, so no Postgres extension is
needed). Spring/Hibernate's SQLite dialect is second-class; Diesel and SQLx require per-dialect
migration directories; Alembic requires hand-written dialect conditionals.

**6. Iteration speed matters more than peak performance here.**
This is a personal app whose requirements are still moving. A fast edit-compile-test loop and a
supervision model that lets you change a pipeline stage in isolation are worth more than raw
throughput the app will never saturate.

---

## Honest costs

These are real, and were accepted rather than argued away.

**No trustworthy Japanese tokenizer in Elixir.** Checked rather than assumed: `mecab` on Hex is a
binding last released in **2018**; `kiri` reads Sudachi binary dictionaries in pure Elixir with POS and
reading forms, but it is **v0.2.0 with 319 downloads all-time**, first released February 2026. The
credible native path is `sudachi.rs` through Rustler — the same Rust implementation whose Python
bindings are SudachiPy — which costs a Rust toolchain and NIF packaging in the build.

So tokenization is an HTTP endpoint on the Python dictionary service. The `sudachi.rs` NIF remains a
possible later replacement and would remove the hop, but it buys nothing now: one call per page, to a
service that must run regardless for the dictionary.

OCR is a second Python service for the same underlying reason — PaddleOCR only exists in Python — and
it has to be resident, because loading PP-OCRv6 medium takes seconds per process.

**This reframes the whole decision.** A Python process is unavoidable no matter what the app is
written in, so the real question was never "Elixir versus Python" but "which language for the layer
that is not Python". The app layer is exactly where Elixir pays for itself.

**The BEAM is weak at tight numeric loops.** No SIMD, no native threads for compute. Irrelevant today
because every compute step is a remote call — but it is the reason this decision would need revisiting
if OCR ever moved in-process (on-device inference, requirement §12).

**Smaller talent pool and fewer niche libraries.** For a single-user personal project, the cost of
this is near zero. It would matter for a team.

**One more dependency to add.** Background jobs need Oban (not yet in `mix.exs`) or a hand-rolled
queue on `Task.Supervisor`. That is a real piece of work, not a freebie.

---

## Alternatives rejected

**Python (FastAPI + asyncio).** The best libraries by a wide margin, and the closest call. Rejected
because once OCR, tokenization, and translation are all HTTP calls, Python's ecosystem advantage
evaporates — the app itself becomes a CRUD-and-orchestration layer, which is exactly where the BEAM is
stronger. There is also no LiveView equivalent: you would write the frontend and the API boundary
separately.

**Rust (Axum + SQLx).** Fastest, lowest memory, strongest type safety, single binary, and it has
`sudachi.rs` and `fsrs.rs` natively. Rejected on iteration cost: for a personal app in flux, writing
the web layer, the forms, and the realtime updates by hand buys throughput that will never be needed.
This is the decision most likely to be revisited if the app ever needs to run offline or on-device.

**JVM + Spring Boot.** Most ceremony, slowest edit-compile-test loop, weakest SQLite story, and no
advantage on any axis that matters here — the workload is I/O fan-out, not transactional enterprise
throughput.

**Node/TypeScript.** Genuinely pragmatic for the UI and ecosystem-rich. Rejected for a weaker
concurrency model (single-threaded event loop) and no supervision/restart semantics for the ingest
pipeline.

---

## Consequences

- Ingest and translation are background jobs with published progress, not request-blocking work
  (requirements §9)
- Two Python services sit beside the app: the dictionary + tokenizer (`jp-dict-api`), and a resident
  OCR service (requirements §7.1–7.3)
- The `sudachi.rs` NIF is the one path that would remove a service later (§12)
- UI is LiveView; there is no separate frontend build
- Add Oban (or equivalent) before the first ingest pipeline lands
- Revisit this ADR if OCR moves in-process or if the app must run offline
- **The strongest argument against this decision:** every heavy dependency is Python-shaped (OCR,
  tokenization) and the dictionary service must run regardless of what the app is written in. If the
  owner decides that zero external services is worth more than LiveView and supervision, a Python
  monolith is the correct answer and this ADR should be superseded, not defended. The decision below
  survives only because the service is a foregone conclusion, which makes the extra hop nearly free.
