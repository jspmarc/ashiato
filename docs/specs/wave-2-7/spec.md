# Wave 2.7 — Prerequisites for ingest

**Status:** approved by user, 2026-11-16
**Baseline:** `79490e935a648ed4f2b6b29ec89b388da0e48693`, branch `main`, clean tree
**Source:** wave-3 readiness review, 2026-11-16

## Problem

Wave 3 (`docs/plan/wave-3.md`) cannot start. Four gaps sit outside its "owns
`lib/ashiato/ingest*`" boundary:

1. **No public way to mint a `words` row.** `Ledger.record_encounter/1` requires `word_id`,
   but `Ledger.find_or_create_word/2` is private (`lib/ashiato/ledger.ex:865`). The only public
   route, `introduce_words(force: true)`, also writes `word_states`, so every token becomes a
   queue card immediately — violating R2.8 and the encounter threshold.
2. **Encounters require `crop_key`, and no crop exists.** `Ashiato.Ocr` returns line boxes but no
   image; the tokenizer returns no geometry; there is no image dependency. `encounters.crop_key`
   is `NOT NULL`.
3. **Translations have nowhere to persist.** R7.3 requires a per-line cache, and
   `Ashiato.Translator` deliberately has none. No `translations` table exists, so wave 3 can only
   publish ephemeral text.
4. **No store→OCR locator mapping.** `Ashiato.Ocr.Socket.recognise/1` accepts `{:path, p}` or
   `{:url, u}`; there is no public `Ocr.recognise/1`. `Ashiato.Storage` exposes only the
   `presigned_get/2` callback, which `Ashiato.Storage.Local` answers as a `file://` URL. That URL
   must be parsed and percent-decoded by the receiver, and its path resolves in the receiver's
   container filesystem, so it couples both containers to the same absolute mount path. Nothing
   maps a store to an OCR locator today.

## Goal

Land those prerequisites in one small wave so wave 3 can stay inside the ingest boundary,
mint real word identities, store real crops for OCR pages, and cache translations.

## Decisions

- `Ledger.find_or_create_word/2` becomes public. It mints a `words` row only; no `word_states`
  row, so no card is queued.
- The OCR reply carries a required per-line crop: base64-encoded JPEG in a `crop` field. The
  client decodes it to raw bytes and requires a non-empty binary; it does not verify the JPEG
  signature or decode the image. It does not write storage. The socket reply cap rises from
  4 MiB to exactly 16 MiB (`16_777_216` bytes). `Ashiato.Ocr.recognise/1` becomes public and
  delegates to `impl()`, matching the `Tokenizer` and `Translator` façades. The Python
  `ashiato-ocr` service is external to this repository; this wave ships the wire contract, the
  Elixir client, the fake, and the stub test.
- `encounters.crop_key` becomes nullable. A text-layer PDF has no OCR line boxes and is not
  rasterised (D30), so an embedded-text encounter carries `crop_key = nil` and its card renders
  text only: lemma, reading, meaning. Real line crops need PDF text-layer coordinates in a later
  card. `crop_store` keeps its `NOT NULL` default and is ignored when `crop_key` is nil.
- A `translations` table caches one row per `(provider, target_lang, sha256(source_line))`.
  The service resolves `Translator.impl()` **once**, pins that module for the label and the call,
  and uses `provider.provider_name()`: a behaviour callback whose default is the fully qualified
  module name, with built-in providers declaring stable short names (`"google_free"`, `"llm"`,
  `"deepl"`, `"google_cloud"`, `"off"`) and `Fake` using `"fake"`.
  Switching provider never reads another provider's rows. `Ashiato.TranslatorService.translate_page/2`
  wraps the pinned provider:
  - every line cached and fresh → return the cached lines in input order, zero provider calls;
  - any miss or expired row → delete expired rows for the page's keys (`fetched_at` older than
    30 days), then make one `provider.translate_page/2` invocation over the full input, so
    cross-line context survives; the provider's own per-line fallback may still run. The returned
    lines are exactly the provider's output, duplicates and order preserved; missing rows are
    inserted with `on_conflict: :nothing`; fresh rows are never overwritten. Duplicate source lines
    insert once, from the first occurrence, and a later all-hit page returns that value for every
    duplicate;
  - TTL is 30 days, measured in whole seconds: `fetched_at >= now - 2_592_000` is fresh, older is
    expired. Equality is fresh;
  - `Ashiato.TranslatorService.PruneWorker` deletes every expired row with the same cutoff.
    Production schedules it daily at 03:00 UTC through `Oban.Plugins.Cron`; dev and test call
    `prune_expired/0` or `perform/1` directly;
  - provider errors insert or overwrite no translations; expired rows for the page's keys may
    already have been deleted by the cleanup step;
  - a missing, empty, or non-string `target_lang` returns `{:error, :missing_target_lang}` with no
    provider call and no write;
  - cache reads, writes, and deletes emit no Ecto query-log entries (`log: false`), so debug
    logging stays quiet.
- `Ashiato.Storage` gains a locator mapping. `Storage.Local` returns `{:key, object_key}`; the
  OCR service validates the key and resolves it under its own configured shared-volume root, so
  the two containers agree on the volume and the root, never on an absolute path. An S3 store
  will return `{:url, presigned}` when it exists. `Ashiato.Ocr.locator()` gains `{:key, key}`
  alongside `{:path, path}` and `{:url, url}`.
- A new service card, `docs/plan/ashiato-ocr.md`, documents the resident PaddleOCR service:
  socket protocol including the required `crop` reply field, locator request shapes, exact size
  cap, error shape, Paddle runtime flags, reference wrapper, container topology and shared
  volumes, and the fixture corpus. The orchestration mechanism (Podman, Quadlet, Docker, systemd,
  or other) is left open and is not a requirement of this wave. The service remains unbuilt and
  its implementation is not part of this repository's gate; wave 3 runs against fakes.
- `docs/requirements.md` §7.3 currently mandates Quadlet. That mandate is removed and replaced
  with a mechanism-neutral description: two containers in one pod, a shared socket volume, and a
  shared page-image volume. The service card uses the same neutral wording and mandates no
  orchestration product.
- Existing migrations are edited in place. The project is not in production, so no new migration
  file and no backfill: `encounters.crop_key` is created nullable, and the `translations` table is
  added to the table-creating migration.

## Non-goals

- No ingest pipeline, ingest Oban worker, state machine, progress events, or encounter writing
  (wave 3). The translation-prune Oban worker is in scope.
- No Python `ashiato-ocr` implementation; only the Elixir contract and stub.
- No PDF rasterisation, text-layer coordinate extraction, or line crops for embedded pages.
- No S3 storage implementation.
- No UI work: no review card rendering, no translation overlay (R1.11), no editor.
- No confirmation flow, chrome recomputation, or changes to `update_chrome_like/1`.
- No per-user translation cache and no provider selection changes; the cache is provider-scoped.
- No changes to `Ashiato.Translator` fallback or cooldown rules; only `provider_name/0` is added.

## Acceptance criteria

| ID | Criterion | Verified by |
|---|---|---|
| AC-1 | `Ledger.find_or_create_word/2` is public. It returns `{:ok, %Word{}}` for an existing and for a new `(user_id, lexeme_id)`; concurrent calls create exactly one row; it writes no `word_states` row; the returned id is accepted by `record_encounter/1`. `@doc` states that both ids must exist and that a missing user or lexeme raises `Ecto.ConstraintError`; tests assert that raise for each case without DB work after the assertion. | `mix test test/ashiato/ledger_test.exs`; `MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix test test/ashiato/ledger_concurrency_test.exs --include postgres` |
| AC-2 | `Ashiato.Ocr.recognise/1` is public and delegates to `impl()`. `Ashiato.Ocr` line maps carry a required `crop` as decoded, non-empty binary. `Socket.recognise/1` decodes a valid base64 `crop`; invalid base64, empty decoded bytes, or a missing crop return `{:invalid_line, index}`. The framed reply limit is exactly `16_777_216` bytes (4-byte length prefix excluded): a JSON body of that size is accepted and one of `16_777_217` bytes is rejected cleanly. The fake returns crops and records requests. | `mix test test/ashiato/ocr_test.exs` |
| AC-3 | `encounters.crop_key` is nullable in the migration and the changeset; `record_encounter/1` accepts a nil `crop_key` and returns the row; existing required fields still reject nil. The edited migration runs on SQLite and PostgreSQL from an empty database. | `mix test test/ashiato/ledger_test.exs`; `mix ecto.drop && mix ecto.create && mix ecto.migrate` under both adapters |
| AC-4 | `Ashiato.TranslatorService.translate_page/2` resolves `Translator.impl()` once, pins that module, and stores misses in `translations` keyed by `(provider_name, target_lang, sha256(line))`, where `provider_name = provider.provider_name()`. An all-hit fresh page returns cached lines with zero provider calls. Any miss or expired row deletes expired rows for the page's keys, then makes one pinned `provider.translate_page/2` call over the full page and returns exactly the provider output, duplicates and order preserved; missing rows are inserted with `on_conflict: :nothing`, fresh rows are never overwritten. Duplicate lines insert once from the first occurrence and a later all-hit page returns that value for every duplicate. TTL is 30 days in whole seconds: `fetched_at >= now - 2_592_000` is fresh; older is expired. Provider errors insert or overwrite nothing, though expired rows may already be deleted. A nil, empty, or non-string `target_lang` returns `{:error, :missing_target_lang}` with no provider call and no write. Cache reads, writes, and deletes emit no Ecto query-log entries (`log: false`). | `mix test test/ashiato/translator_service_test.exs`; inspection of `log: false` |
| AC-5 | `Storage.locator/2` returns `{:key, object_key}` for `Storage.Local`, rejects an invalid key, and the fake returns a recorded marker with the same tuple shape accepted by `Ocr.recognise/1`. `Ocr.recognise/1` accepts `{:key, key}` and sends it as the `key` field on the socket. | `mix test test/ashiato/storage_test.exs test/ashiato/ocr_test.exs` |
| AC-6 | `docs/diagrams/erd.dbml` shows `encounters.crop_key` as nullable and adds the `translations` table with its provider/lang/hash unique index and an expiry index. `docs/requirements.md` §7.3 and R7.3 document the required `crop` reply field, the `key` locator, the provider-scoped `(provider, lang, line)` translation cache with a 30-day TTL, and replace the Quadlet mandate with a mechanism-neutral two-container/shared-volume description; R2.6 records that embedded-text encounters are text-only until PDF line crops exist. No orchestration mechanism is mandated. Migration comments explain every new column and index. | inspection |
| AC-7 | `docs/plan/ashiato-ocr.md` exists and states: socket frame protocol, required `crop` reply field and encoding, locator request shapes including `key`, exact `16_777_216`-byte cap, error shapes, Paddle flags (`enable_mkldnn=False`, `FLAGS_enable_pir_api=0`, thread cap), reference wrapper path, two-container topology with a shared socket and image volume, the OCR-side image root config, and fixture-corpus policy. Orchestration mechanism is left open. It states the service is unbuilt and names no implementation in this repository. | inspection |
| AC-8 | The wave gate passes: formatting, warnings-as-errors, the full SQLite suite, and the PostgreSQL suite. | `mix format --check-formatted`; `mix compile --warnings-as-errors`; `mix test`; `MIX_BUILD_PATH=_build/pg ASHIATO_TEST_ADAPTER=postgres MIX_ENV=test mix test --include postgres`; `mix precommit` |
| AC-9 | `Ashiato.TranslatorService.PruneWorker.perform/1` deletes only rows with `fetched_at < now - 2_592_000` (whole seconds) and leaves rows at or above the cutoff. `TranslatorService.prune_expired/0` returns the deleted count. Production config schedules the worker daily at 03:00 UTC via `Oban.Plugins.Cron`; dev/test have no recurring insert. | `mix test test/ashiato/translator_prune_test.exs test/ashiato/config_test.exs`; inspection of `config/prod.exs` |

## Constraints

- **No new dependencies.**
- **Existing migrations are edited in place.** No new migration file, no data backfill. Local
  dev and test databases predate the edit and must be dropped and recreated; CI always starts
  empty. The user has approved dropping the local dev database for this wave.
- Only the two schema changes above. No other tables or columns.
- `config/prod.exs` gains `Oban.Plugins.Cron` for the daily prune; no other config keys are added
  or changed.
- Deployment orchestration is out of scope. Requirements must not mandate Podman, Quadlet,
  Docker, systemd, or any other mechanism; the service card states volumes and containers only.
  The existing Quadlet mandate in §7.3 is removed by this wave's docs task.
- The suite must run unchanged on SQLite and PostgreSQL. Migrations must not use dialect-specific
  SQL.
- Tests exercise public functions only, per `AGENTS.md`; fakes stay in `lib/`, not `test/support`.
- Secrets and credentials are never logged. Translation cache reads and writes emit no Ecto
  query-log entries; verified by inspecting `log: false` on those operations.
- No push and no PR without explicit approval.

## Context

- Affected modules: `lib/ashiato/ledger.ex`, `lib/ashiato/schemas/encounter.ex`,
  `lib/ashiato/outbound/ocr.ex`, `lib/ashiato/outbound/ocr/socket.ex`,
  `lib/ashiato/outbound/ocr/fake.ex`, `lib/ashiato/outbound/storage.ex`,
  `lib/ashiato/outbound/storage/local.ex`, `lib/ashiato/outbound/storage/fake.ex`,
  `lib/ashiato/outbound/translator.ex`, plus `Ashiato.TranslatorService`,
  `Ashiato.TranslatorService.PruneWorker`, and `Ashiato.Schemas.Translation`.
- Config: `config/prod.exs` adds the Cron plugin; no other config file changes.
- Migrations: the existing table-creating migrations are edited in place; exact paths are in the
  plan.
- Tests: `test/ashiato/{ledger,ledger_concurrency,ocr,storage,translator,config}_test.exs`, new
  `test/ashiato/translator_service_test.exs`, new `test/ashiato/translator_prune_test.exs`, plus
  the OCR stub in `test/support/ocr_stub.ex`.
- Wave 3 consumes these contracts; it is not changed by this wave.
