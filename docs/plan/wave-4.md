# Wave 4 — LiveView

Read `AGENTS.md` first; it wins over anything here.

**Depends on:** `wave-3.md` for the upload/editor screen, Wave 1's SRS for the review screen, Wave 1's
queries for the dashboard, and W2-6 (Settings) for the settings screen.

## How to work these cards

- Each screen card owns its own directory under `lib/ashiato_web/live/`. Creating files is fine; editing
  another card's directory is a merge conflict.
- **Only W4-5 edits `router.ex` and `layouts.ex`.** That card exists precisely so four parallel UI cards
  do not all edit the router.
- Gate: `mix format` → `mix compile --warnings-as-errors` → `mix test` → `mix precommit`.
- Do not edit `priv/repo/migrations/`.

## Model

Free `opencode/glm-5.3-flash-free` is fine for scaffolding; use 35B if a screen needs real state
reasoning (the review session does).

## Phoenix conventions that are enforced here

- Every template begins with `<Layouts.app flash={@flash} ...>`.
- `<.flash_group>` appears inside `layouts.ex` and nowhere else.
- Use the imported `<.input>` and `<.icon>` components; never a `Heroicons` module.
- A `current_scope` error means the route is outside the right `live_session` — fix the routing, not the
  template.

| # | Card | Owns |
|---|---|---|
| W4-1 | Upload + page list + text editor | `lib/ashiato_web/live/page_live*` |
| W4-2 | Review session | `lib/ashiato_web/live/review_live*` |
| W4-3 | Coverage + kanji map dashboard | `lib/ashiato_web/live/dashboard_live*` |
| W4-4 | Settings screen | `lib/ashiato_web/live/settings_live*` |
| W4-5 | Router + layout wiring | `lib/ashiato_web/router.ex`, `lib/ashiato_web/components/layouts*` |

---

## W4-1 — Upload, page list, text editor

- Upload accepts images **and PDFs**, multipart. A PDF becomes one `documents` row plus one `pages` row
  per PDF page (`document_id`, `page_index`).
- The page list reopens a stored page without re-photographing it (R1.9).
- The editor saves `accepted_text` and **bumps `revision`** in the same transaction (R1.3, R1.5) — that
  bump is what fences an in-flight ingest job.
- Acceptance: uploading a fixture image creates a page; saving an edit increments `revision`; the page
  list shows it again afterwards.

## W4-2 — Review session

- Card front is the line crop with **the target word named beneath it, not masked** (R3.2). The reason
  the word is named: the trained skill is receptive recognition, and naming it keeps the grade attached
  to the right word rather than to a different unknown word in the same line.
- Back: word, reading, meaning, kanji.
- Grading writes a `review_event` and updates the materialised `word_states`.
- **Occurrence rotation:** show the occurrence at `reps mod occurrence_count`, so every context is
  eventually seen and any given card is reproducible (R3.12). Never show a discarded or unconfirmed
  encounter's crop.
- Acceptance: grading advances `word_states`; a word with two encounters alternates crops across two
  reviews; a discarded encounter's crop never appears.

## W4-3 — Dashboard

- Per-source coverage and "N words to 95%" (R4.1).
- Kanji map: how many of the 2,136 常用漢字 have been met, with first and last seen (R4.2).
- The queries belong to Wave 1. **This card only renders them** — if a query is missing, do not write it
  here; leave the panel out and note it.

## W4-4 — Settings screen

- Choose the translation provider from all of them, toggle translation, toggle AI features, and enter
  each provider's credentials (R7.4).
- Each provider displays its readiness: *ready*, *needs an API key*, *needs a URL*. A misconfiguration
  should be visible here rather than as a failed page twenty minutes later.
- No provider is privileged; `google_free` is only the initial value.
- Writes go through `Ashiato.Settings` (W2-6) — never to the table directly, so secrets stay encrypted.

## W4-5 — Router and layouts

- Wires the four screens into `router.ex` under the correct `live_session`, and adds a navigation entry
  for each.
- Sole owner of `router.ex` and `layouts.ex`.
- Acceptance: `mix test` still green, `mix phx.routes` shows all four screens, and no template defines
  its own flash group.

---

## Definition of done

```
mix format
mix compile --warnings-as-errors
mix test
mix precommit
```

A screen is not done because it renders. It is done when a test drives the interaction (upload creates a
page, saving bumps `revision`, grading advances `word_states`) and would fail with the handler removed.
