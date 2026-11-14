# Wave 2.5 — shared HTTP transport

**Status:** proposed
**Baseline:** `2a325a40a88612712a1ab2595e4615af39f7a8e3`, branch `wave-2-5-shared-http`, clean tree
**Source card:** `docs/plan/wave-2.5.md`

## Problem

Three outbound clients own their own HTTP transport:

- `Ashiato.Tokenizer.Http` uses `Req.post!/2` plus a local `rescue` for transport, HTTP, and JSON errors.
- `Ashiato.Dictionary.Http` builds its own `Req` request, sets its own timeouts, and maps errors locally.
- `Ashiato.Translator.http_post/2` builds another request, validates its own URL, and maps errors locally.

The copies have drifted. Only the tokenizer and dictionary set timeouts. Only the tokenizer and
dictionary accept `:plug` injection. Error shapes differ: `{:unexpected_status, status}` in two
clients, `{:http, status}` in one. A malformed JSON reply is `:invalid_json` in one client and
`:unparsable` in another. A transport reason is sanitized in two clients and trusted in one.

This duplication makes each new outbound client re-learn the same rules, and it lets those rules
diverge again.

## Goal

One module, `Ashiato.HTTP`, at `lib/ashiato/outbound/http.ex`, is the only module that calls `Req`.
Every outbound service sends its requests through it. Service-specific parsing, validation, cache
behaviour, provider fallback, and credentials stay in the service clients.

## Non-goals

- No tokenizer, dictionary, translator, OCR, or storage response shapes inside `Ashiato.HTTP`.
- No retries, backoff, redirects, circuit breaking, or connection pooling policy beyond what the card states.
- No new dependencies. `Req` and `Jason` are already present.
- No migrations, schema changes, or `config/` changes.
- No translation caching and no S3 storage work.
- No changes to behaviour callbacks or public service function signatures.
- No S3 presigning, OCR socket work, or settings work.

## Acceptance criteria

Each criterion names the check that proves it. Tests use `Req.Test`; no test opens a socket or calls
a real service.

| ID | Criterion | Verified by |
|---|---|---|
| AC-1 | `Ashiato.HTTP.get/2` and `post/2` accept only absolute `http`/`https` URLs with a non-empty host. A malformed URL, a missing scheme, or another scheme returns `{:error, :invalid_url}` without calling Req. | `mix test test/ashiato/http_test.exs` |
| AC-2 | A 200 JSON reply returns `{:ok, decoded_body}`. A 200 text reply returns `{:ok, binary}`. The caller owns the shape check. | `mix test test/ashiato/http_test.exs` |
| AC-3 | Any non-200 reply returns `{:error, {:http, status}}` and never the body. | `mix test test/ashiato/http_test.exs` |
| AC-4 | A transport failure returns `{:error, {:transport, reason}}` where `reason` is an atom. A provider or protocol binary reason is reduced to `:unknown`. | `mix test test/ashiato/http_test.exs` |
| AC-5 | A malformed JSON reply returns `{:error, :invalid_json}`. The response body never appears in the error term, a log line, or an exception. | `mix test test/ashiato/http_test.exs` |
| AC-6 | Requests always set `retry: false` and `redirect: false`, proven behaviorally: a 302 and a 500 each run the plug exactly once. `:receive_timeout` and `:request_timeout` default to `10_000` ms and accept overrides; no test seam is exposed, so this part is verified by code inspection. `:plug` is forwarded so a test needs no socket. | `mix test test/ashiato/http_test.exs`; code inspection of the private request-option builder |
| AC-7 | `Ashiato.Tokenizer.Http` calls `Ashiato.HTTP` and keeps its token parsing and hiragana normalisation. Its HTTP test still passes through `:plug`, and a non-200 reply is asserted as `{:error, {:http, status}}`. | `mix test test/ashiato/tokenizer_test.exs` |
| AC-8 | `Ashiato.Dictionary.Http` calls `Ashiato.HTTP` and keeps its reply validation, batch fan-out, and cache payloads. Its `:plug` tests still pass. A malformed JSON reply surfaces as `{:error, :invalid_json}`. | `mix test test/ashiato/dictionary_test.exs` |
| AC-9 | `Ashiato.Translator.http_post/2` delegates to `Ashiato.HTTP`, keeps the per-provider `decode/1` functions and the page fallback rule, and passes the configured `:plug` through. A malformed JSON reply maps to `{:error, :unparsable}` so the per-line fallback still runs. | `mix test test/ashiato/translator_test.exs` |
| AC-10 | `Ashiato.Translator.GoogleFree` is exercised through its real parser with `Req.Test`: the documented nested wire shape returns `{:ok, ["hello"]}` for `["こんにちは"]`. | `mix test test/ashiato/translator_test.exs` |
| AC-11 | After migration, no module under `lib/ashiato/outbound/` other than `http.ex` contains a `Req` call. | `rg -n "Req\.(new|request|post!?|get!?)" lib/ashiato/outbound --glob '!http.ex'` returns no matches |
| AC-12 | The full gate passes. | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix precommit` |

## Constraints

- No new dependencies, no `mix.exs` changes, no lockfile changes.
- No `config/` edits. `:plug` is read from each service's existing application config.
- No migrations and no `priv/repo/` edits.
- May edit only: `lib/ashiato/outbound/http.ex` (new), `test/ashiato/http_test.exs` (new),
  `lib/ashiato/outbound/tokenizer/http.ex`, `lib/ashiato/outbound/dictionary/http.ex`,
  `lib/ashiato/outbound/translator.ex`, and their tests under `test/ashiato/`.
- No push, no PR.
- Never log URLs, request bodies, headers, credentials, translated text, or page text.
- All error terms crossing the transport boundary must be safe to log: atoms and integers only.
- Existing public behaviour callbacks and function signatures stay unchanged.
- Tests that write application env stay `async: false`.

## Context

The repository is a Phoenix 1.8 / Elixir 1.17 app using `Req` 0.7.5 and SQLite in test. The
outbound directory layout is fixed by `AGENTS.md`, which already names
`lib/ashiato/outbound/http.ex` as the sole `Req` caller.

Baseline checks on the worktree are green: `mix format --check-formatted` exit 0,
`mix compile --warnings-as-errors` exit 0, `mix test` 180 tests, 0 failures. `mix test` emits one
transient `Exqlite.Error: database is locked` log while connecting; it does not fail the run.

**Amendment 2026-11-15:** ERTS call tracing is disabled on this host (`:erlang.trace` and `:dbg`
deliver no messages), so AC-6's timeout defaults are verified by code inspection instead of a test
seam. `retry` and `redirect` remain behaviorally tested.
