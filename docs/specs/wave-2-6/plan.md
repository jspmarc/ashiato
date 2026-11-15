# Wave 2.6 — implementation plan

**Spec:** `docs/specs/wave-2-6/spec.md`
**Baseline:** `641d5fbbe5c96211f6cb5aed4c8cee34519d2546`, branch `wave-2-6-cleanup`
**Status:** awaiting user approval (AC-10 rewrite; expert pass skipped by user direction)

## Approach

Fix correctness first, in dependency order: configuration (Oban engine, adapter switch), page fencing,
settings, translator credentials, ledger concurrency. Then run the suite on PostgreSQL to prove the
two dialect-only fixes, wire the second CI job, and only then inline helpers and move dictionary
persistence. Cleanup tasks run last so their diffs sit on already-correct code.

## Rejected alternatives

- **Optimistic retry instead of a row lock for reviews.** Rejected: more code, and PostgreSQL is the
  production target where the lock is exact.
- **`lock: "FOR UPDATE"` unconditionally.** Rejected: `ecto_sqlite3` raises `locks are not supported
  by SQLite3`, so the lock is gated on the adapter.
- **Keep the insert-race rescue and wrap it in a savepoint.** Rejected: an upsert expresses the intent
  without transaction bookkeeping.
- **PG-tagged tests only in CI.** Rejected: the suite already passes on PG, so the full run costs
  seconds and covers every query.
- **`MIX_ENV=test_pg` for the second job.** Rejected: new env needs `elixirc_paths` and alias changes;
  one env var in `config/test.exs` is smaller.
- **A separate config file per adapter.** Rejected: two repo blocks in one file are easier to compare.

## Change surface

| Path | Status | Task |
|---|---|---|
| `config/prod.exs` | edit | T1 |
| `config/test.exs` | edit | T1 |
| `test/test_helper.exs` | edit | T1 |
| `test/ashiato/config_test.exs` | new | T1 |
| `lib/ashiato/ledger.ex` | edit | T2, T5, T6, T8, T9 |
| `test/ashiato/ledger_test.exs` | edit | T2, T8 |
| `test/ashiato/ledger_concurrency_test.exs` | new | T5, T6 |
| `lib/ashiato/settings.ex` | edit | T3, T9 |
| `test/ashiato/settings_test.exs` | edit | T3 |
| `test/support/settings_fake.ex` | edit | T3 |
| `lib/ashiato/outbound/translator.ex` | edit | T4, T9 |
| `lib/ashiato/outbound/translator/llm.ex` | edit | T4, T9 |
| `lib/ashiato/outbound/translator/deepl.ex` | edit | T9 |
| `lib/ashiato/outbound/translator/google_cloud.ex` | edit | T9 |
| `test/ashiato/translator_test.exs` | edit | T4 |
| `.github/workflows/ci.yml` | edit | T7 |
| `lib/ashiato/outbound/tokenizer/http.ex` | edit | T9 |
| `lib/ashiato/outbound/storage/local.ex` | edit | T9 |
| `lib/ashiato/schemas/lexeme.ex` | edit | T9 |
| `lib/ashiato/dictionary_service.ex` | new | T10 |
| `lib/ashiato/outbound/dictionary.ex` | edit | T10 |
| `test/ashiato/dictionary_test.exs` | edit | T10 |
| `test/support/fixtures.ex` | edit | T11 |
| `test/ashiato/fixtures_test.exs` | new | T11 |

## Interfaces

- `Settings.credential(user_id, key) :: String.t() | nil` — stored row wins, environment is the
  fallback. A resolved value that is empty or not a binary returns `nil`; an explicit empty stored row
  still blocks the environment fallback. Public; `ai_capable?/1` uses it.
- `Ledger.transition/2` returns `{:ok, Page.t()} | {:error, :invalid_transition | :superseded}`.
- `Ashiato.DictionaryService`: `lookup(term)`, `lookup_many(terms)`, `refresh_version/0`, `prune/0`
  keep the current shapes and become the public dictionary entry points. Cache reads/writes, version
  memo, kind derivation, and pruning are private to the service.
- `Ashiato.Dictionary` keeps the `lookup/1`, `lookup_many/1`, `dict_version/0` callbacks, `impl/0`,
  the configured key, and the adapters. It has no facade and no queries.
- `config/test.exs` reads `ASHIATO_TEST_ADAPTER`; value `"postgres"` selects `Ecto.Adapters.Postgres`
  and `DATABASE_URL` (default `postgres://postgres:postgres@localhost:5432/ashiato_test`).
- ExUnit tag `:postgres`, excluded unless `ASHIATO_TEST_ADAPTER=postgres`.
- Cooldown key becomes `{Ashiato.Translator, :cooldown, provider, fingerprint}` where `fingerprint` is
  the first 16 hex chars of `sha256(api_key)`, or `:none` when the key is absent, empty, or not a
  binary. `clear_cooldowns/0` matches the 4-tuple.
- `Ashiato.Repo` binds `:ecto_adapter` at compile time. Local PostgreSQL runs set
  `MIX_BUILD_PATH=_build/pg`; the CI job uses a per-adapter cache key with no cross-adapter restore.

## Risks

- **Compile-time adapter is not recompiled by an env-only change.** Reproduced in a scratch project:
  changing `ASHIATO_TEST_ADAPTER` alone does not recompile `Ashiato.Repo`. Mitigation:
  `MIX_BUILD_PATH=_build/pg` for local PG runs; a fresh, adapter-specific CI cache.
- **PG lock is adapter-gated.** Verified locally: `lock:` raises on SQLite3. Mitigation: one private
  helper chooses the query; the SQLite suite must stay green.
- **The shared sandbox cannot prove concurrency.** `start_owner!(shared: true)` checks out one
  connection, so two tasks serialize on it inside one transaction and the lost-update bug stays
  invisible. Mitigation: the T5/T6 concurrency cases live in a separate module that skips `DataCase`,
  uses `Sandbox.unboxed_run/2` for real per-task connections and commits, and deletes committed rows
  in `on_exit`. Tagged `:postgres`, `async: false`, one machine, one database.
- **Fixture defaults touch ~40 call sites.** Mitigation: full suite after the change; ownership is
  asserted directly in the new fixture test.
- **Inlining four helpers inside `kanji_map/1`.** Mitigation: keep `fold_word_facts/2` and
  `kanji_map/1` structure; inline only the leaf functions.
- **CI job cannot run locally.** Mitigation: run the same commands against podman PostgreSQL; record
  the workflow as inspected, not executed, until it is pushed.
- **Moving dictionary persistence changes the public entry point.** Mitigation: only
  `test/ashiato/dictionary_test.exs` calls the current facade; `on_conflict` handling moves verbatim.

## Tasks

| ID | Satisfies | Read first | Deliverable | Done when | Verification | Depends on | Parallel-safe |
|---|---|---|---|---|---|---|---|
| T1 | AC-1, AC-8 | `config/*.exs`, `test/test_helper.exs` | Adapter switch, PG repo config, engine per adapter, `:postgres` exclusion, config test | SQLite run selects Lite; PG run selects Basic; prod config names Basic | `mix test test/ashiato/config_test.exs`; `rg "Oban.Engines.Basic" config/prod.exs` | — | no |
| T2 | AC-2 | `lib/ashiato/ledger.ex:670-710` | Status+revision fence on both writes, `:superseded` documented | Stale struct writes nothing; valid moves pass; tests cover stale status and stale revision | `mix test test/ashiato/ledger_test.exs` | — | no |
| T3 | AC-3, AC-6 | `lib/ashiato/settings.ex`, `test/support/settings_fake.ex` | Secret classification preserved; `credential/2` public; fake kept in parity | Re-put stays encrypted; explicit false declassifies; empty credential returns nil; fake matches | `mix test test/ashiato/settings_test.exs` | — | no |
| T4 | AC-6, AC-13 | `lib/ashiato/outbound/translator.ex`, `llm.ex` | LLM reads `:api_key` only; cooldown keyed by provider and credential fingerprint; `opts` threaded through both cooldown helpers; `clear_cooldowns/0` matches the 4-tuple | No `System.get_env("OPENAI_API_KEY")` in `llm.ex`; two keys do not share cooldown; clear erases all | `mix test test/ashiato/translator_test.exs` | T3 | no |
| T5 | AC-4 | `lib/ashiato/ledger.ex:170-230`, `test/support/data_case.ex:39` | `FOR UPDATE` on the `words` row (always present); unchanged SQLite path; new `ledger_concurrency_test.exs` using `Sandbox.unboxed_run/2`, committed fixtures, `on_exit` cleanup | Two concurrent reviews on separate connections yield `reps == 2` and two events on PG, including a first-ever review; SQLite suite unchanged | `ASHIATO_TEST_ADAPTER=postgres MIX_BUILD_PATH=_build/pg mix test --include postgres test/ashiato/ledger_concurrency_test.exs` | T1, T2 | no |
| T6 | AC-5, AC-7 | `lib/ashiato/ledger.ex:75-110, 800-825` | `on_conflict: :nothing` find-or-create for word and lexeme with refetch when `id` is nil; validation errors unchanged; POS normalised; race case reuses the unboxed harness | Concurrent force-introduce on separate connections creates one row without abort; nil POS returns `""`; invalid attrs still return the changeset | same PG command as T5 plus `mix test test/ashiato/ledger_test.exs` | T5 | no |
| T7 | AC-8 | `.github/workflows/ci.yml`, T1 config | Second job: postgres:17 service, health check, adapter-specific cache key with no cross restore, full cycle | YAML parses; local PG run matches job commands | `podman` PG + the job's command sequence; workflow inspection | T1, T5, T6 | no |
| T8 | AC-11 | `lib/ashiato/ledger.ex:316-337, 758-893` | Constant-query chrome detection using `2 * occurrences > pages`, preserving "every source with encounters" and skipping zero-page sources | Query count equal for 1 and 3 sources; ratios unchanged; zero-page source test passes | `mix test test/ashiato/ledger_test.exs` | T2, T6 | no |
| T9 | AC-9 | all files in change surface | Inline exactly: `new_word_state`, `missing_word_changeset`, `new_stats`, `add_sighting`, `add_word_fact`, `glyph_entry`, `in_lexeme_order`, `chrome_word_ids`, `request_url`, `request_opts`, `encode_path`, `put_test_plug`, `valid_lines`, `request`/`put_source` in `deepl.ex` and `google_cloud.ex`; drop the identity-only cases in `review/3` and `encode_value/2`; update the stale `Lexeme.changeset/2` @doc to describe the upsert flow (doc only) | `rg` finds none of those definitions; suite green | `rg` for each name; `mix test` | T2, T3, T4, T6, T8 | no |
| T10 | AC-10 | `lib/ashiato/outbound/dictionary.ex`, `test/ashiato/dictionary_test.exs` | New `DictionaryService` context owns the public entry points, orchestration, and all queries; `Dictionary` becomes behaviour + `impl/0` | No `Repo`/`Ecto.Query` or `DictionaryService` reference under `lib/ashiato/outbound`; dictionary tests use the service | `rg -n "Repo\.\|Ecto\.Query\|DictionaryService" lib/ashiato/outbound`; `mix test test/ashiato/dictionary_test.exs` | — | no |
| T11 | AC-12 | `test/support/fixtures.ex` | Ownership-first fixtures: user from `source_id` when only that is given, source under the given `user_id` when only that is given, no unused rows | Default page and source share a user; both override directions create no extras | `mix test test/ashiato/fixtures_test.exs`; `mix test` | — | no |
| T12 | AC-14 | — | Recorded gate evidence on both adapters | Both suites green, format and compile clean | `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test`, PG `mix test` with `MIX_BUILD_PATH=_build/pg` | T1–T11 | no |

Note: all `ledger.ex` edits form the chain T2 → T5 → T6 → T8 → T9, and the dependency cells state it.

## Coverage

AC-1 T1 · AC-2 T2 · AC-3 T3 · AC-4 T5 · AC-5 T6 · AC-6 T3,T4 · AC-7 T6 · AC-8 T1,T7 ·
AC-9 T9 · AC-10 T10 · AC-11 T8 · AC-12 T11 · AC-13 T4 · AC-14 T12

## Baseline checks

| Check | Result |
|---|---|
| `git status --short --untracked-files=all` | only `docs/specs/wave-2-6/spec.md` |
| `mix format --check-formatted` | exit 0 |
| `mix compile --warnings-as-errors` | exit 0 |
| `mix test` | 200 tests, 0 failures |
| PG probe, Lite engine | app boot fails: `Oban.Migrations.Postgres.with_defaults/2` → `String.replace(false, ...)` |
| PG probe, Basic engine | 200 tests, 0 failures |

The Lite-on-PG boot failure is the defect AC-1 fixes; it is expected before T1 and was reproduced with
a temporary config edit that was restored.

## Constraints

Inherited from the spec: no migrations, no new dependencies, no push or PR, SQLite stays the default
test adapter, PostgreSQL-only tests tagged `:postgres`.

## Expert findings

| Pass | ID | Decision | Reason |
|---|---|---|---|
| 1 | F1 | accept | Mix does not recompile on an env-only adapter change; PG runs use `MIX_BUILD_PATH=_build/pg`, CI uses adapter-specific caches |
| 1 | F2 | accept | T9 now names every helper to inline |
| 1 | F3 | accept | Lock the `words` row, not `word_states`; the parent row always exists |
| 1 | F4 | accept | `on_conflict: :nothing` plus refetch when `id` is nil; validation errors still surface |
| 1 | F5 | accept | `test/support/settings_fake.ex` added to T3; fake parity required |
| 1 | F6 | accept | `credential/2` returns nil for empty/non-binary; empty stored row still blocks env |
| 1 | F7 | accept | `clear_cooldowns/0` matches the 4-tuple key |
| 1 | F8 | accept | `opts` threaded into both cooldown helpers; empty or nil key maps to `:none` |
| 1 | F9 | accept | `payloads/2` takes `{kind, term}` pairs; kind derivation stays in `Dictionary` |
| 1 | F10 | accept | Integer-safe `2 * occurrences > pages`; zero-page and encounter-source invariants stated |
| 1 | F11 | accept | Fixture resolves user from source and source from user, both directions |
| 1 | F12 | accept as-is | No change; plan-level signatures are design detail |
| 1 | F13 | accept | T9 depends on T6 too; ledger chain made explicit |
| 2 | F1 | accept | T5 now depends on T2 and T8 on T6; cells match the stated chain |
| 2 | F2 | accept | Concurrency cases use a separate module with `Sandbox.unboxed_run/2`, real connections and commits, `on_exit` cleanup |
| — | AC-10 rewrite | user-directed | Orchestration and entry points move to `DictionaryService`; expert pass explicitly skipped by the user |
