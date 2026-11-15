# Wave 2.6 — Cleanup

**Status:** proposed
**Baseline:** `641d5fbbe5c96211f6cb5aed4c8cee34519d2546`, branch `wave-2-6-cleanup`, clean tree
**Source:** code-quality scan, session `ses_e231258ecffeJ4dpK6Ir9k2ozk`

## Problem

The scan found eight defects. Seven hold against the code; the symlink item does not. Separately, the
repo carries low-value single-use helpers, an outbound module that owns database queries, N+1 chrome
detection, fixtures that create invalid ownership, cooldowns that couple unrelated credentials, and
no PostgreSQL test run even though production uses PostgreSQL.

## Goal

Fix the seven valid defects. Inline the low-value helpers while keeping the FSRS formulas, behaviour
callbacks, and resource-cleanup boundaries. Move dictionary persistence into a context. Remove the
chrome N+1, fix fixture ownership, scope cooldowns by credential, and run the full suite against
PostgreSQL in CI.

## Non-goals

- No symlink or realpath hardening. Keys are app-generated, `valid_key?/1` already blocks traversal,
  and an exploit needs write access to the storage volume. Any pre-check is TOCTOU; the real fix
  (`O_NOFOLLOW`/`openat`) is not worth it here.
- No inlining of `initial_stability/1`, `lapse_delta/1`, `add_days/2`, behaviour callbacks, or
  resource-cleanup boundaries.
- No migrations, schema changes, or new dependencies.
- No pipeline wiring: no Oban workers, routes, LiveViews, or controllers.
- No S3, presigning, or translation-cache work.

## Acceptance criteria

| ID | Criterion | Verified by |
|---|---|---|
| AC-1 | Production selects `Oban.Engines.Basic`; the test environment selects Basic when the adapter is PostgreSQL and Lite only for SQLite. | config inspection; `mix test test/ashiato/config_test.exs` |
| AC-2 | `Ledger.finish_page/2` and `Ledger.transition/2` fence the write on `id`, `revision`, and expected status. A stale struct returns `{:error, :superseded}` and writes nothing; a valid move still succeeds. `transition/2` documents the added error. | `mix test test/ashiato/ledger_test.exs` |
| AC-3 | Re-storing an existing secret without `secret: true` keeps the row encrypted; `Settings.all/1` still returns `:redacted`. Explicit `secret: false` declassifies. | `mix test test/ashiato/settings_test.exs` |
| AC-4 | Two concurrent reviews of the same word on PostgreSQL both apply: `reps` advances by two, both events exist, and the second schedule is computed from the first. Serialization uses a row lock on PostgreSQL only; SQLite behaviour is unchanged. | `mix test --include postgres test/ashiato/ledger_test.exs` on the PG job |
| AC-5 | `find_or_create_word/2` and `find_or_create_lexeme/3` resolve a lost insert race without a failing refetch inside an aborted transaction. Concurrent force-introduction on PostgreSQL creates exactly one row per identity and raises nothing. | `mix test --include postgres test/ashiato/ledger_test.exs` on the PG job |
| AC-6 | `Translator.Llm` reads the key only from `opts[:api_key]` and returns `{:error, :not_configured}` without it; it never reads `OPENAI_API_KEY`. `Settings.credential/2` is public and applies the stored-row-then-environment precedence used by `ai_capable?/1`. | `mix test test/ashiato/translator_test.exs test/ashiato/settings_test.exs` |
| AC-7 | `find_or_create_lexeme/3` accepts a `nil` part of speech: no raise, stored as `""`, and a repeated call returns the same row. | `mix test test/ashiato/ledger_test.exs` |
| AC-8 | CI runs the full suite and the migration apply/reverse cycle against PostgreSQL 17 in a second job, with a separate build cache. The SQLite job is unchanged. | `.github/workflows/ci.yml` inspection; local `ASHIATO_TEST_ADAPTER=postgres mix test` against a podman PostgreSQL |
| AC-9 | The listed single-use helpers are inlined and no longer defined. Public behaviour and results are unchanged. | `rg` for each removed name; `mix test` |
| AC-10 | No module under `lib/ashiato/outbound/` runs a query or calls a context. `Ashiato.DictionaryService` is the public entry point and owns validation, version memo, cache reads and writes, service-on-miss, and pruning. `Ashiato.Dictionary` is the behaviour plus `impl/0` only. | `rg -n "Repo\.\|Ecto\.Query" lib/ashiato/outbound`; `rg -n "DictionaryService" lib/ashiato/outbound` returns nothing; `mix test test/ashiato/dictionary_test.exs` |
| AC-11 | Chrome detection uses a query count that does not grow with the number of sources. | `mix test test/ashiato/ledger_test.exs` with a telemetry query counter |
| AC-12 | A default page belongs to the same user as its source; overriding `user_id` or `source_id` creates no unused rows. | `mix test test/ashiato/fixtures_test.exs` |
| AC-13 | Translation cooldowns are scoped by provider and credential fingerprint: a 403 for one key does not block another key of the same provider. | `mix test test/ashiato/translator_test.exs` |
| AC-14 | The full gate passes on SQLite and PostgreSQL. | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, `mix test` with `ASHIATO_TEST_ADAPTER=postgres` |

## Constraints

- Work stays on `wave-2-6-cleanup`; no push, no PR.
- SQLite remains the default test adapter. The PostgreSQL job is additive and runs the same suite.
- PostgreSQL-only tests are tagged `:postgres` and excluded by default.
- No migrations and no new dependencies.
- Public contracts change only where an AC states it: `transition/2` gains `{:error, :superseded}`;
  `Settings.credential/2` becomes public; dictionary entry points move from `Ashiato.Dictionary` to
  `Ashiato.DictionaryService`.
