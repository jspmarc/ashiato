# Wave 2.7 — Prerequisites for ingest: implementation plan

**Spec:** `docs/specs/wave-2-7/spec.md`
**Baseline:** `79490e935a648ed4f2b6b29ec89b388da0e48693`, branch `main`, clean tree
**Branch:** `wave-2-7-prereqs` (implementation only; no commits on `main`)
**Status:** approved by user, 2026-11-16; latest expert verdict pass 9 `revise` (N1 applied, no ready verdict)

## Expert findings

### Pass 1 — verdict `blocked`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| F1 | 🔴 | Spec AC-6 called `crop` optional while AC-2 required it | accept | Make `crop` required in spec, plan, and docs |
| F2 | 🔴 | `Ocr.recognise/1` does not exist | accept | Add the public façade, matching Tokenizer/Translator |
| F3 | ❓ | Partial hit: cached or provider lines returned? | accept | Any miss returns the provider's full-page output; cache is read only on all-hit |
| F4 | 🟡 | Duplicate lines share a key but may differ contextually | accept | Dedupe inserts, first occurrence wins; provider output untouched |
| F5 | ❓ | Crop validation depth undefined | accept | Base64 decode + non-empty binary; no JPEG or image validation |
| F6 | 🟡 | `16_000_000` is not 16 MiB | accept | Use `16_777_216` and test above 4 MiB and above cap |
| F7 | 🟡 | "One page request" conflicts with provider fallback | accept | One `Translator.translate_page/2` call; fallback may issue per-line requests |
| F8 | 🟡 | Provider provenance encoding undefined | accept | Store `inspect(Translator.impl())` and assert it |
| F9 | 🟡 | Cache writes could log translated text | accept | `log: false` on cache operations + debug log-capture test |
| F10 | 🟡 | Missing-target behavior only in the plan | accept | Promote to AC-4 with nil/empty/non-string cases |
| F11 | 🟡 | Migration placement mixed into spec | accept | Spec says existing table-creating migrations; exact paths in plan |
| F12 | 🔴 | Requirements mandate Quadlet despite open orchestration | accept | Remove the mandate; mechanism-neutral wording only |
| F13 | 🟡 | Public word creation has undeclared FK preconditions | accept | Document valid existing IDs and the `Ecto.ConstraintError` raise |
| F14 | 🟡 | Malformed OCR fixtures would fail for the wrong reason | accept | Give unrelated malformed fixtures valid crops |
| F15 | 🟡 | AC-8 PG command omitted the build path | accept | Use `MIX_BUILD_PATH=_build/pg ... MIX_ENV=test` |

Spec and plan amended accordingly. Spec approval re-opens because the spec text changed; re-approval
happens after the second expert verdict.

### Pass 2 — verdict `revise`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| G1 | 🟡 | T4 done criteria used `{:missing_target_lang}` | accept | Correct to `{:error, :missing_target_lang}` |
| G2 | 🟡 | Fake cannot produce differing duplicate translations | accept | Add optional `:replies` list; include the fake in T4's surface |
| G3 | 🟡 | Debug capture is vacuous at Logger `:warning` | accept | Enable and restore `:debug`; assert a control debug line is captured |
| G4 | 🟡 | Word precondition remained plan-only | accept | Add existing-ID + `Ecto.ConstraintError` to AC-1 and test both missing cases |
| G5 | 🟡 | Cap tests did not prove the exact constant | accept | Accept exactly `16_777_216` and reject `16_777_217`, prefix excluded |
| G6 | 🟡 | Spec carried test mechanics (`log: false`, capture) | accept | Spec keeps the observable no-text-logging requirement; mechanics stay in the plan |
| G7 | 🔵 | Problem named nonexistent `Ocr.recognise/1` and `presigned_get/2` façades | accept | Name `Ocr.Socket.recognise/1` and the storage callback/implementations |

### Pass 3 — verdict `revise`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| H1 | 🟡 | G6 partially applied: spec still prescribed a debug-level capture test | accept | Remove the capture phrase from spec; keep only the observable no-query-log requirement |
| H2 | 🔵 | `translator/fake.ex` missing from the change-surface table | accept | Add it as a T4 edit |

### Post-pass 3 user revision

The user dropped the log-capture test: the concern is log noise, not secrecy, and the database already
stores the text unencrypted.

| ID | Original decision | Revised decision | Reason |
|---|---|---|---|
| F9 | accept (`log: false` + capture test) | revise | Keep `log: false`; drop the capture test; verify by inspection |
| G3 | accept (debug capture with control) | revise | Same; no Logger manipulation in tests |
| H1 | accept | accept, expanded | Spec now states only that cache operations emit no Ecto query-log entries |

Status: awaiting fourth expert review.

### Pass 4 — verdict `revise`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| J1 | 🟡 | Plan constraints still forbade all translation-text logging, exceeding the revised spec | accept | Allow `log: false` query-log suppression; secrets/credentials still never logged; inspection |

J1 applied. No fifth expert pass was run; stopped for user direction.

### Pass 5 — verdict `ready`

No findings. Expert confirmed J1, logging constraints, AC coverage, and task coverage. Plan awaits user
approval.

### Post-pass 5 user revision

- `TranslationCache` renamed to `Ashiato.TranslatorService`, matching the `DictionaryService`
  precedent. Wave 3 calls `TranslatorService.translate_page/2`; `Translator.translate_page/2` stays
  the provider call.
- The user approved dropping the local dev database. T2 resets dev, test, and PG test databases.

This invalidated the ready verdict; pass 6 was run.

### Pass 6 — verdict `ready`

Only K1 (🔵) remained: the risk row used invalid `MIX_ENV=dev|test` shorthand and its pipe split the
Markdown table. Applied; the row now points at T2's explicit reset commands.

### Post-pass 6 user revision

The user changed the translation cache design:

- Key is now `(provider, target_lang, sha256(line))`; switching provider never reuses another
  provider's rows.
- TTL is 30 days; expired rows are ignored on read and replaced for the page's keys.
- A new `TranslatorService.PruneWorker` deletes expired rows; production schedules it daily at
  03:00 UTC through `Oban.Plugins.Cron`, configured only in `config/prod.exs`.
- Spec AC-4, AC-6, AC-9, non-goals, constraints, and context updated; plan T2/T4, tasks T5–T8,
  change surface, interfaces, config, risks, and coverage updated.

This invalidated the pass 6 ready verdict. Pass 7 is required.

### Pass 7 — verdict `revise`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| L1 | 🟡 | `impl()` resolved twice could mislabel output | accept | Resolve once; pin module; `provider_name/0` callback with `__using__` default; `Off` explicit |
| L2 | 🟡 | Deleting stale rows before the provider violates "provider errors write nothing" | accept, clarified | DELETE is cleanup; AC-4 forbids INSERT/UPDATE on provider error, allows expired-row deletion |
| L3 | 🟡 | TTL boundary/timestamp convention undefined | accept | Second precision; `2_592_000`-second cutoff; equality fresh; same for prune |
| L4 | 🟡 | Deleting by observed IDs can kill a concurrent refresh | accept | DELETE predicate uses keys + `fetched_at < cutoff`; test concurrent refresh survives |
| L5 | 🔵 | Change surface omitted T5 ownership and `config_test.exs` | accept | Rows added |

Spec and plan amended; pass 8 pending.

### Pass 8 — verdict `revise`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| M1 | 🟡 | Non-goal forbade provider-behaviour changes though `provider_name/0` is added | accept | Exempt the callback; fallback/cooldown rules unchanged |
| M2 | 🟡 | Last-segment provider names collide for custom modules | accept | Default `inspect(__MODULE__)`; built-ins declare explicit short names; `Off`/`Fake` explicit |
| M3 | 🟡 | Provider pause after DELETE cannot test the DELETE refresh race | accept, clarified | Test 1: fresh+expired keys, fixed now, insert-all conflict. Test 2: one Task, blocking fake, test inserts fresh row before release. No production hook. |
| M4 | 🟡 | Exact-cutoff tests use a live clock | accept | `:now` opt on translate_page; `prune_expired(now \\ Utils.utc_now())` |
| M5 | 🔵 | `translator.ex` missing from change surface | accept | Added, plus the provider modules touched for explicit names |

Spec and plan amended; pass 9 pending.

### Pass 9 — verdict `revise`

| ID | Severity | Finding | Decision | Reason |
|---|---|---|---|---|
| N1 | 🟡 | Test 2 did not specify `async: false`/shared sandbox | accept | `use Ashiato.DataCase, async: false`; DataCase shares the sandbox with the Task and prevents global provider/fake races |

N1 applied. Stopped for user direction; no pass 10 run.

## Approach

Land identity and schema first (word mint, nullable crop, translation table), then the OCR wire
contract, then the provider-scoped cache with its TTL, then the prune worker and its production Cron,
then storage locator and docs. Every task is dispatched
sequentially: `ledger.ex`, `ledger_test.exs`, the migrations, and the shared gate files overlap, so
parallel worktrees would only create integration risk. The existing patterns are reused:
`DictionaryService` for the cache context, `Storage.Fake`/`Ocr.Fake` for doubles, and the OCR Unix
socket stub for wire tests.

## Rejected alternatives

- **New migration files instead of editing the table-creating migrations.** Rejected: no production
  database exists, and the user explicitly authorised editing in place; a new migration would need a
  backfill and an `ALTER` that SQLite handles poorly.
- **Absolute-path locator for local storage.** Rejected: couples both containers to the same mount
  path. A storage key plus an OCR-side root config only requires the shared volume.
- **Full-page image as the embedded-page crop.** Rejected: D30 does not rasterise text-layer PDFs, and
  a full page still is not the per-line crop R2.6 asks for. Nullable plus text-only is honest.
- **Widen `dict_cache_entries.kind` to `translation`.** Rejected: it forces a fake `dict_version` and
  mixes immutable dictionary data with mutable provider output.
- **Cache inside `Ashiato.Translator`.** Rejected: the behaviour is the provider transport; the cache
  needs a database and belongs above it.
- **Crop in Elixir with an image dependency.** Rejected: no new dependencies, and the OCR service
  already has the decoded line crops.
- **Build `ashiato-ocr` now.** Rejected: separate runtime and repository cadence, AVX-dependent, not
  verifiable in this repo's gate. Wave 3 runs on fakes; the service card records the contract.
- **Parallel task dispatch.** Rejected: shared ledger/test files and one migration gate make the
  integration cost higher than the saved time.

## Change surface

| Path | Status | Task |
|---|---|---|
| `lib/ashiato/ledger.ex` | edit | T1, T2 |
| `test/ashiato/ledger_test.exs` | edit | T1, T2 |
| `test/ashiato/ledger_concurrency_test.exs` | edit | T1 |
| `priv/repo/migrations/20261101095347_create_other_tables.exs` | edit | T2 |
| `priv/repo/migrations/20261101090036_create_root_tables.exs` | edit | T2 |
| `lib/ashiato/schemas/encounter.ex` | edit | T2 |
| `lib/ashiato/schemas/translation.ex` | new | T2 |
| `test/ashiato/schema_test.exs` | edit | T2 |
| `docs/diagrams/erd.dbml` | edit | T2 |
| `lib/ashiato/outbound/ocr.ex` | edit | T3 |
| `lib/ashiato/outbound/ocr/socket.ex` | edit | T3 |
| `lib/ashiato/outbound/ocr/fake.ex` | edit | T3 |
| `test/ashiato/ocr_test.exs` | edit | T3 |
| `test/ashiato/translator_service_test.exs` | new | T4 |
| `lib/ashiato/outbound/translator.ex` | edit | T4 |
| `lib/ashiato/outbound/translator/fake.ex` | edit | T4 |
| `lib/ashiato/outbound/translator/off.ex` | edit | T4 |
| `lib/ashiato/outbound/translator/deepl.ex` | edit | T4 |
| `lib/ashiato/outbound/translator/google_cloud.ex` | edit | T4 |
| `lib/ashiato/outbound/translator/google_free.ex` | edit | T4 |
| `lib/ashiato/outbound/translator/llm.ex` | edit | T4 |
| `lib/ashiato/translator_service.ex` | new | T4, T5 |
| `lib/ashiato/translator_service/prune_worker.ex` | new | T5 |
| `test/ashiato/translator_prune_test.exs` | new | T5 |
| `test/ashiato/config_test.exs` | edit | T5 |
| `config/prod.exs` | edit | T5 |
| `lib/ashiato/outbound/storage.ex` | edit | T6 |
| `lib/ashiato/outbound/storage/local.ex` | edit | T6 |
| `lib/ashiato/outbound/storage/fake.ex` | edit | T6 |
| `test/ashiato/storage_test.exs` | edit | T6 |
| `docs/plan/ashiato-ocr.md` | new | T7 |
| `docs/requirements.md` | edit | T7 |

`test/support/ocr_stub.ex` needs no change; its handler already answers arbitrary JSON maps.

## Interfaces

### Elixir

- `Ledger.find_or_create_word(user_id :: integer(), lexeme_id :: integer()) ::
    {:ok, Word.t()}`
  Public; same upsert as the private function; writes only `words`, never `word_states`.
  `@doc` states the precondition: `user_id` and `lexeme_id` must exist; a missing row raises
  `Ecto.ConstraintError` (no new error tuple; `introduce_words/3` keeps its `{:ok, word} =`
  pattern).
- `Storage.locator(key :: String.t(), ttl_seconds :: pos_integer()) ::
    {:ok, {:key, String.t()} | {:url, String.t()}} | {:error, term()}`
  Behaviour callback of the same name and arity; `Storage.locator/2` delegates to `impl()`.
  `Local` ignores the TTL and returns `{:key, key}` after key validation; `Fake` records
  `{:locator, key, ttl_seconds}` and returns `{:key, key}`. A future S3 store returns
  `{:url, presigned}`.
- `Ocr.recognise/1` is public and delegates to `impl().recognise/1`; wave 3 and tests use it
  rather than calling `impl()` directly.
- `Ocr.locator :: {:path, String.t()} | {:url, String.t()} | {:key, String.t()}`
- `Ocr.line :: %{bbox: [integer()], text: String.t(), score: float(), crop: binary()}`
  `crop` is required decoded bytes, not base64. Validation is base64 decode plus non-empty
  binary; no JPEG signature or image decode.
- `Translator.provider_name() :: String.t()` is a behaviour callback. Its default is
  `inspect(__MODULE__)` (fully qualified, collision-free for custom providers). Built-ins pass
  explicit names through `use Ashiato.Translator, name: "..."` (`google_free`, `llm`, `deepl`,
  `google_cloud`); `Off` and `Fake` implement/declare `"off"` and `"fake"`. The service resolves
  `Translator.impl()` once, calls `provider.provider_name()`, and uses the same pinned module for
  `translate_page/2`.
- `TranslatorService.translate_page(lines :: [String.t()], opts :: keyword()) ::
    {:ok, [String.t()]} | {:error, term()}`
  Reads `:target_lang` through `Translator.langs/1`; nil, empty, or non-string targets return
  `{:error, :missing_target_lang}` without a provider call or database write.
  Cache identity is `(provider_name, lang, source_hash)`, where `source_hash` is lowercase hex
  SHA-256 of the line. TTL is 30 days in whole seconds: `fetched_at >= now - 2_592_000` is fresh;
  older is expired. `translate_page/2` accepts a `:now` opt for deterministic tests; production
  omits it and uses `Utils.utc_now/0`.
  All-hit fresh pages return cached lines in input order with zero provider calls. Any miss or
  expired row first deletes expired rows for the page's keys with a `keys + fetched_at < cutoff`
  predicate (never by previously observed IDs), then calls the pinned provider once over the full
  input and returns exactly the provider output (duplicates and order preserved); missing keys are
  inserted with `on_conflict: :nothing`; fresh rows are never overwritten. Provider errors insert
  or overwrite nothing; expired rows may already be deleted. Duplicate source lines are deduped
  before insert, first occurrence wins; a later all-hit page returns that value for every duplicate.
  Cache reads, writes, and deletes pass `log: false`.
- `TranslatorService.prune_expired(now \\ Utils.utc_now()) :: {:ok, non_neg_integer()}`
  Deletes rows with `fetched_at < now - 2_592_000` and returns the deleted count. The optional
  `now` keeps boundary tests deterministic.
- `TranslatorService.PruneWorker` is an `Oban.Worker` on the `:default` queue whose
  `perform/1` calls `prune_expired/0` and returns `:ok`.
- `Translator.Fake.start_link(replies: [String.t()])` returns the positional replies in order for a
  page request, so duplicate input lines can get different output; absent `:replies`, the existing
  deterministic `"[" <> line <> "]"` transform is unchanged.

### Wire and storage literals

- Socket request for the local store: `{"op": "ocr", "key": "<object key>"}`.
- Socket reply line: `{"bbox": [x1,y1,x2,y2], "text": "...", "score": 0.98, "crop": "<base64 JPEG>"}`.
- `@max_reply_bytes` changes from `4_000_000` to `16_777_216` (16 MiB). Tests accept a framed
  JSON body of exactly `16_777_216` bytes and reject one of `16_777_217`; the 4-byte length prefix
  is excluded.
- Translation cache identity: `(provider_name, lang, lowercase hex SHA-256 of the line)`. No source
  text column. `provider_name` comes from the pinned provider's `provider_name/0`. TTL is 30 days
  in whole seconds (`2_592_000`). Cache reads, writes, and deletes pass `log: false`; verified by
  inspection, no log-capture test.
- Translation cache table columns: `provider` string NOT NULL, `lang` string NOT NULL,
  `source_hash` string NOT NULL, `translated_text` text NOT NULL, `fetched_at` utc_datetime NOT NULL.
  Unique index `translations_provider_lang_source_hash_index` on
  `[:provider, :lang, :source_hash]`; index `translations_fetched_at_index` on `[:fetched_at]` for
  the prune.

### Migrations

- `20261101095347_create_other_tables.exs`: `crop_key` changes to `null: true`; comment states that
  a nil crop means the page had embedded text and no line geometry.
- `20261101090036_create_root_tables.exs`: adds `translations` with the provider/lang/hash unique
  index, `fetched_at` index, and comments explaining global scope, provider-scoped identity, and
  the 30-day TTL. No foreign keys; the cache is global like `dict_cache_entries`.

### Config

- `config/prod.exs` adds `plugins: [{Oban.Plugins.Cron, crontab: [{"0 3 * * *", Ashiato.TranslatorService.PruneWorker}]}]`.
  No Cron plugin in dev or test, so tests insert no recurring jobs. Oban's `:default` queue already
  exists. The OCR service image root is service configuration, documented in
  `docs/plan/ashiato-ocr.md`, not application env.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Editing already-applied migrations leaves dev/test databases stale; `mix ecto.migrate` will not apply the edit. | Run the explicit dev and test reset commands in T2. The user approved dropping the local dev database for this wave. CI starts empty. |
| The PG compile-time adapter check fails when switching adapters in one build tree. | Use `MIX_BUILD_PATH=_build/pg` with `ASHIATO_TEST_ADAPTER=postgres`; baseline proved this works. Every PG command in this plan carries it. |
| A required `crop` breaks a future OCR backend or the unbuilt service. | The service is unbuilt; the contract and stub define it. `Ocr.Fake` supplies crops. The service card records the requirement. |
| Large base64 crops exceed the old 4 MB packet cap or blow test memory. | Raise the cap to exactly `16_777_216`; accept a framed JSON body of that size and reject `16_777_217`; prefix excluded. |
| Cache writes race on the unique index during concurrent pages. | Dedupe by hash, insert with `on_conflict: :nothing` + `conflict_target: [:provider, :lang, :source_hash]`, never overwrite fresh rows. Returned page output remains the provider's. |
| Duplicate source lines map to one cache key but may get different contextual translations. | Dedupe inserts by first occurrence; return provider output unchanged; `Translator.Fake` gains positional `:replies` so the test can prove first-occurrence wins. |
| Cache queries flood debug logs with translated text. | Pass `log: false` on the read, insert, and prune operations; verify by inspecting those options. No log-capture test; the concern is noise, not secrecy. |
| Expired rows are ignored on read but never removed, so the table grows. | 30-day TTL in whole seconds (`2_592_000`) plus `PruneWorker` deleting `fetched_at < cutoff`; production Cron daily at 03:00 UTC, manual `prune_expired/0` elsewhere. |
| A stale row blocks an insert because the unique key already exists. | On a miss/expired page, delete expired rows for the page's keys with `keys + fetched_at < cutoff` before the provider call, then insert with `on_conflict: :nothing`. Provider errors may leave those expired rows deleted; no insert/overwrite happens. |
| A concurrent refresh is deleted by a stale caller. | The DELETE predicate includes `fetched_at < cutoff`, never row IDs observed earlier. Test 1 covers a fresh row surviving DELETE; Test 2 covers a row inserted after SELECT surviving INSERT. |
| TTL boundary is off by one second or uses mixed precision. | `Utils.utc_now/0` and the `:now` opt are second precision; cutoff `2_592_000`; equality fresh, one second older expires; `prune_expired/1` takes the same `now`. |
| Cron in dev/test inserts jobs and pollutes the Oban table. | Cron plugin is configured only in `config/prod.exs`; dev/test exercise `perform/1` and `prune_expired/1` directly. |
| Provider provenance is ambiguous for custom modules. | Default `provider_name/0` is `inspect(__MODULE__)`, so custom modules cannot collide; built-ins declare short names explicitly; `Fake` is `"fake"`. |
| A hash collision would serve the wrong translation. | SHA-256 is the identity; collisions are not a practical risk, and storing source text would add dialogue duplication. |
| `SchemaTest` silently misses the new table. | T2 adds `Ashiato.Schemas.Translation` to its schema list; the test compares columns both ways. |
| Docs drift from the wire contract. | T7 is last and reads the implemented modules; AC-7 lists the required literals. |

## Tasks

| ID | Satisfies | Read first | Deliverable | Done criteria | Verification | Depends on | Parallel-safe |
|---|---|---|---|---|---|---|---|
| T1 | AC-1 | `lib/ashiato/ledger.ex` (`find_or_create_word/2`, `resolve_words/3`, `record_encounter/1`); `lib/ashiato/schemas/word.ex`; `priv/repo/migrations/20261101095347_create_other_tables.exs:107-135`; `test/ashiato/ledger_test.exs`; `test/ashiato/ledger_concurrency_test.exs` | Public `find_or_create_word/2` with doc/spec and the existing-ID precondition; tests for existing, new, no `word_states` row, usable by `record_encounter/1`, `Ecto.ConstraintError` for a missing user and a missing lexeme, and PG concurrent calls | Function public and race-safe; doc names the `Ecto.ConstraintError` precondition; raise tests do no DB work after the assertion; tests assert exactly one row and no `word_states` write; SQLite and PG tests pass | `mix test test/ashiato/ledger_test.exs` and `MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix test test/ashiato/ledger_concurrency_test.exs --include postgres` | — | no |
| T2 | AC-3, AC-6 | Migrations `20261101090036_create_root_tables.exs` and `20261101095347_create_other_tables.exs`; `lib/ashiato/schemas/encounter.ex`; `Ledger.record_encounter/1` doc; `test/ashiato/schema_test.exs`; `docs/diagrams/erd.dbml` | `crop_key` nullable; `translations` table + `Ashiato.Schemas.Translation` with provider/lang/hash unique index and `fetched_at` index; encounter changeset update; ERD update; migration comments | `record_encounter/1` accepts nil crop and still rejects nil required fields; schema test includes the new schema; both migrations build from empty on SQLite (dev and test) and PG | `MIX_ENV=dev mix ecto.drop && MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate`; `MIX_ENV=test mix ecto.drop && MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate`; `MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix ecto.drop && MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix ecto.create && MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix ecto.migrate`; `mix test test/ashiato/ledger_test.exs test/ashiato/schema_test.exs` | T1 | no |
| T3 | AC-2, AC-5 | `lib/ashiato/outbound/ocr.ex`; `lib/ashiato/outbound/ocr/socket.ex`; `lib/ashiato/outbound/ocr/fake.ex`; `test/ashiato/ocr_test.exs`; `test/support/ocr_stub.ex` | Public `Ocr.recognise/1`; `{:key, key}` locator and request; required per-line `crop` base64 decode + non-empty validation; exact `16_777_216` cap; fake crops; tests for crop, invalid base64, empty crop, missing crop, key locator, exact framed JSON body at `16_777_216` accepted and `16_777_217` rejected (length prefix excluded); existing malformed-bbox/score fixtures get valid crops | Every accepted line has non-empty binary `crop`; malformed crop is `{:invalid_line, index}`; unrelated malformed fixtures fail on bbox/score only; key locator sends `key`; cap is proven at the exact byte boundary; tests pass | `mix test test/ashiato/ocr_test.exs` | — | yes |
| T4 | AC-4 | `lib/ashiato/outbound/translator.ex` (`translate_page/2`, `impl/0`, `langs/1`, `__using__`); provider modules; `lib/ashiato/outbound/translator/fake.ex`; `lib/ashiato/schemas/translation.ex`; `lib/ashiato/dictionary_service.ex`; `test/support/data_case.ex`; `test/ashiato/schema_test.exs` | `Ashiato.TranslatorService.translate_page/2` with pinned provider, `provider_name/0` (fully qualified default; explicit short names on built-ins), provider/lang/hash key, 30-day TTL, delete-expired-before-provider, `:now` opt; `Translator.Fake` gains `:replies` and a blocking gate; `translator_service_test.exs` uses `Ashiato.DataCase, async: false` for a shared sandbox; Test 1 (fresh+expired keys at fixed now, insert-all with conflict) and Test 2 (one Task, test inserts fresh row while fake blocks, then releases) | Provider label pinned and explicit; Test 1 asserts fresh sentinel survives, expired key replaced, provider called once; Test 2 asserts a row inserted after SELECT wins the INSERT conflict; TTL equality fresh, one second older expires; provider switch misses; provider error inserts/overwrites nothing; duplicate first-occurrence with differing fake replies; nil/empty/non-string target no call/write; `log: false` inspection | `mix test test/ashiato/translator_service_test.exs test/ashiato/schema_test.exs` | T2 | no |
| T5 | AC-9 | `lib/ashiato/translator_service.ex`; `lib/ashiato/translator_service/prune_worker.ex`; `lib/ashiato/schemas/translation.ex`; `config/prod.exs`; `config/test.exs`; `test/ashiato/config_test.exs` | `TranslatorService.prune_expired(now \\ Utils.utc_now())`; `TranslatorService.PruneWorker`; prod-only `Oban.Plugins.Cron` daily 03:00 UTC; prune tests with fixed `now` | `prune_expired/1` deletes only `fetched_at < now - 2_592_000` and returns the count; boundary equality stays; `perform/1` calls it and returns `:ok`; prod config schedules the worker; dev/test config has no Cron plugin | `mix test test/ashiato/translator_prune_test.exs test/ashiato/config_test.exs`; inspection of `config/prod.exs` | T4 | no |
| T6 | AC-5 | `lib/ashiato/outbound/storage.ex`; `lib/ashiato/outbound/storage/local.ex`; `lib/ashiato/outbound/storage/fake.ex`; `test/ashiato/storage_test.exs`; `lib/ashiato/outbound/ocr.ex` | `locator/2` callback + public delegation; Local and Fake implementations; tests that `Ocr.recognise/1` accepts the returned locator | Local returns `{:key, key}` and rejects invalid keys; Fake records and returns the same shape; `Ocr` accepts it | `mix test test/ashiato/storage_test.exs test/ashiato/ocr_test.exs` | T3 | no |
| T7 | AC-6, AC-7 | `docs/requirements.md` §7.3, R2.6, R7.3, D20, D29; `docs/diagrams/erd.dbml`; `reference/python-jp-reader/core/ocr.py`; implemented T1–T6 modules | New `docs/plan/ashiato-ocr.md`; requirements updates for required `crop`, `key` locator, provider-scoped `(provider, lang, line)` cache with 30-day TTL, embedded text-only note, and removal of the Quadlet mandate | Service card covers every AC-7 literal; no orchestration product is named as a requirement anywhere; requirements no longer describe the reply without `crop` or the cache without provider/TTL; no orchestrator mandate | `rg -n 'crop|key|16|Paddle|volume|fixture' docs/plan/ashiato-ocr.md`; `! rg -n -i 'quadlet|podman|docker|systemd' docs/requirements.md docs/plan/ashiato-ocr.md`; `rg -n 'provider|30|TTL' docs/requirements.md docs/diagrams/erd.dbml`; inspection against AC-6/AC-7 | T1–T6 | no |
| T8 | AC-8 | Spec, plan, all changed files | Verification evidence for the full gate | All commands exit 0 on SQLite and PG; no skipped new tests | `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix test`; `MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix test --include postgres`; `mix precommit` | T1–T7 | no |

## Coverage

| AC | Tasks |
|---|---|
| AC-1 | T1 |
| AC-2 | T3 |
| AC-3 | T2 |
| AC-4 | T4 |
| AC-5 | T3, T6 |
| AC-6 | T2, T7 |
| AC-7 | T7 |
| AC-8 | T8 |
| AC-9 | T5 |

Every acceptance criterion appears in at least one task; no task adds scope beyond the spec.

## Baseline checks (pre-change evidence)

Run on `79490e9`, clean tree except `docs/specs/wave-2-7/spec.md` (untracked).

| Command | Exit | Output |
|---|---|---|
| `mix format --check-formatted` | 0 | no output |
| `mix compile --warnings-as-errors` | 0 | `Generated ashiato app` |
| `mix test` | 0 | `231 tests, 0 failures, 4 excluded` (1.5 s) |
| `MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix test --include postgres` | 0 | `231 tests, 0 failures` (1.8 s) |

Known noise, not failures: `Unknown translation provider "googel_free"`, `setting encryption failed:
SECRET_KEY_BASE missing`, `setting new_cards_per_day cannot be stored: foreign_key failed`.

A bare `ASHIATO_TEST_ADAPTER=postgres mix test` on the default `_build` exits 1 with the compile-time
`ecto_adapter` mismatch. Use the `MIX_BUILD_PATH=_build/pg` form above; CI compiles fresh with the
env var set and does not need it.

`pg_isready`/`psql` are absent on this host, but PostgreSQL listens on `localhost:5432` and the PG
suite above connected and passed.

## Constraints inherited from the spec

- No new dependencies.
- Edit existing migrations in place; no new migration file, no backfill.
- Dev and test database resets are approved for this wave; CI starts empty.
- Schema changes limited to nullable `encounters.crop_key` and the new `translations` table.
- SQLite and PostgreSQL must both pass; no dialect-specific SQL.
- Tests exercise public functions; fakes stay in `lib/`.
- Secrets and credentials are never logged. Translation cache reads, writes, and deletes pass
  `log: false` so they emit no Ecto query-log entries; verified by inspection.
- `config/prod.exs` gains `Oban.Plugins.Cron` for the daily prune; no other config keys change.
- No push and no PR without explicit approval.
- Deployment orchestration is out of scope; no Podman/Quadlet/Docker/systemd requirement.
