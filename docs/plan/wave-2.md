# Wave 2 — service clients

Read `AGENTS.md` first; it wins over anything here.

Prerequisite: migrations, eleven Ecto schemas (`Ashiato.Schemas.*`), seeds and the first three
`Ashiato.Ledger` functions exist with 15 passing tests. Wave 1 (the rest of the ledger plus SRS) is
separate and **Wave 2 does not depend on it** — the six cards here are independent of each other and of
Wave 1.

## How to work a card

- **One card = one file owner.** Creating files is fine; editing another card's files is a merge
  conflict. The `Owns` column below is the contract.
- Gate for every card: `mix format` → `mix compile --warnings-as-errors` → `mix test` → `mix precommit`.
- Tests only for public functions, per `AGENTS.md`.
- No new dependencies unless the card says so explicitly.
- Do not edit `priv/repo/migrations/`.

## Model

The free `opencode/glm-5.3-flash-free` is fine here, but these cards are literal: the behaviour spec, the
fake contract and the acceptance test are all stated. Implement what is written rather than inventing an
interface.

## Code layout (already in place)

```
lib/ashiato/
  ledger.ex  srs.ex                 contexts — the only modules that query the database
  settings.ex                       context, added by W2-6
  schemas/                          Ashiato.Schemas.*, one Ecto schema per table
  services/                         external clients, one directory each:
    tokenizer.ex                      behaviour + impl()/0
    tokenizer/http.ex                 Ashiato.Tokenizer.Http
    tokenizer/fake.ex                 Ashiato.Tokenizer.Fake
    ...
```

Schema modules were renamed to singular under `Ashiato.Schemas` (`Ashiato.Pages` → `Ashiato.Schemas.Page`)
so no schema name collides with a behaviour or context name. Do not add new files directly under
`lib/ashiato/` except a context.

## All six cards can run in parallel

| # | Card | Owns (may edit) |
|---|---|---|
| W2-1 | `Ashiato.Tokenizer` behaviour + HTTP impl + fake | `lib/ashiato/services/tokenizer*`, `test/ashiato/tokenizer_test.exs` |
| W2-2 | `Ashiato.Dictionary` + cache + fake | `lib/ashiato/services/dictionary*`, `test/ashiato/dictionary_test.exs` |
| W2-3 | `Ashiato.Ocr` Unix-socket client + fake | `lib/ashiato/services/ocr*`, `test/ashiato/ocr_test.exs` |
| W2-4 | `Ashiato.Translator` provider behaviour + fakes | `lib/ashiato/services/translator*`, `test/ashiato/translator_test.exs` |
| W2-5 | `Ashiato.Storage` behaviour + local impl | `lib/ashiato/services/storage*`, `test/ashiato/storage_test.exs` |
| W2-6 | `Ashiato.Settings` typed accessor + encrypted secrets | `lib/ashiato/settings*`, `test/ashiato/settings_test.exs` |

## Shape every card shares

A behaviour, one real implementation, one fake, and a test that drives the behaviour through the fake.
**No card may call a real external service in a test** — neither `ashiato-ocr` nor `jp-dict-api` exists
yet, so the fake is the only way this code can be exercised.

Naming: `Ashiato.X` is the behaviour, `Ashiato.X.Http` (or `.Socket`, `.Local`) the implementation,
`Ashiato.X.Fake` the test double, and `Ashiato.X.impl()` returns the configured implementation from
application config so later waves depend on the behaviour and never on a concrete module.

---

## W2-1 — `Ashiato.Tokenizer`

```elixir
@callback tokenize(text :: String.t()) :: {:ok, [token]} | {:error, term()}
# token :: %{surface: String.t(), lemma: String.t(), reading: String.t(), part_of_speech: String.t()}
```

- `Ashiato.Tokenizer.Http` — `Req.post!` to `{JP_DICT_API_URL}/tokenize`, JSON in and out.
- **Readings must be normalised to hiragana in the client.** Sudachi returns katakana (タベル); lexeme
  identity is `lemma + reading`, so an unconverted reading mints a second row for the same word.
  Katakana U+30A1..U+30F6 map to hiragana by subtracting 0x60.
- `Ashiato.Tokenizer.Fake` — canned response, configurable per test, and it records what it was asked.
- Also verify the measured behaviour holds end to end: kana is **not** converted to kanji (たべる stays
  たべる), inflection **is** normalised (食べた → lemma 食べる), homophones stay distinct (はし / 橋 / 箸).
- Acceptance: a test asserting a katakana reading comes back as hiragana; a test asserting the HTTP
  implementation maps the service's JSON shape; `mix precommit` green.

## W2-2 — `Ashiato.Dictionary`

```elixir
@callback lookup(term :: String.t()) :: {:ok, entry} | {:error, term()}
@callback lookup_many(terms :: [String.t()]) :: {:ok, %{String.t() => entry}} | {:error, term()}
```

- Uses `dict_cache_entries`, keyed `(kind, cache_key, dict_version)`. **Every lookup checks the cache
  first**, and a cache hit must not touch the network.
- `dict_version` comes from the service. When it changes, cached rows are simply no longer matched —
  never updated in place, because the ledger must not silently rewrite what it claims you studied.
- `kind` is `"word"` or `"kanji"`, matching the CHECK constraint. `payload` is `jsonb`, so store a map.
- Acceptance: a cache-hit test asserting zero HTTP calls (the Fake counts them); a version-bump test
  asserting old rows are ignored rather than mutated.

## W2-3 — `Ashiato.Ocr`

```elixir
@callback recognise(locator :: {:path, String.t()} | {:url, String.t()}) ::
            {:ok, [%{bbox: [integer()], text: String.t(), score: float()}]} | {:error, term()}
```

- `Ashiato.Ocr.Socket` — `:gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false])`,
  send one JSON object, read one reply. `packet: 4` is a 4-byte big-endian length prefix and is the
  entire framing protocol.
- The request is `{"op": "ocr", "path": ...}` or `{"op": "ocr", "url": ...}` — a locator, never image
  bytes. With the `s3` store the app presigns a GET and sends the URL.
- Boxes are normalised 0–1000 by the service. Validate the range and reject a malformed block rather
  than passing it on.
- Acceptance: a test against a stub Unix socket in `test/support` (this card owns creating it) proving
  one round trip, and a clean error when the socket is absent.

## W2-4 — `Ashiato.Translator`

```elixir
@callback translate_page(lines :: [String.t()], opts :: keyword()) ::
            {:ok, [String.t()]} | {:error, term()}
```

- One request per page, so cross-line context survives. Providers: `google_free` (default), `llm`,
  `deepl`, `google_cloud`, `off`.
- The `llm` provider asks for a **JSON array** of strings and falls back to per-line when the array does
  not parse. NMT providers return line-aligned text directly. **If the returned line count differs from
  the input, fall back to per-line.**
- **No caching in this card.** That would need `dict_cache_entries.kind = 'translation'`, which the CHECK
  constraint forbids, so caching waits for a migration that adds the value. Do not widen the constraint
  here, and do not repurpose an existing `kind`.
- `Ashiato.Translator.Fake` returns deterministic output and records calls.
- Acceptance: a 3-line page produces 3 lines; a mismatched line count triggers the per-line fallback.

## W2-5 — `Ashiato.Storage`

```elixir
@callback put(key :: String.t(), binary()) :: :ok | {:error, term()}
@callback get(key :: String.t()) :: {:ok, binary()} | {:error, term()}
@callback presigned_get(key :: String.t(), ttl_seconds :: pos_integer()) :: {:ok, String.t()}
@callback delete(key :: String.t()) :: :ok | {:error, term()}
```

- `Ashiato.Storage.Local` writes under a configurable root and presigns to `file://`.
- **S3 is a separate, later card.** SigV4 presigning needs either a new dependency or hand-rolled
  `:crypto` work; do not take that on here. Ship the behaviour plus `Local` so the pipeline is
  unblocked.
- Acceptance: put/get/delete round trip in a temp directory, and a presigned path the OCR fake can
  consume.

## W2-6 — `Ashiato.Settings`

- Typed accessor over the `settings` key-value table: `get(user_id, key, default)`,
  `put(user_id, key, value, opts)`, `all(user_id)`.
- **This module is the only place that knows settings are key-value.** Everything else calls it.
- Values are JSON-encoded in the `value` column. Rows with `secret: true` are encrypted with a key
  derived from `SECRET_KEY_BASE` — `Plug.Crypto.MessageEncryptor` is already available through
  `plug_crypto`, so no new dependency — and the plaintext is never logged.
- Capability helpers: `ai_capable?/1` (switch on **and** an API key present) and `translate_capable?/1`
  (translation enabled **and** the selected provider configured).
- Acceptance: a secret round-trips through encrypt/decrypt; a non-secret row is readable as plain JSON;
  `ai_capable?` is false when the switch is on but the key is missing.

---

## Definition of done

```
mix format
mix compile --warnings-as-errors
mix test
mix precommit
```

A card is not done because it compiles. It is done when its acceptance test drives the behaviour through
a fake and would fail with the implementation removed.
