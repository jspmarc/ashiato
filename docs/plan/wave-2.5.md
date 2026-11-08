# Wave 2.5 — shared HTTP transport

Read `AGENTS.md` first; it wins over anything here.

**Depends on:** W2-1, W2-2, and W2-4. Their HTTP clients exist and define the
behaviour this card consolidates.

**Why this exists:** `Ashiato.Tokenizer.Http`, `Ashiato.Dictionary.Http`, and
`Ashiato.Translator.http_post/2` repeat the same transport concerns: URL
validation, retry policy, timeouts, status mapping, exception handling, and test
injection. The copies have drifted: only two set timeouts, only two sanitize
transport reasons, and only two allow `:plug` injection. One module fixes that
without coupling the services to each other.

## How to work this card

- **This card owns `lib/ashiato/outbound/http.ex` and `test/ashiato/http_test.exs`.** It may
  edit the three clients named below and their tests; it changes no other module.
- Gate: `mix format` → `mix compile --warnings-as-errors` → `mix test` →
  `mix precommit`.
- No new dependencies. `Req` is already present.
- Do not add tokenizer, dictionary, or translator response shapes to this module.
  Each service keeps its own parser.

## Naming and placement

The module is `Ashiato.HTTP`, not `Ashiato.Http`, deliberately: it is the umbrella transport, and the
capitalised acronym marks it as infrastructure rather than one more client. The per-client modules keep
`Ashiato.X.Http` (`Ashiato.Tokenizer.Http`, `Ashiato.Dictionary.Http`) — that asymmetry is intended, not
a thing to "fix".

It lives at `lib/ashiato/outbound/http.ex`, inside the directory that holds everything crossing the
process boundary, directly under `AGENTS.md`'s layout rule. Do not add it to `lib/ashiato/` root.

## Contract

```elixir
@spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
@spec post(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
```

Options passed through to `Req`:

- `:headers` — request headers.
- `:json` — JSON request body.
- `:form` — form request body.
- `:params` — query parameters.
- `:receive_timeout` — default `10_000` ms.
- `:request_timeout` — default `10_000` ms.
- `:plug` — test-only adapter injection; forwarded unchanged.

Rules:

- Validate the URL with `URI.new/1`. Accept only `http` and `https` with a
  non-empty host; otherwise return `{:error, :invalid_url}` without calling Req.
- Always set `retry: false` and `redirect: false`.
- Return `{:ok, body}` for a 200 reply. Req may have decoded a JSON body already;
  the caller owns the shape check.
- Return `{:error, {:http, status}}` for any other status. Do not return the body:
  it can echo user text.
- Reduce transport failures to `{:error, {:transport, reason}}`, where `reason` is
  an atom. Provider or protocol binaries never reach a caller or a log.
- Map a malformed JSON reply to `{:error, :invalid_json}`. The `Jason.DecodeError`
  struct carries the response body in `data`; it must not escape.
- Never raise. Rescue Req and decoder exceptions at this boundary.
- Never log the URL, body, headers, or credentials.

## Migration

1. Add `Ashiato.HTTP` and its tests.
2. Switch `Ashiato.Dictionary.Http` (`lib/ashiato/outbound/dictionary/http.ex`) to it. Keep
   the dictionary reply validation and cache payloads; delete the local `safe_reason/1`
   and request error mapping.
3. Switch `Ashiato.Tokenizer.Http` (`lib/ashiato/outbound/tokenizer/http.ex`) to it. Keep
   the token parsing and hiragana normalisation; replace `Req.post!` and the local rescue.
4. Switch `Ashiato.Translator.http_post/2` (`lib/ashiato/outbound/translator.ex`) to it.
   Keep the per-provider `decode/1` functions and the page fallback rule. Pass the caller's
   `:plug` option through, so a provider can be stubbed — see the acceptance criteria.
5. One status error shape, `{:error, {:http, status}}`, replaces the
   `{:unexpected_status, status}` tuples. The live assertions are in
   `test/ashiato/tokenizer_test.exs`; the dictionary client already maps statuses the new
   way.
6. After migration, `Req` is called only from `Ashiato.HTTP`; the services call the
   shared module.

## Acceptance

`test/ashiato/http_test.exs` drives every branch through `Req.Test`:

- a 200 JSON reply comes back decoded, and a 200 text reply comes back as a binary
- a non-200 reply returns only the status
- a malformed URL and a non-HTTP scheme return `{:error, :invalid_url}`
- a transport failure returns a sanitized atom reason
- a malformed JSON reply returns `{:error, :invalid_json}` and never the body
- `:plug` injection works without a socket

One service test per migrated client must still pass through `:plug`, proving the
shared module is wired in rather than bypassed.

**And one provider test**, which is the reason this card exists as much as the duplication is:

```elixir
# exercise the real parser against the documented wire shape, no socket
Application.put_env(:ashiato, Ashiato.Translator,
  provider: :google_free,
  plug: {Req.Test, Ashiato.Translator.GoogleFree}
)

Req.Test.stub(Ashiato.Translator.GoogleFree, fn conn ->
  Req.Test.json(conn, [[["こんにちは", "hello"]], nil, "ja"])
end)

assert Ashiato.Translator.GoogleFree.translate_page(["こんにちは"], target_lang: "en") ==
         {:ok, ["hello"]}
```

Pick one provider (GoogleFree is the default and the one with the undocumented wire shape, so it is
the best value) and assert its `decode/1` through `:plug`. Without this, every provider's mapping stays
covered by nothing but compilation, which is exactly how it shipped in W2-4.

## Definition of done

```
mix format
mix compile --warnings-as-errors
mix test
mix precommit
```

The migration is done when no service owns a private HTTP client anymore. If a
service still needs its own rescue, status mapping, or timeout setup, the shared
module is missing a rule.
