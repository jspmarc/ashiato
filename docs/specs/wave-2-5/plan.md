# Wave 2.5 — implementation plan

**Spec:** `docs/specs/wave-2-5/spec.md`
**Baseline:** `2a325a40a88612712a1ab2595e4615af39f7a8e3`, branch `wave-2-5-shared-http`
**Status:** awaiting expert review

## Approach

Add `Ashiato.HTTP` as the single `Req` boundary, with a fixed request policy and a small error
taxonomy. Migrate the three clients to it one at a time, keeping each service's parsing and
validation where it is. Map the shared `:invalid_json` atom at the two service boundaries that have
their own contract: the dictionary exposes it, the translator converts it to `:unparsable` so the
existing per-line fallback still runs. Prove the transport with `Req.Test` and prove one real
provider parser with `Req.Test` too.

## Rejected alternatives

- **Leave the three clients alone and share helper functions.** Rejected: the drift returns the
  moment a fourth client copies the helpers, and nothing enforces a single `Req` caller.
- **Move service reply parsing into `Ashiato.HTTP`.** Rejected: couples every service shape into
  infrastructure and violates the spec's non-goals.
- **Make the clients build `%Req.Request{}` and pass it in.** Rejected: exposes `Req` structs to
  callers and keeps the transport rules spread across files.
- **Use `Req`'s default retry and redirect policy.** Rejected: a retried POST can duplicate work,
  and a redirect can send credentials to another host.

## Change surface

| Path | Status | Owner task |
|---|---|---|
| `lib/ashiato/outbound/http.ex` | new | T1 |
| `test/ashiato/http_test.exs` | new | T1 |
| `lib/ashiato/outbound/tokenizer/http.ex` | edit | T2 |
| `test/ashiato/tokenizer_test.exs` | edit | T2 |
| `lib/ashiato/outbound/dictionary/http.ex` | edit | T3 |
| `test/ashiato/dictionary_test.exs` | edit | T3 |
| `lib/ashiato/outbound/translator.ex` | edit | T4 |
| `test/ashiato/translator_test.exs` | edit | T4 |

No other source file changes. `docs/specs/wave-2-5/` is the only documentation surface.

## Interfaces

### `Ashiato.HTTP`

```elixir
@spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
@spec post(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
def get(url, opts \\ [])
def post(url, opts \\ [])
```

Both functions guard the arguments: a non-binary `url` returns `{:error, :invalid_url}` without
raising, and a non-keyword `opts` list returns `{:error, :invalid_options}`. The guard runs before
URL parsing, so `URI.new/1` never receives a non-binary value.

Accepted options, and nothing else:

| Option | Behaviour |
|---|---|
| `:headers` | forwarded to `Req` |
| `:json` | forwarded to `Req` |
| `:form` | forwarded to `Req` |
| `:params` | forwarded to `Req` |
| `:receive_timeout` | default `10_000` |
| `:request_timeout` | default `10_000` |
| `:plug` | forwarded unchanged for `Req.Test` |

Fixed policy: `retry: false`, `redirect: false`. The function drops any caller-supplied `:retry` or
`:redirect` so a caller cannot widen the policy.

Returns:

- `{:ok, body}` on 200; `body` is decoded JSON or a binary, caller checks the shape.
- `{:error, :invalid_url}` when `URI.new/1` fails, the scheme is not `http`/`https`, or the host is
  missing or empty. `Req` is not called.
- `{:error, {:http, status}}` on any other status. The body is discarded.
- `{:error, {:transport, reason}}` on `Req.TransportError` or `Req.HTTPError`, with `reason` an
  atom; non-atom reasons become `:unknown`. `Req.HTTPError` is an HTTP protocol failure, so it
  belongs to AC-4, not the request-policy bucket.
- `{:error, :invalid_json}` on `Jason.DecodeError`. The `data` field is discarded.
- `{:error, :request_failed}` for any other rescued exception, so the boundary never raises.

No logging in this module.

### Client mappings

| Client | Shared error | Client result |
|---|---|---|
| `Ashiato.Tokenizer.Http` | `:invalid_url` | unchanged |
| | `:invalid_json` | unchanged |
| | `{:http, status}` | replaces `{:unexpected_status, status}` |
| | `{:transport, reason}` | unchanged |
| `Ashiato.Dictionary.Http` | `:invalid_json` | exposed as `:invalid_json` (new) |
| | `{:http, status}` | replaces `{:unexpected_status, status}` |
| | `{:transport, reason}` | unchanged |
| `Ashiato.Translator.http_post/2` | `:invalid_json` | mapped to `:unparsable` |
| | `{:http, status}` | unchanged |
| | `{:transport, reason}` | unchanged |
| | `:request_failed` | unchanged |

Dictionary keeps `:base_url_not_configured` and `:invalid_base_url` for the base URL it owns.
Translator keeps `:no_decoder`, `:invalid_url`, and the cooldown rule.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| The card's GoogleFree fixture is reversed: `[[["こんにちは","hello"]], nil, "ja"]` makes the real parser return `{:ok, ["こんにちは"]}`, not `["hello"]`, because Google's first field is the translated text. | Use `[[["hello","こんにちは"]], nil, "ja"]` in the AC-10 test. Do not change `decode/1`; changing it would break the real API mapping. |
| Req emits no telemetry and ERTS call tracing is disabled on this host (`:erlang.trace` and `:dbg` deliver nothing), so timeout defaults cannot be asserted from a response or a trace. | Keep the request-option builder private. Assert `retry`/`redirect` behaviorally and verify timeout defaults by code inspection; AC-6 records this limit. |
| A catch-all rescue hides real bugs. | Rescue `Req.TransportError`, `Req.HTTPError`, and `Jason.DecodeError` explicitly; use one final catch-all that returns `:request_failed` without logging. |
| `URI.new/1` can raise on a non-binary argument before the rescue. | Guard `is_binary(url)` at the public function head; a non-binary URL returns `:invalid_url`. A non-keyword `opts` list returns `:invalid_options`. |
| Malformed JSON changes the dictionary test from `:unexpected_response` to `:invalid_json`. | Update that assertion and keep dictionary reply-shape validation returning `:unexpected_response`. |
| The tokenizer test asserts `{:unexpected_status, 500}`. | Update to `{:error, {:http, 500}}`. |
| `:plug` from caller and application config can collide. | Translator keeps `Keyword.put_new/3`; explicit caller option wins. Dictionary and tokenizer read only config. |
| Redirect/retry tests could be slow if policy is wrong. | Use one 302 response with a call counter and one 500 response with a call counter; assert one call and the mapped error. |
| `URI.new/1` may accept some surprising URLs. | Cover `not a url`, `lt.example.com`, `ftp://example.com`, and `https://` (empty host) explicitly. |
| A rescued exception message can carry a URL, body, or header. | Never build an error term from an exception message; only atoms, status integers, and `:unknown`. |

## Baseline checks

Run in `/home/robin/Projects/ashiato/.worktrees/wave-2-5` at `2a325a4`:

- `git status --short --untracked-files=all` before the spec: empty.
- `mix format --check-formatted`: exit 0.
- `mix compile --warnings-as-errors`: exit 0.
- `mix test`: 180 tests, 0 failures.
- Known noise: `Exqlite.Connection ... database is locked` once while the test pool connects. It does
  not fail the run.
- `mix deps.get` was required in this fresh worktree; it resolved from the existing `mix.lock`.

No existing failure blocks this plan.

## Tasks

| ID | Satisfies | Read first | Deliverable | Done when | Verification | Depends on | Parallel-safe |
|---|---|---|---|---|---|---|---|
| T1 | AC-1, AC-2, AC-3, AC-4, AC-5, AC-6 | `lib/ashiato/outbound/tokenizer/http.ex`, `lib/ashiato/outbound/dictionary/http.ex`, `lib/ashiato/outbound/translator.ex` | `Ashiato.HTTP` with `get/2`, `post/2`, argument guards, and `test/ashiato/http_test.exs` covering every branch | URL gate, argument guards, 200 JSON/text, status mapping, `Req.TransportError` and `Req.HTTPError` sanitization, malformed JSON, fixed policy behaviorally, and `:plug` are exercised; timeout defaults are code-inspected | `mix test test/ashiato/http_test.exs`; code inspection of the private request-option builder | none | no |
| T2 | AC-7 | `lib/ashiato/outbound/tokenizer/http.ex`, `test/ashiato/tokenizer_test.exs`, `lib/ashiato/outbound/http.ex` | Tokenizer uses `Ashiato.HTTP.post/2`; local rescue, `safe_reason/1`, and `Req` builder removed; base URL is trimmed before appending `/tokenize`; status assertion updated; stale `Req.post!` moduledoc removed | Tokenizer tests pass through `:plug`; a trailing-slash base URL test passes; no direct `Req` reference remains in the file | `mix test test/ashiato/tokenizer_test.exs` | T1 | no |
| T3 | AC-8 | `lib/ashiato/outbound/dictionary/http.ex`, `test/ashiato/dictionary_test.exs`, `lib/ashiato/outbound/http.ex` | Dictionary uses `Ashiato.HTTP.get/2`; local `safe_reason/1` and request error mapping removed; validation, batching, and cache untouched | `:plug` tests pass; malformed JSON asserts `:invalid_json`; no direct `Req` call remains | `mix test test/ashiato/dictionary_test.exs` | T1 | no |
| T4 | AC-9, AC-10 | `lib/ashiato/outbound/translator.ex`, `lib/ashiato/outbound/translator/google_free.ex`, `test/ashiato/translator_test.exs`, `lib/ashiato/outbound/http.ex` | `http_post/2` delegates to `Ashiato.HTTP.post/2`; `:invalid_json` maps to `:unparsable`; GoogleFree parser test added | Translator tests pass; GoogleFree returns `{:ok, ["hello"]}` through its real parser; no direct `Req` call remains in `translator.ex` | `mix test test/ashiato/translator_test.exs` | T1 | no |
| T5 | AC-11, AC-12 | all edited files, `AGENTS.md`, `mix.exs` | Migration audit: no service owns a `Req` call, `Req` struct, or transport rescue; docs in edited files match the new path | Grep finds no `Req` reference outside `http.ex`; full gate passes | `rg -n "\bReq\b" lib/ashiato/outbound --glob '!http.ex'` returns no matches; `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix test`; `mix precommit` | T2, T3, T4 | no |

## Coverage

| AC | Task |
|---|---|
| AC-1 | T1 |
| AC-2 | T1 |
| AC-3 | T1 |
| AC-4 | T1 |
| AC-5 | T1 |
| AC-6 | T1 |
| AC-7 | T2 |
| AC-8 | T3 |
| AC-9 | T4 |
| AC-10 | T4 |
| AC-11 | T5 |
| AC-12 | T5 |

No uncovered criterion.

## Constraints

Inherited from the spec:

- No new dependencies, no `mix.exs` or lockfile changes.
- No `config/` changes, no migrations, no `priv/repo/` changes.
- Only the paths in the change surface may be edited.
- No push, no PR.
- No test may call a real service or open a socket.
- Never log URLs, bodies, headers, credentials, page text, or translated text.
- Error terms crossing the transport boundary contain only atoms and integers.

## Expert findings

| Finding | Pass | Decision | Reason |
|---|---|---|---|
| F1 — `Req.HTTPError` fell through to `:request_failed` | 1 | Accept | Protocol failures are AC-4 transport failures; map both `Req.TransportError` and `Req.HTTPError` to `{:error, {:transport, atom}}`. |
| F2 — non-binary URL / non-keyword opts could raise before rescue | 1 | Accept | Guard at the public function head; `:invalid_url` for a bad URL, `:invalid_options` for bad opts. |
| F3 — reject `userinfo` in URLs | 1 | Reject | Would tighten AC-1 beyond the approved spec; configuration is trusted and this stays out of scope. |
| F4 — tokenizer base URL trailing slash | 1 | Accept | Use the codebase pattern: `String.trim_trailing/2` before appending `/tokenize`, matching `Dictionary.Http` and `Translator.Llm`. |
| F5 — AC-11 grep too narrow; stale moduledoc | 1 | Accept | Check every `Req` reference under `lib/ashiato/outbound` and remove the stale `Req.post!` mention. |
| F6 — timeout-default test seam | 1 | Accept | Keep the `Req.new/1` trace, scoped strictly to `self()` and cleared on exit. |
| F6 — tracing unavailable on this host | 3 | Superseded | ERTS call tracing delivers nothing. User chose a private option builder with no test seam; AC-6 now verifies timeout defaults by code inspection only. |
| Re-review — AC-6 amendment and T1 alignment | 3 | Ready | No new findings; verdict `ready`. |
| Re-review — all first-pass findings resolved | 2 | Ready | No new findings; verdict `ready`. |
