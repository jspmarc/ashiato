# Ashiato

An application to help your Japanese study and the reading of 足跡 (footprint).
Take a photo of a Japanese sentence, get the translation, meaning of each word, and add them to your study SRS.

The design lives in `docs/requirements.md`; the work is split into waves in `docs/plan/`.

## Status

Early, and honest about it. The ledger and the scheduler exist and are tested; nothing is wired to a UI
or to a real external service yet.

| Wave | Area | State |
|---|---|---|
| 1 | Ledger (pages, revision fencing, encounters, introduction) + FSRS-6 | done |
| 2 | Service clients: tokenizer, dictionary, OCR, translator, storage, settings | next |
| 3 | Ingest pipeline | not started |
| 4 | LiveView screens | not started |

**The external services are specified, not built.** `jp-dict-api` (dictionary + `/tokenize`) and
`ashiato-ocr` (PaddleOCR over a Unix socket) do not exist yet, so every client is reached through a
behaviour with a fake, and **no test may call a real service**. §7 of the requirements describes the
intended contracts, not running code.

## Code layout

```
lib/ashiato/
  ledger.ex  srs.ex  settings.ex    contexts: the only modules that query the database
  schemas/                          one Ecto schema per table, Ashiato.Schemas.*
  services/                         external clients: behaviour + implementation + fake
  repo.ex  application.ex  mailer.ex  utils.ex
```

`schemas/` sits outside any single context because the schemas are shared: both `Ashiato.Ledger` and
`Ashiato.Srs` use `Word`, `WordState` and `ReviewEvent`. It is deliberately not called `repo/` —
`Ashiato.Repo` is the database connection, and these files are rows.

## Development

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Before committing: `mix precommit` (format, compile with warnings as errors, unused-deps check, tests).

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

### Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
