# Ashiato — Requirements

**Status:** Draft, agreed through design review
**Owner:** Josep Marcello
**Repo:** private (`jspmarc/ashiato`)

---

## 1. Purpose

Ashiato (足跡, "footprints") is a personal Japanese reading and vocabulary system. You photograph
Japanese text you meet in the world — a game screen, a manga page, a sign in Tokyo — and the app
transcribes it, helps you understand it, and silently records which words you met. Those encounters
become a personal ledger, and the ledger drives a spaced-repetition queue.

The point is not to build a better flashcard app. The point is that **what you study is a record of
what you have actually read**, not a list someone else wrote.

### 1.1 Single user

Built for one person: the owner. Multi-user is **not planned**, but the schema must be **prepared
for it** — adding it later must not require a migration. Concretely: every table carries `user_id`
from the first migration, and every unique constraint includes it (see §6.2).

There is no auth, no account, no onboarding flow, and no sharing in v1.

### 1.2 The honest limitation

Nobody can retro-photograph their past. The ledger is empty on day one and becomes genuinely useful
after months, not weeks. Any feature designed around "instant value on first launch" is solving a
problem this app does not have.

---

## 2. Non-goals (v1)

- Multi-user (not planned; schema prepared for it, see §1.1), accounts, sharing, social features
- **Standard JLPT-level decks for introduction.** Planned, not in v1: introducing cards from a
  canned N5–N1 ordering instead of only from your own encounters. The ledger stays the default source
  of truth for what gets studied; a standard deck is an opt-in shortcut, not a replacement.
- Native mobile app (responsive web is sufficient)
- Handwriting practice / stroke-order grading (production cards are deferred; see R3.7)
- Audio, TTS, listening practice
- Grammar SRS (grammar is tracked as a separate concern, not in this app)
- Anki and WaniKani progress import — deferred to the next scope (Epic 8)
- Bunpro import (no official API; only an unstable reverse-engineered one)
- Anki export of review intervals (export is a known-words list only; see R5.4)

---

## 3. Glossary

| Term | Meaning |
|---|---|
| **Token** | One morphological unit produced by the tokenizer, with lemma, reading, and POS |
| **Word** | A distinct vocabulary item, identified by `lemma + reading` |
| **Lemma** | Dictionary form. 食べた / 食べます / 食べる all normalise to 食べる |
| **Kanji** | A single character, identified by the glyph |
| **Encounter** | One observed occurrence of a word: source, date, line crop, normalized text |
| **Source** | Where an encounter came from — a game, a manga, a book, optionally a chapter |
| **Mature** | A word whose FSRS **stability** is at or above the maturity threshold (default 21 days, configurable). A derived predicate, never a stored flag |
| **Remedial step** | A short sub-day delay after a failed review: 4h → 12h → 24h; 24h repeats until a pass. It sets `due_at`, not stability |
| **Ghost** | The scheduler mode entered on the second consecutive `again` with no pass in between. Not an FSRS state and not a memory score |
| **Massed exposure** | High `occurrences` over few `days_seen`. A ranking/resurfacing signal, not a ghost and not a scheduler mode |
| **Leech** | A word that repeatedly fails across normal reviews. A flag, not a scheduler |
| **Failure streak** | `word_states.failure_streak`: consecutive `again` grades, reset by any pass. Drives remedial and ghost scheduling and never FSRS (R3.13) |
| **Content word** | Noun, verb, adjective, adverb. Not particles, auxiliaries, or punctuation |
| **Coverage** | Fraction of tokens in a text whose words are already known |
| **Page** | One processed image. Identity is a hash of its normalized text |
| **Tokens** | Raw count of a word in accepted text. Depth |
| **Occurrences** | Number of distinct pages containing a word, once per page. Breadth |
| **Lexeme** | A distinct lexical item — `lemma + reading + POS`. Global and shared, not owned by a user |
| **FSRS** | Free Spaced Repetition Scheduler, **version 6** (21 weights, `w0..w20`). Owns stability, difficulty and the day-scale interval; decay is learned (`w20`) rather than fixed, and the curve factor is derived from the desired retention |
| **Stability (S)** | FSRS variable: days until recall probability decays to 90%. "How long until I'd forget this" |
| **Difficulty (D)** | FSRS variable, 1–10: how hard this item is *for this user*. Rises on lapses, falls on easy recalls |
| **Retrievability (R)** | FSRS variable: probability of recall *right now*, given S and elapsed time |
| **Chrome-like** | A word appearing on more than a set fraction of a source's pages — HUD, menus, system text |

---

## 4. Load-bearing design principles

These are decisions that everything else follows from. Each one has a reason; if a feature conflicts
with one, the feature is wrong.

**P1. The word is the reviewable unit. Kanji is a derived index.**
Readings belong to words, not characters. 生 has a dozen readings; a card saying "生 = life" teaches
nothing usable at 生簀 or 一生懸命. Kanji are reviewed *through* words, or through discrimination
drills (R3.7), never through "what does this character mean".

**P2. Encounters flow one way.**
Word reviews update kanji state. Kanji never schedule independent review of the same knowledge — two
schedulers reviewing one thing fight each other and produce worse results than either alone.

**P3. A kanji is known when ≥1 word containing it is mature AND it appears in ≥2 distinct words.**
*Mature* means that word's FSRS **stability** has reached the maturity threshold (default 21 days) —
the point at which recall is projected to survive weeks without review. Stability is used rather than
interval because stability is FSRS's own measure of memory strength, while the interval is a
scheduling choice. Derived from review history, never set by hand.
The second clause is the load-bearing one. A kanji known from a single word is word knowledge
wearing a character's costume.

**P4. Three counters, not one.**
`occurrences` (distinct pages containing the word — utility ranking), `distinct_sources` (context
diversity), `days_seen` (distinct calendar days). `days_seen` is the strongest retention signal;
spaced encounter beats massed encounter. Raw token depth is tracked separately as `tokens` (§6.5).

**P5. Recall sets the interval. Frequency only decides what to study next.**
FSRS owns scheduling. Encounters, occurrences, and `days_seen` decide introduction order and
resurfacing; they never change the due date. Capping intervals by frequency would override FSRS and
double-count a signal the app already has: a frequent word will meet you again in real material.

How the counters and the scheduler actually combine is specified in §6.4.

**P6. Stats are derived, never stored counters.**
A stored counter drifts the first time a batch is imported twice, and then the whole ranking is built
on lies. Derived from the event log, recomputable at any time.

**P7. Never store per-kanji readings.**
No clean alignment exists (今日, 大人, 一人 do not decompose). Store the word's reading.

**P8. Every token is dictionary-validated.**
Keep only tokens that exist as real words. This drops OCR garbage — but *not* plausible substitution
(未/末, 士/土, 待/持, 微/徴), which needs human confirmation on first encounter plus retained crops.

**P9. Store what identity needs; fetch what the dictionary owns.**
`lemma`, `reading`, and `part_of_speech` are stored — `reading` is half the identity key, and the
tokenizer produced it anyway. Meanings, kanji readings, JLPT levels, frequency ranks, and component
data are cached from the dictionary service under a version stamp, never written into the ledger.
A dictionary update must not silently rewrite what the ledger says you studied.

---

## 5. Functional requirements

Priority: **M** = must have in v1, **S** = should have, **C** = could have / later.

### Epic 1 — Capture and understand

| ID | Pri | Requirement |
|---|---|---|
| R1.1 | M | Photograph a passage and see it transcribed line by line. |
| R1.2 | M | Upload one or more images in a single action; a batch becomes N pages queued as one group. |
| R1.3 | M | Correct the transcribed text before anything is recorded. |
| R1.4 | M | Rotate and apply perspective correction to a page, then re-run. |
| R1.5 | M | Replace a page's photo without losing the recorded encounters. |
| R1.6 | M | See furigana above every token containing kanji. |
| R1.7 | M | Tap a token to see its reading, meaning, and the kanji it contains. |
| R1.8 | S | See a translation of the passage, or of a selected phrase. Optional AI feature (R7). |
| R1.9 | M | Browse a list of stored pages and reopen any without re-photographing. |
| R1.10 | S | When two OCR backends are configured, run both. Where they agree, auto-accept; where they disagree, require confirmation before those tokens are recorded. |
| R1.11 | S | Produce a translated page image with each line's translation painted over it, as `jp-reader` does, alongside the plain text list. |

**Acceptance (R1.3):** text edits are saved before tokenization; the recorded ledger reflects the
corrected text, and the original OCR output is retained separately for audit.

**Acceptance (R1.10):** disagreement is a *confidence* signal, not a correctness one — two backends can
agree and both be wrong (see §7.3), so agreement never overrides the human confirmation pass on first
encounter.

### Epic 2 — Record encounters (the ledger)

| ID | Pri | Requirement |
|---|---|---|
| R2.1 | M | Every content word in a processed page is recorded as an encounter automatically — no confirmation step. |
| R2.2 | M | The same line photographed twice counts once. Dedupe by hash of normalized text. |
| R2.3 | M | Mark a word as already known while reading, so it never becomes a card. |
| R2.4 | M | Attach a page to a named source, optionally with a chapter/episode. |
| R2.5 | M | For any word, see every place it was met, with the crop for each. |
| R2.6 | M | Store a per-line crop permanently; store the full page image with a 30-day TTL. |
| R2.7 | S | Discard an individual encounter (bad OCR) without deleting the word. |
| R2.8 | M | Encounters are recorded automatically but carry a `confirmed` flag. Unconfirmed encounters count toward nothing — no ranking, no queue entry, no coverage. Confirmation happens once per word, not per page. |
| R2.9 | M | When a word becomes chrome-like, an existing card is suspended with reason `chrome`. History preserved, coverage still counts it, clearing the flag restores it. |

**Acceptance (R2.1):** particles, auxiliaries, punctuation, and standalone numerals are not recorded.
Proper nouns are recorded but flagged, so they can be excluded from ranking.

**This resolves a real tension.** R2.1 says record automatically with no confirmation step; P8 says
plausible substitutions need human confirmation. Both are satisfiable: record everything, but only
confirmed tokens influence anything. The cost is one confirmation per *new word*, not per page, and it
is the only defence against 貴方→何方, which dictionary validation cannot catch.

**Acceptance (R2.2):** re-uploading the same image, or photographing a repeating dialogue box, does not
increase any word's counters. HUD and menu text is flagged `chrome_like` and does not drive ranking
or introduction (§6.5).

### Epic 3 — Review (SRS)

| ID | Pri | Requirement |
|---|---|---|
| R3.1 | M | A review session presents due cards, one at a time, gradeable. |
| R3.2 | M | Card front = the line crop where the word was met, **with the target word named beneath it, not masked**. Card back = word, reading, meaning, kanji. One card per word. |
| R3.3 | M | Grading updates FSRS state for that word. |
| R3.4 | M | A word is not introduced to the queue until it has been encountered at least N times, N configurable (default 2), with a force-add override. |
| R3.6 | M | When a word is encountered in new material while its interval is long, resurface it immediately rather than waiting for its due date. |
| R3.7 | S | Opt-in kanji discrimination drill: minimal pairs (e.g. 待/持/時/特), multiple choice, back of card explains the distinguishing radical. Generated only for kanji with ≥2 encountered words. Minimum-encounter threshold configurable, force-add available. |
| R3.8 | M | Suspend a word indefinitely; suspend + mark mastered (excluded from queue, still counted in coverage). |
| R3.9 | M | New-card introduction ordered by priority (frequency within own material × novelty), capped per day. |
| R3.10 | S | Filter new-card introduction by JLPT level relative to the user's own level setting. |
| R3.11 | S | Flag and surface leeches: words met often but repeatedly failed. A leech flag does not change scheduling. |
| R3.12 | M | A word met in several pages shows one occurrence per review, chosen deterministically by `reps mod occurrence_count`, so every context is eventually seen and any card is reproducible. Never show a discarded or unconfirmed encounter. |
| R3.13 | M | A first `again` schedules a 4-hour remedial step. A second consecutive `again` with no pass in between enters ghost mode: 12 hours, then 24 hours, repeating 24 hours until a pass. A pass clears the failure streak and returns the word to normal FSRS scheduling. Remedial steps set `due_at` only; FSRS stability and difficulty still update normally. |

**Acceptance (R3.2):** grading a word card never advances a kanji card, and a kanji is never presented
as "what does this mean".

**Why the word is named rather than masked.** The skill being trained is *receptive*: see the word in a
real sentence and know what it means. That is what reading actually requires, and it is what the card
should test. Masking would turn the same card into a cloze — a production task — which is a different
skill, and one that also needs token-level geometry and an alignment between tokenizer tokens and OCR
glyph boxes that does not exist yet. Naming the word keeps the context doing its job while making the
stimulus visible, so no mask has to be drawn and no geometry has to be stored.

The word is also named so the grade stays attached to the right thing: if the front showed a sentence and
said nothing about which word it was for, a failure caused by a different unknown word in the same line
would push *this* word's FSRS interval down for reasons that have nothing to do with it.

**Acceptance (R3.4):** changing N triggers a recomputation of which words qualify for introduction.
It must never remove or reset a card already in review rotation.

**Deliberately excluded:** `bury` (sibling burying / "not today"). Suspend covers the use case and has
a durable meaning.

### Epic 4 — Progress and coverage

| ID | Pri | Requirement |
|---|---|---|
| R4.1 | M | Per-source coverage: percentage of tokens whose words are known, and "N words to 95%". |
| R4.2 | M | Kanji map: how many 常用漢字 have been encountered, which ones, first and last seen per character. |
| R4.3 | S | Onomatopoeia / mimetic word tracking, as a distinct view. They are almost all kana, so they can never appear in a kanji map. |
| R4.4 | S | Words met frequently but failing repeatedly (leesches, cross-referenced with R3.11). |

**Acceptance (R4.1):** coverage is computed over the user's own material, not a general corpus. That
is the number that predicts whether a given source is readable, and the one no existing tool supplies.

### Epic 5 — Curation and hygiene

| ID | Pri | Requirement |
|---|---|---|
| R5.1 | M | Offer a merge for **orthographic variants**: same reading, same POS, and one lemma contains no CJK character at all ("kana-only") while the other contains at least one ("kanji-bearing"). Merge candidates: たべる ↔ 食べる (タベル, verb), いけす ↔ 生簀 (イケス, noun). Never auto-merge two **kanji-bearing** lemmas sharing a reading — 橋 and 箸 are different words, and checking "same reading" alone would fuse them. |
| R5.2 | M | Delete an encounter or an entire source; derived stats recompute. |
| R5.4 | M | Export the known-words list in a portable format. |

### Epic 6 — Lookup and detail

| ID | Pri | Requirement |
|---|---|---|
| R6.1 | M | Search by text across the ledger and the dictionary. |
| R6.2 | M | Word detail: reading, meaning, part of speech, the kanji it contains, and every encounter with its crop. |
| R6.3 | M | Kanji detail: onyomi, kunyomi, meanings, JLPT level, frequency rank, component breakdown, and every ledger word containing it. |
| R6.4 | S | Mnemonics on both word detail and kanji detail (R7.1). |
| R6.5 | S | Example sentences on both (R7.2). |

### Epic 7 — Optional AI assistance

All features in this epic are **off unless the user enables them** (`ai_features_enabled`, default
false). `OPENAI_BASE_URL` and `OPENAI_API_KEY` are **credentials, not switches** — AI features cannot
work without them, but setting them must not turn anything on by itself. Capability is checked at boot
and exposed to the UI, so affordances hide rather than fail.

OCR is *not* in this epic. It runs on the local PaddleOCR service and needs no AI credentials (§7.3),
which is what makes the credentials genuinely optional rather than effectively required.

**So "optional" now means optional.** `OPENAI_BASE_URL` defaults to `https://api.openai.com/v1`, and the
LLM backend may be anything OpenAI-compatible (llama.cpp, vLLM, a proxy). Only `OPENAI_API_KEY` has no
default. Capability is computed once at boot:

```
ai_capable = ai_features_enabled AND OPENAI_API_KEY present
```

An empty key disables every AI affordance even if the switch is on, and the UI hides the buttons rather
than offering something that will fail.

**Translation is gated separately** (§7.5). It is not an LLM feature and does not require an LLM: it has
its own provider set, its own switch, and its own credentials.

| ID | Pri | Requirement |
|---|---|---|
| R7.1 | S | Mnemonic generation for a word or kanji. Stored, cached, user-editable. Regenerating over an edit requires confirmation and keeps the previous version. Records which model and prompt version produced each. |
| R7.2 | S | Generate 1–3 example sentences per word. The prompt includes the user's own recorded meaning and the source sentence, so generated sentences match the sense actually learned. Validate the target word appears with the expected reading before displaying. |
| R7.3 | S | Passage translation in one request per page, so cross-line context survives. The `llm` provider is asked for a **JSON array** of strings and falls back to per-line if it does not parse; NMT providers return line-aligned text directly. Results cached per line by `(lang, line)`. Provider and gate: §7.5. |
| R7.4 | M | Settings screen: choose the translation provider from all of them, toggle translation, and enter each provider's credentials. Each provider displays its readiness. No provider is privileged. |

**Note:** the user's own encounters are the primary source of example sentences. Generated ones are
supplementary.

### Epic 8 — Imports (deferred to the next scope)

Not in this scope. Anki and WaniKani import were specified as a cold-start mitigation and a way to seed a
known baseline; both are pushed to the next scope. Bunpro was already out — no official API exists, only a
permissioned reverse-engineered one that is explicitly unstable.

The requirement that would return with them is unchanged: **imported progress is a known baseline, never
review state.** Merging foreign intervals with local FSRS parameters produces nonsense (D10).

---

## 6. Data semantics

### 6.1 Identity rules

- **A word is `lemma + reading`, and that pair belongs to a lexeme.** Same spelling with a different
  reading is a different word (生物 せいぶつ vs なまもの). `reading` is non-null with a `""` default so
  the unique constraint actually bites — multiple NULLs pass a unique index on both SQLite and
  Postgres. Uniqueness is `(lemma, reading, part_of_speech)` on the **shared** `lexemes` table, not per
  user; see §6.3.
- **Page identity is a hash of its normalized text**, unique per user. Re-uploading the same screen
  creates nothing new. It is a hash rather than the text itself because a Postgres btree index entry
  is capped at roughly 2.7 kB — a page of Japanese dialogue exceeds that and the insert would fail —
  and because NFKC/whitespace normalization has to happen once, before comparison, not on every
  lookup. A SHA-256 hex digest is a fixed 64 bytes whatever the page length.
- **Encounter identity is `(user, word, page-text hash)`** — one encounter per word per page. A single
  page yields many word encounters, so the page hash alone would collapse them into one. (Writing the
  constraint as `(user, text_hash)` was wrong; the ERD caught it.)
- **Kanji identity is the glyph.** Name the column `glyph`, not `character` — the latter is a
  reserved type name on Postgres and needs quoting.

### 6.2 Multi-user readiness

Multi-user is not planned, but adding it must not require a migration. Rules, all cheap now and
expensive later:

- Every table carries `user_id` from the first migration, even while exactly one user row exists.
- Every user-scoped unique constraint includes `user_id`: `(user_id, lexeme_id)`,
  `(user_id, glyph)`, `(user_id, source_id, text_hash)`. The lexical identity itself
  `(lemma, reading, POS)` is global and lives on `lexemes` (§6.3).
- No auth. A single default user is created on first boot, and the context layer populates `user_id`.
  That context layer is the only thing that changes when auth eventually arrives.
- Coverage, imports, and the review queue are per-user by construction, so per-user reporting needs
  no new code path.

**Identifiers are `int` — 4 bytes, auto-incrementing. Not UUIDs, and not bigint.**

UUIDs solve a problem this design does not have: merging rows between databases. That happens with
replication, offline clients syncing, or sharding. Here there is one writer and one database, and
export/import is a *document* (JSON keyed by `lemma + reading` and `glyph`), so surrogate ids never
travel. A v4 UUID is 16 bytes and random, so every insert lands at a random point in the B-tree rather
than appending — the worst pattern for the two append-only tables, `encounters` and `review_events`.

`bigint` is the usual insurance against a later `int` overflow, and here the insurance is not worth
buying. The ceiling is 2.1 billion rows. The heaviest table is `encounters`, and a genuinely heavy user
— 100 pages a day, 20 words a page, every day for a decade — lands at about 7.3 million, which is 0.3%
of the limit. Going `int` → `bigint` later is one `ALTER TABLE` plus a rewrite that takes seconds at
this scale, so the downside of being wrong is small and the saving is half the bytes in every index and
every join, forever.

**Right-sizing per table, for the record:**

| Table | Expected rows | Type |
|---|---|---|
| `kanji` | ≤ 13,000 (every CJK character that exists) | `int` |
| `lexemes` | ≤ 1 M (JMdict has ~200 k entries) | `int` |
| `users` | tens, even self-hosted for years | `int` |
| `words` | ~50 k–500 k | `int` |
| `pages` | thousands | `int` |
| `encounters`, `review_events` | ~7 M per decade of heavy use | `int` |
| `dict_cache_entries` | ≤ 200 k | `int` |

Nothing needs `bigint`. `smallint` would do for a position column, but there is none — see below.

**There is no `kanji` table and no `kanji_lexemes` table.** The kanji of a word are the CJK codepoints
already in its `lemma`, in order: 食べる contains 食, 一生懸命 contains 一 · 生 · 懸 · 命. Storing that
relation denormalises a value already held, and it is derived data — which P6 already forbids storing.

Two consequences worth stating:

- **It is more correct, not just tidier.** If the text shows たべる in kana, the reader has not seen 食.
  A projection of the lemma records exactly that. A relation built from the dictionary's kanji forms
  would credit characters never actually encountered.
- **Querying changes shape.** Filtering by one character is still a portable SQL filter —
  `WHERE lemma LIKE '%生%'` is exact for CJK, since a glyph is one character and cannot be a substring of
  another — but it is a scan rather than an index lookup. Aggregating *across* characters cannot stay in
  SQL portably: splitting a string into characters is `regexp_split_to_table` on Postgres and has no
  SQLite equivalent. So the kanji map is one query plus a grouping fold in Elixir, which at 50 k lexemes
  is a rounding error.

Costed and rejected along the way: a join table at 8 bytes per row (~480 KB with `int`), or the glyph
stored inline in that table (~420 KB), versus **zero** for deriving it. Deriving also removes a table, a
foreign key, and an entire class of drift — the same argument P6 makes about counters, applied to a
relation.

### 6.3 What is stored, what is fetched

Two levels, and the split is what keeps storage flat as users are added.

| Table | Scope | Holds |
|---|---|---|
| `lexemes` | **global, shared** | `lemma`, `reading`, `part_of_speech`. Unique on `(lemma, reading, POS)` |
| `words` | per user | `user_id`, `lexeme_id`, known / suspended / mastered flags |
| `dict_cache` | **global** | meanings, kanji readings, JLPT, frequency rank, components — keyed by `(kind, key, dict_version)` |
| `encounters`, `review_events`, `pages`, `sources` | per user | the ledger itself |

Readings are stored — on `lexemes`, **once per distinct word in the whole database, not once per
user** — for four reasons: they are half the identity key, so uniqueness cannot be enforced without
them; the tokenizer produced them anyway; card rendering must work while the dictionary service is
unavailable; and a dictionary update that changes a reading must not retroactively alter what the
ledger claims you studied.

**On the storage worry:** a heavy user might reach 50,000 distinct words over years. A lexeme row is
roughly 100 bytes of text, so the shared table stays in the low megabytes and is shared by every user.
The per-user marginal cost of a word is one small join row. Ten users add ten small rows per word, not
ten copies of the reading.

Meanings and kanji readings are **not** ledger fields, and are not per-user either — they are
dictionary-owned (P9) and live in `dict_cache`.

### 6.4 How the scheduling inputs interact

FSRS computes intervals from review grades alone. The counters never touch its internals — they decide
*what to study next*.

| Signal | Drives | Never does |
|---|---|---|
| FSRS grades | stability, difficulty, interval | — |
| `occurrences` (distinct pages) | introduction order (R3.9) | change stability, difficulty, or the interval |
| `distinct_sources` | confidence that the word is a real recurring item rather than one author's idiolect; ranking tiebreak | change the interval directly |
| `days_seen` | retention evidence outside FSRS; massed-exposure detection; "you can suspend this" prompts | change the interval directly |
| `failure_streak` | whether the next `due_at` is a remedial step (4h → 12h → 24h) or a ghost-mode step; reset by any pass | change stability or difficulty — those still come from FSRS alone |

**Massed exposure** = high `occurrences` with low `days_seen`. Crammed exposure, fragile memory.
Resurface these first. It is not a ghost and does not change scheduling.

A re-encounter (R3.6) is a genuine review event and *does* feed FSRS. That is the only place the
ledger changes scheduling, and it does so honestly — by supplying a new observation rather than by
faking an interval.

**Remedial steps and ghosts.** FSRS owns stability, difficulty, and the day-scale interval. A first
`again` schedules a 4-hour remedial step. A second consecutive `again` with no pass in between enters
ghost mode: 12 hours, then 24 hours, repeating 24 hours until a pass. A pass clears the failure streak
and returns the word to normal FSRS scheduling.

The FSRS state still updates on every review; remedial steps only override `due_at`.
`review_events.interval_after` records `0` for a remedial step because the step is not an FSRS
interval. FSRS applies its normal elapsed-day rule to the next review: 4h rounds same-day, while
12h and 24h count as one day.

### 6.5 Counting rules

Three systematically named numbers, so nobody has to guess which one a query means:

- **`tokens`** — raw count of the word in accepted text. Depth.
- **`occurrences`** — number of **distinct pages** containing the word, counted once per page. Breadth.
- **`days_seen`** — distinct calendar days on which the word was encountered.

Page identity is a hash of normalized page text, which gives three consequences:

- **The same screenshot uploaded twice counts once.** Re-uploading, or photographing a repeating
  dialogue box, creates no new encounter.
- **HUD and menu chrome is the massed-repetition case.** 「HP」「セーブ」「コマンド」 appear on nearly
  every screen of a game. A word appearing on more than a configurable fraction of a source's pages
  (default 50%) is *chrome-like in that source*. The word is flagged only when it is chrome-like in **every** source it
  appears in — otherwise a HUD word in one game would suppress real vocabulary met in a manga. The user
  can also ignore a line or a pattern explicitly.

  **What happens to a card that already exists when the flag lands** (R2.9): it is suspended with
  `suspended_reason = chrome`, never deleted. Review history survives, coverage still counts it, and
  clearing the flag un-suspends it — which is why the reason is stored rather than inferred.
- **Ranking uses `occurrences`, not `tokens`**, so one screen repeating a word ten times cannot
  promote it.

Worked example: a HUD word present on 200 screenshots of one game gives 200 `occurrences` and 200
`tokens` until it is flagged `chrome_like`. A dialogue word appearing twice on one screen and once on
another gives 2 `occurrences` and 3 `tokens`.

### 6.6 Formulas and thresholds

Everything below is a **v1 heuristic with configurable numbers.** None is sacred. Because review
history is an append-only log (§6.7), re-ranking after a parameter change is a pure recomputation, so
tuning costs nothing but time.

**Maturity**

```
mature(word)  ⇔  stability ≥ maturity_threshold      # default 21 days
```

Stability, not interval: stability is FSRS's own measure of memory strength, while the interval is a
scheduling choice.

**Massed exposure**

```
density = occurrences / max(days_seen, 1)
massed  ⇔  occurrences ≥ 5  AND  density ≥ 4
```

Five or more sightings crammed into one or two days is the signature of a word seen repeatedly in a
single session — memorised in the moment, gone in a week. Massed words are resurfaced first and never
trusted as known. This is a ranking/resurfacing signal, not ghost mode.

**Introduction priority (R3.9)**

```
priority = 3 × days_seen + occurrences
```

Ordered descending, after filtering out `chrome_like` words, words below `min_encounters`, and words
above the user's JLPT ceiling. `days_seen` carries triple weight because spaced encounter predicts
retention far better than repetition within one day.

**Re-encounter resurfacing (R3.6)**

```
if a new encounter arrives AND now < due_at - 7 days:
    schedule an early review (a real FSRS review event, not a fabricated interval)
```

The ledger never writes a fake interval. It supplies a new observation and lets FSRS decide.

### 6.7 Page revisions

`pages.revision` is a **fencing token, not a history**. It starts at 1 and is incremented inside the
same transaction as anything that changes what processing would produce:

- accepting a corrected text (R1.3)
- replacing the photo (R1.5)
- applying a rotation or perspective correction and re-running (R1.4)

Every job reads the revision at start and carries it. Writes are conditional:

```sql
UPDATE pages
   SET status = :status, accepted_text = :text
 WHERE id = :page_id AND revision = :started_at;   -- 0 rows ⇒ superseded
```

Zero rows affected means the page moved on while the job was working; the job discards its own result
and logs that it was superseded. That is optimistic concurrency control — no lock is held across the
multi-second OCR call, and a late result can never clobber a correction the user made in the meantime.
Borrowed directly from `jp-reader`'s `update_record_if_revision`.

### 6.8 Review history

Review history is an **append-only log**. Current state is derived from the latest event, and may be
materialised as a row for query speed, rebuildable from the log at any time.

The log is what makes these possible: re-running FSRS with newly optimised parameters over real
history, answering "why is this due in 200 days", and recomputing the queue when the
minimum-encounter threshold changes. A mutable state row destroys all three.

### 6.9 Enumerations and cache policy

**Enumerations are strings, constrained twice**: `Ecto.Enum` in the app and a `CHECK` constraint in the
migration, so anything else writing to the database is rejected too. Never a native Postgres `ENUM`:
SQLite has no equivalent and altering one is a migration hazard with no payoff. The enumerated columns
are `sources.kind`, `pages.status`, `pages.text_origin`, `pages.image_store`, `words.suspended_reason`,
`encounters.crop_store` and `dict_cache_entries.kind`.

`word_states.state` is an `Ecto.Enum` of atoms persisted as the integers 0–3 — `:new`, `:learning`,
`:review`, `:relearning` — so the column stays an integer and the app never handles bare numbers. The
migration's `state IN (0,1,2,3)` CHECK still guards it. `review_events.grade` is a genuine integer (1–4)
rather than an enum, because FSRS grades are numeric by definition.

**`dict_cache_entries` has no TTL and no refresh schedule.** JMdict is immutable between releases, so an
entry keyed by `dict_version` is either current or superseded wholesale — never stale. Refresh happens
one way: `jp-dict-api` reports a new `dict_version`, and the app re-fetches lazily on miss. A nightly job
re-downloading identical bytes would be pure waste. The only scheduled work worth having is a *check* for a new JMdict release, which flips a version
string and nothing else. That check is admin-configurable: on/off, and its interval (default weekly).

---

## 7. Integrations

**Implementation status.** Every service in this section is specified, not built. `jp-dict-api` and
`ashiato-ocr` do not exist yet. The Elixir side reaches them only through behaviours — `Ashiato.Tokenizer`,
`Ashiato.Dictionary`, `Ashiato.Ocr`, `Ashiato.Translator`, `Ashiato.Storage` — each with a fake, so no
test calls a real service. The rest of this section is the contract those behaviours must satisfy, not a
description of running code. See `docs/plan/wave-2.md`.

### 7.1 Dictionary — external HTTP service

The dictionary is **`jp-dict-api`, run as a separate service** (`JP_DICT_API_URL`).

Rationale: it is a large, rebuildable, *shared* dataset (JMdict + KANJIDIC2 + kradfile). Bundling it
into the app's own database would force every installation to rebuild or ship a few hundred MB of
reference data alongside a personal ledger. External, it can be versioned, replaced, and shared
independently.

Consequences, accepted knowingly:

- No cross-database joins. Word/kanji enrichment is fetch-then-merge in Elixir, batched per page.
- It is a runtime dependency. Lookups are cached locally (P9), and the app degrades — records
  encounters without enrichments — rather than failing when the service is down.

**`/tokenize` belongs here; `/ocr` does not.** Tokenization is lexical and needs the same dictionary
data, so it is a natural extension of this service. OCR is a vision workload with its own model,
runtime, and hardware requirements — see §7.3. Do not grow the dictionary service into an OCR host.

**Required addition for R3.10:** a nullable `jlpt` column on words, populated at build time by joining
a JLPT word list (tanos-derived) onto JMdict entries by kanji form, then kana form, keyed by JMdict
entry id.

### 7.2 Tokenizer — a Python endpoint

Tokenization is `POST /tokenize` on `jp-dict-api`, backed by SudachiPy. One call per page.

There is no Elixir implementation worth depending on; both candidates were checked:

- `mecab` on Hex — last release **June 2018**. Eight years unmaintained.
- `kiri` — a pure-Elixir Sudachi dictionary reader with POS and reading forms, but **v0.2.0, 319
  downloads all-time**, first released February 2026.

A Rust NIF (`sudachi.rs` via Rustler) would remove the hop entirely, but it buys nothing today: it is
one HTTP call per page, against a service that has to run regardless for the dictionary. Recorded as a
later option (§12), not a v1 dependency.

Contract: per token — surface form, lemma, reading in hiragana, POS. Output must be deterministic for
identical input, so it is cacheable by text hash.

**Measured behaviour** (SudachiPy, core dictionary, run against the cases that decide the schema):

| input | surface | lemma | reading | implication |
|---|---|---|---|---|
| たべる | たべる | **たべる** | タベル | kana is **not** converted to kanji |
| 食べた | 食べ | 食べる | タベ | inflection is normalised to the dictionary form |
| 食べる | 食べる | 食べる | タベル | same reading as たべる, different lemma |
| いけす | いけす | **いけす** | イケス | kana preserved |
| 生簀 | 生簀 | 生簀 | イケス | — |
| はし / 橋 / 箸 | as written | as written | ハシ | homophones stay **three** lexemes |

Four things follow, and each one changes a design decision:

- **Lemmas preserve orthography.** This is what makes deriving kanji from the lemma honest: たべる
  contributes no 食 because 食 was never on screen. Had the tokenizer normalised kana to kanji, the
  derivation would credit characters the reader never saw.
- **Inflection is normalised**, so 食べた, 食べます and 食べる collapse to one lexeme — the whole reason
  counting works at all.
- **Readings arrive in katakana** and must be converted to hiragana before they become part of the lexeme
  identity, or the same word would be minted twice.
- **A reading does not identify a word.** はし / 橋 / 箸 share ハシ and are three different words, which is
  why identity is `lemma + reading` rather than reading alone.

### 7.3 OCR

**Decision: classic PP-OCR, end to end** — a detector plus a recogniser, both from PaddleOCR, running as
a resident local service. With `lang="japan"` PaddleOCR resolves to **PP-OCRv6 `medium` det + rec**.
CPU only. No credentials, no per-image cost, no network.

The three stages:

1. **Detection (DB — Differentiable Binarization).** A segmentation model emits a shrunk "this is text"
   probability map; threshold it, extract contours, dilate back (unclip) to full line polygons. Output is
   one quadrilateral per text line — exactly what R2.6 and R3.2 need.
2. **Orientation (optional).** Four-way classifier for upside-down lines. Needed for photographs,
   skippable for screenshots.
3. **Recognition.** Each quad is perspective-warped to an axis-aligned strip, **resized to a fixed height
   (~48 px)**, and fed to a CRNN/SVTR sequence model, CTC-decoded to characters.

**Why this shape beats a vision LLM.** Step 3 is the whole argument: recognition sees *one line, upscaled
to a fixed height*, so a low-resolution frame still gives every glyph plenty of pixels. A VLM consumes
the whole image squeezed into a fixed patch budget — the opposite. Detection still needs enough
resolution to *find* line boundaries, but locating a line is far easier than reading a glyph.

**Evidence, one Japanese frame.** 1920×1080, ruby off, ground truth read at 4× zoom:

| Text | Truth | Chandra 4B | LFM-3 2B | PP-OCRv6-japan |
|---|---|---|---|---|
| speaker | ドーネイ | ドーンイ ❌ | ドーンイ ❌ | ドーネイ ✅ (0.99) |
| dialogue | 冷たいな！？ | ✅ | ✅ | ✅ |
| prompt | A はなす | ✅ | ✅ | はなす ✅ (missed the `A`) |
| button glyph | B | ❌ | ❌ | B ✅ |
| minimap | 0101 / 0008 | ❌ ❌ | ~ ✅ | ✅ ✅ (1.00) |
| noise | — | invented a line | fabricated menu labels | one spurious `-` |

PP-OCR won every disagreement, including the ネ/ン minimal pair both VLMs missed at full resolution.

**Evidence, 18 Japanese screenshots** (Nintendo JP guide + IGN Japan, 1280×720–1920×1080), CPU, 2 threads:

| Backend | Character errors | Speed |
|---|---|---|
| **PaddleOCR** — PP-OCRv6 `medium`, `lang=japan` | **~0** | ~7.6 s/image |
| RapidOCR — `japan_PP-OCRv4_rec_mobile` on ONNXRuntime | ~7 per text-heavy screen (~6% CER) | ~0.7 s/image |

One verified frame, RapidOCR: マップ→マツプ, アルバム→アルパム, チャレンジ→チャレソジ, だった→だつた,
ブルアパッド→プルアパツド, いると→しいると, 選ぶ→選ぷ. PaddleOCR read all seven correctly. Ten times
slower and correct is the right trade for a few pages a day.

**Two failure classes, and only one is fixable by better input.**

- **Systematic** — voicing and small-kana collapse (ッ→ツ, っ→つ, ブ→プ, ぶ→ぷ). Mostly harmless, because
  the misread word does not exist in the dictionary and P8 drops it.
- **Convergent minimal pairs** — both backends read ブルアパッド as プルアパッド; both VLMs read ネ as ン.
  Real glyph ambiguity, immune to model choice and to resolution. Only human confirmation (R2.8) catches
  these.

**Language match beats model size.** The Japanese recogniser run over an English screenshot set produced
lookalike errors — power→Dower, ravaged→Favaged, research→Yesearch — while the English recogniser read
the same lines correctly. The recogniser's character set must match the material.

**Runtime constraints — every one of these cost a debugging session.**

- **PaddlePaddle's CPU wheel requires AVX.** Without it the import dies with SIGILL (exit 132). More RAM
  does not help; only an AVX-capable vCPU does.
- **Paddle 3.x + oneDNN fails on every image** with `(Unimplemented) ConvertPirAttribute2RuntimeAttribute`.
  Both `enable_mkldnn=False` **and** `FLAGS_enable_pir_api=0` are required; miss either and nothing works.
- **`lang="japan"` resolves to PP-OCRv6 `medium`.** RapidOCR's model registry only has
  `japan_PP-OCRv4_rec_mobile`, which is measurably worse — the two runtimes are not shipping the same model.
- **No ROCm.** PaddlePaddle is CUDA-first, so CPU is the realistic path on AMD. It is adequate: the
  reference wrapper in this repo measured PaddleOCR oversubscribing threads badly (85 CPU-seconds for one
  page on 16 threads, 22 on one), hence its cap at 4.
- **Box format differs by runtime:** PaddleOCR returns flat `[x1,y1,x2,y2]`, RapidOCR returns N×2
  polygons. Normalise for both.
- **Boxes are normalised 0–1000**, because the backend contract says so. They are fractions of the frame,
  identical on a 400×225 and a 1920×1080 image. Convert with `x_px = x × width / 1000` and assert the
  range on ingest.
- **Expect format drift.** Providers ignore the requested labels and emit malformed attributes. Parse
  leniently, coerce, validate ranges, reject a corrupt block rather than accept it.

**Input requirements — these bind every backend and outweigh model choice.**

1. **Never downscale before OCR.** Send the native capture. A 400×225 thumbnail against a 1920×1080
   original is ~18× fewer pixels, and it was the single largest accuracy lever measured.
2. **Crop to the text region** — the dialogue box, not the whole frame — so each glyph occupies more
   pixels. Cheaper than any model upgrade.
3. **Turn ruby off in-game** (D22). Furigana sit between lines and read as stray glyphs, and the
   tokenizer supplies readings anyway (§7.2).

**Service shape.** `ashiato-ocr` is a **resident** process, not a per-image CLI: loading PP-OCRv6 medium
costs seconds, and the 18-image batch took 137 s *with a single model load*. Load once at boot, then
answer requests with `{"lines": [{"bbox": [x1,y1,x2,y2], "text": "...", "score": 0.98}]}` in the
normalised 0–1000 contract.

**Transport is a Unix domain socket, not HTTP** — not for speed (a socket round trip is sub-millisecond
against a 7.6 s call) but for simplicity: no published port, no bind address, no auth, nothing reachable
off-host. Erlang has first-class support: `:gen_tcp.connect({:local, path}, 0, [:binary, packet: 4])`,
with a 4-byte big-endian length prefix and one compact JSON object per frame.

**Requests carry a locator, never image bytes.** With the `local` image store the request carries the
shared-volume path; with `s3` the app presigns a GET and sends the URL. Base64 over the socket would
inflate every image by a third and hold it in memory twice.

**Deployment: pod `ashiato`, exactly two containers** — `ashiato-web` (Phoenix) and `ashiato-ocr`
(resident PaddleOCR) — sharing a volume for the socket and one for page images. The dictionary service is
**outside** the pod: it is shared, versioned, and has its own release cadence.

A pod shares network, pid and ipc namespaces, so the two sit together with no published port while each
keeps **its own cgroup and restart policy**. That is the point: this OCR path crashed twice during
development (SIGILL without AVX, then the oneDNN PIR failure), and an OCR OOM must not take the review UI
with it.

**Deployment mechanism: Quadlet** — `.pod` and `.container` units in `~/.config/containers/systemd/`,
materialised into systemd user units on `daemon-reload`. Quadlet ships inside the `podman` package here
(`/usr/lib/systemd/system-generators/podman-system-generator`); no extra package.

```text
~/.config/containers/systemd/
├── ashiato.pod                 PublishPort=4000:4000  (web only)
├── ashiato-web.container       Pod=ashiato.pod  Volume=ashiato-run:/run/ashiato
└── ashiato-ocr.container       Pod=ashiato.pod  Volume=ashiato-run:/run/ashiato
```

**Accuracy is measured by a fixture corpus**, not by retained production output: a small set of
screenshots with hand-checked transcriptions lives with the tests and every backend change runs against
it. That is why no `ocr_raw` column exists — a fixture has ground truth, and retaining per-page output
would store the same bytes twice on pages nobody corrected.

**Optional second backend (R1.10).** Any OpenAI-compatible vision endpoint can serve as a second opinion;
where the two backends agree the tokens are auto-accepted, and only disagreements require confirmation.
Hygiene for that path: strict transcription prompt, temperature 0, no commentary, every token
dictionary-validated (P8), crops retained. Agreement is a *confidence* signal, never a correctness one —
see the convergent-error class above.

**There is no OCR backend for Elixir**, and no binding for any of them, so this is a service rather than
an in-process call. This repository already contains a working PaddleOCR wrapper at
`reference/python-jp-reader/core/ocr.py` returning `rec_boxes` per line — the detector half can be lifted
rather than rewritten.

### 7.4 Ingest pipeline

The state a page moves through, in order. Stages after (5) run as background work and publish progress,
so the UI fills in as results arrive rather than blocking on the slowest step.

1. **Upload** — images, or PDFs. An image becomes one page record in `uploaded`. A PDF becomes one
   `documents` row plus one `pages` row per PDF page, sharing `document_id` and carrying `page_index`.
   If the PDF has a **text layer** the text is extracted directly, `text_origin = embedded`, and stages
   3–4 are skipped: no OCR, no character error. Only image-only PDFs are rasterised (200 DPI).
2. **Preprocess** — rotation and perspective correction, as needed
3. **Detect** — PP-OCR detector returns line quads; each line becomes a crop (R2.6)
4. **Recognise** — PP-OCR recogniser (default), per line crop; a VL model may run as a second
   opinion for the disagreement check (R1.10)
5. **Accept text** — raw output stored untouched; the accepted text is what the user may correct
   (R1.3) and what everything downstream uses
6. **Tokenise** — `Tokenizer` behaviour returns surface, lemma, reading, POS per token
7. **Validate** — drop tokens absent from the dictionary (P8); flag proper nouns; drop particles and
   auxiliaries (R2.1)
8. **Record** — write encounters for content words, once per page, deduping by page text hash; apply
   the `chrome_like` ratio (§6.5)
9. **Enrich** — meanings, kanji breakdown, JLPT, frequency rank, fetched from `jp-dict-api` in one
   batch per page and cached in `dict_cache`
10. **Translate** — optional, per line, on the AI path; each finished line is published so LiveView
    can render it immediately
11. **Ready** — page re-readable from the page list (R1.9) without re-photographing

Failure at any stage leaves the page in a failed state with the last good artifacts retained, and does
not roll back encounters already recorded.

**This pipeline follows `reference/python-jp-reader` deliberately.** That module already solved the
shape; its choices are worth copying rather than rediscovering:

- **Decode hygiene**: EXIF transpose, an 80-megapixel decompression-bomb cap, JPEG/PNG/WebP only, and a
  single normalised stored image that is *exactly* what OCR saw, so reported boxes line up with what the
  browser shows. One deviation: it downscales to `max_dim` first. We must not downscale text below
  legibility — set the cap high (≈3000 px long edge) instead of reusing a thumbnail size.
- **A monotonic `revision` per page.** A correction or re-photograph bumps it; a job that finishes late
  compares revisions and discards its own result rather than overwriting newer work.
- **Translation is its own job, after OCR.** Text is readable while translation runs, and a failed
  translation never loses the OCR result. Note what this means for us specifically: in `jp-reader`,
  tokenization is *not* a pipeline stage at all — it is computed on demand to render furigana for a
  phrase. In Ashiato it is a stage, because encounters are recorded from tokens. But tokenization and
  translation are **siblings, not a chain**: both depend only on `accepted_text`, so they run
  concurrently and neither waits for the other. Only OCR is a hard predecessor.
- **Translation cached by `(lang, text)`**, each line translated separately so it can be **painted over
  the line** on the page image. That overlay is the real reading aid (R1.11).
- **Furigana comes from the tokenizer**, never read off the image.
- **Per-line progress events**, published as each stage and each line completes.

### 7.5 Translation — a provider behaviour

Translation is one HTTP call, so it lives **in the Elixir app** using `Req`, not in a Python service.
There is no local model to host and no reason to pay for a boundary. Results are cached per line by
`(lang, line)` in the app's own database.

`jp-reader`'s chain is not the model to copy. It calls Google through `deep_translator`, which uses the
*free web endpoint* — no API key, which is exactly why it gets refused and why that module needs a
MyMemory fallback, a chunker for MyMemory's 500-character cap, and a 300-second circuit breaker. Fine
for a personal toy; a poor foundation for something shipped.

| Provider | Credentials | Japanese quality | Notes |
|---|---|---|---|
| `google_free` | **None** | Good | **Default.** The undocumented web endpoint the free widget uses. Works with zero setup, which is why it wins as a default |
| `llm` | OpenAI-compatible key or a local server | Best with page context | The only provider that can use surrounding lines, speaker, and register |
| `deepl` | DeepL API key (free tier exists) | Strongest on prose | Weakest on slang and casual game dialogue |
| `google_cloud` | Cloud Translation key (paid) | Same engine, supported contract | The official API — use this if you need reliability you can depend on |
| `libretranslate` | None; self-hosted URL | Weakest | Fully offline. Japanese is supported (ja↔en Argos models, ~112 MB) but it is a small NMT model |
| `off` | — | — | Disables translation entirely |

**Default provider is `google_free`**, because it is the only one that works on a fresh install with no
key, no URL, and no local server — and at single-user volume (a few hundred short lines a day) the free
endpoint is nowhere near its rate limits.

Three caveats that are not optional to state:

- **It is undocumented and outside Google's terms.** No key, no contract, no warning if it changes. It is
  the right default for a personal install and the wrong foundation for anything with users who depend on
  it — that is what `google_cloud` is for.
- **It can start refusing without notice.** The circuit breaker (§7.5, borrowed from `jp-reader`) is not
  decorative: a refused provider is skipped for a cool-down rather than retried per request, and an
  unconfigured fallback means translation silently degrades to "unavailable" instead of failing a page.
- **It sends your text to Google.** Game screenshots carry dialogue, and dialogue is personal. That is why
  the `translation_enabled` switch is **off by default** even though the provider is configured: nothing
  leaves the machine until you ask for it.

**Every provider is equally available and the user picks.** `google_free` is only the *initial* value, so a
fresh install has something working; it is not privileged. Selection, the enable switch, and each
provider's credentials are all editable in the app's Settings screen, and each provider shows whether it
is ready — "needs an API key", "needs a URL", "ready" — so a misconfiguration is visible before a page
fails.

Credentials entered in the UI are stored in `settings` with `secret = true`, encrypted at rest using a key
derived from `SECRET_KEY_BASE`, and never written to logs or error reports. Environment variables still
work as defaults for the same values, which keeps unattended container deploys possible without touching
the UI.

There is no `deep_translator` in Elixir, so `google_free` is a thin client of our own — the
`translate_a/single` endpoint, unwrapping a nested JSON array into plain strings. It returns
line-aligned text for input separated by newlines, so the page-batch contract (D44) works without the
JSON-array trick that only an LLM needs.

Capability, computed at boot alongside the AI gate:

```
translate_capable = translation_enabled AND provider_configured(translation_provider)
```

Where `provider_configured` means the key or URL that provider needs is present. No `translation_enabled`
switch means no translate affordance anywhere in the UI — hidden, not failing.

---

## 8. Configuration

| Setting | Default | Purpose |
|---|---|---|
| `ai_features_enabled` | `false` | The switch for mnemonics and example sentences. Does not imply credentials exist |
| `translation_enabled` | `false` | UI-editable. Off by default so nothing is sent off-host until opted in |
| `translation_provider` | `google_free` | UI-editable. `google_free`, `llm`, `deepl`, `google_cloud`, `libretranslate`, `off` |
| `deepl_api_key` | unset | Only read for the `deepl` provider |
| `google_cloud_api_key` | unset | Only read for the `google_cloud` provider |
| `libretranslate_url` | unset | Only read for the `libretranslate` provider; the key is optional (self-hosted) |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | Any OpenAI-compatible endpoint: llama.cpp, vLLM, proxy |
| `OPENAI_API_KEY` | unset | Credentials only. No default; empty means AI features are unavailable |
| `JP_DICT_API_URL` | — | Dictionary service |
| `tokenizer_provider` | `http` | `http` or `sudachi_nif` |
| `ocr_provider` | `paddleocr` | OCR recognition backend: classic PP-OCRv6 by default; `paddleocr_vl` is the optional second opinion (R1.10) |
| Min encounters — words | 2 | Queue-entry threshold (R3.4) |
| Min encounters — kanji | 2 | Discrimination-drill threshold (R3.7) |
| Remedial / ghost steps | 4h / 12h / 24h | First failure 4h, second consecutive 12h, third+ 24h repeating until a pass (R3.13) |
| Maturity threshold | 21 days (stability) | Defines *mature* for P3 |
| User JLPT level | unset | Gates new-card introduction (R3.10) |
| New cards per day | 10 | Introduction cap (R3.9) |
| Chrome page-ratio | 0.5 | Chrome flagging (§6.5) |
| Page image TTL | 30 days | R2.6 |
| Image store | `local` | `local` or `s3` |
| Image format | `jpeg` | Admin-configurable: `jpeg`, `webp`, `png`, `jxl` |
| Image quality | 90 | Admin-configurable; ignored by lossless formats |
| S3 endpoint / bucket / keys | unset | Read only when the image store is `s3` |
| JMdict release check | weekly | Admin-configurable on/off and interval |
| PDF raster DPI | 200 | Image-only PDFs; text layers are extracted instead |

---

## 9. Operations

- **OCR and translation run as background jobs**, not request-blocking. A page moves through
  states (uploaded → OCR → tokens recorded → enriched → translated) with progress published so the
  UI updates as each stage and each line completes.
- **Every index and constraint carries a comment in the migration** saying what it is for. A unique
  index is an assertion about the domain, and six months later nobody can tell
  `(user_id, word_id, text_hash)` from `(user_id, text_hash)` without one. The intent for each index is
  recorded on the tables in `docs/diagrams/erd.dbml`.
- **Database:** SQLite in development, Postgres in production. Migrations must run unchanged on both.
  Achieved by choosing the intersection type set, not the idiomatic per-dialect one: UUID primary keys
  generated client-side, `utc_datetime` timestamps, no `ALTER COLUMN TYPE`, no `ILIKE`, no full-text
  search in the core schema, no SQL views for derived data.
- **Portability is proven by running it:** the migration chain runs against both backends on every
  commit and the resulting schemas are diffed.

---

## 10. Decision log

| # | Decision | Rejected alternative | Why |
|---|---|---|---|
| D1 | Elixir + Phoenix | Python, Rust, JVM/Spring | Workload is I/O-bound fan-out. See ADR 0001. |
| D2 | Word is the review unit; kanji derived | Separate kanji SRS queue | Two schedulers over one piece of knowledge fight each other |
| D3 | Append-only review log | Mutable state row | Loses history, blocks parameter optimisation and audit |
| D4 | Dictionary as external HTTP service | Bundled `dict_*` tables in the ledger DB | Installation cost; reference data is large and shared |
| D5 | Word-level frequency counter | Kanji-level counter | Words are what is met and what carry readings |
| D6 | Per-line crop as card front | Text-only cards | Trains recognition in the source font; also the OCR audit trail |
| D7 | No interval caps by frequency band; FSRS owns the due date | Frequency-band interval caps | Caps override FSRS, increase workload, and double-count a signal the ledger already has: frequent words reappear in real reading |
| D8 | Re-encounter resurfacing | Random sampling of year-old cards | Uses a signal generic SRS apps do not have |
| D9 | Kanji discrimination = minimal pairs | Masked-glyph production card | Masking tests production; the reading, not vision, would disambiguate |
| D10 | Import as known baseline | Import SRS intervals | Foreign intervals and local FSRS parameters do not merge |
| D11 | `OPENAI_BASE_URL` | `OPENAI_API_BASE_URL` | Conventional name; SDKs and proxies expect it |
| D43 | AI capability = switch **and** non-empty key; base URL defaults to OpenAI | Treat the env vars as the switch | OCR no longer needs those credentials, so they are genuinely optional; an empty key must disable the feature rather than fail at call time |
| D44 | Translate the page in one request, asking for a JSON array; fall back to per-line | Per-line only, or jp-reader's numbered-prose batching | A sentence split across two OCR lines only translates correctly when the model sees the page; JSON survives round-trip far better than "1. 2. 3." prose |
| D45 | Translation is a provider behaviour, defaulting to `google_free` | Ship `off`, or default to a paid engine | It is the only provider that works on a fresh install with no key and no server; at single-user volume the rate limits are irrelevant. `translation_enabled` stays off so nothing leaves the host until asked |
| D46 | Translation lives in the Elixir app, not a Python service | Add it to the NLP service | It is one HTTP call with no local model, and the cache belongs in the ledger's database |
| D47 | Settings are a per-user key-value table; secrets encrypted with a key from `SECRET_KEY_BASE` | A column per setting, or credentials in env only | The schema is still moving and a settings UI would otherwise cost a migration per toggle; typed access stops the looseness at one boundary |
| D12 | Tokenizer is an HTTP endpoint on the dictionary service | Sudachi NIF via Rustler | Elixir tokenizer packages are dead (2018) or v0.2.0; one call per page makes the hop irrelevant |
| D13 | AI gated by an application setting | Gating on env vars | Env vars are credentials; a credential is not a preference |
| D14 | Classic PP-OCR end to end as default; VL model only as a second opinion | VLM-only OCR | PP-OCR recognises per line crop at fixed height, which survives low-res frames; VLMs squeeze the whole image |
| D15 | `occurrences` = distinct pages, chrome flagged | Raw token count | HUD text would otherwise dominate ranking |
| D16 | Store lemma/reading/POS, cache dictionary fields | Store everything in the ledger | Dictionary updates must not rewrite the ledger |
| D17 | Every table carries `user_id` from the start | Add it when multi-user arrives | One column now, a migration and a data backfill later |
| D18 | Shared `lexemes` table + per-user `words` | Store lemma/reading on every user's word row | Readings stored once globally; per-user cost is one join row |
| D19 | Maturity defined on FSRS **stability** | Interval ≥ 21 days (Anki's convention) | Stability is memory strength; interval is a scheduling choice. Maturity should not depend on scheduler policy |
| D20 | Pod `ashiato` = web + OCR; dictionary stays a separate service | All three in one pod, or one fat container | OCR is heavy and crashy and must be co-located; the dictionary is shared, versioned, and has its own release cadence |
| D21 | OCR behind a provider behaviour | Commit to one OCR backend | Accuracy on game UI text varies wildly; the backend must be swappable by config |
| D22 | Ruby off in-game when photographing | Keep furigana on for the camera | Ruby reads as stray glyphs to every backend; the tokenizer already supplies readings |
| D23 | Never downscale before OCR; crop to the text region | Hand the backend the full frame as-is | Resolution is a bigger accuracy lever than model choice; both test models failed on the same low-res input |
| D24 | Cross-model agreement as a confidence gate (R1.10) | Trust one strong model | Agreement catches divergent errors; it cannot catch convergent ones, so it complements rather than replaces confirmation |
| D25 | PaddleOCR (PP-OCRv6 medium) as default; RapidOCR as the AVX-less fallback | One runtime only | PaddleOCR was ~0 errors vs ~6% CER for RapidOCR's v4-mobile model — 10× slower and correct |
| D27 | `enable_mkldnn=False` + `FLAGS_enable_pir_api=0` | Paddle defaults | Paddle 3.x oneDNN fails every image with a PIR attribute error otherwise |
| D28 | All NLP/vision in Python services; the app stays Elixir | Python monolith | OCR and tokenization are Python-only, so a Python process exists either way; a monolith would also cost LiveView, Ecto and OTP supervision |
| D29 | Images in S3-compatible storage behind one behaviour | Filesystem paths | The app and the OCR service must not assume they share a filesystem |
| D30 | PDFs accepted; text layer extracted, else rasterised at 200 DPI | Images only | Text-layer PDFs skip OCR entirely and carry zero character error |
| D31 | Chrome flag requires the ratio in *every* source | Flag on the first source that trips it | A HUD word in one game must not suppress real vocabulary met elsewhere |
| D32 | Suspension records a reason | A bare boolean | Chrome, manual, leech and mastered must be reversible independently |
| D33 | Enums are strings, validated in app and by CHECK | Postgres native enums | SQLite has no equivalent; native enum migrations are a hazard |
| D34 | `dict_cache_entries` is version-keyed, no TTL | Time-based refresh | JMdict is immutable between releases |
| D35 | Adopt `jp-reader`'s pipeline shape | Design it again | It already solved ordering, staleness and failure isolation |
| D36 | Kanji membership is derived from `lemma`; no `kanji` and no `kanji_lexemes` table | Dimension table, or a glyph-carrying join table | The relation is a projection of data already stored; deriving it cannot drift, costs nothing, and credits only characters actually seen |
| D37 | Tokenization and translation run concurrently after OCR | Tokenize then translate as a chain | Both depend only on `accepted_text`; serialising them adds latency for nothing |
| D38 | Image format and quality are admin settings | Hard-coded encoder | Operators have opinions about storage cost and fidelity, and neither choice affects correctness |
| D39 | Drop the "re-OCR with another model" requirement | Keep it | Single-user app; making it useful would have required a separate OCR-runs table, and nobody would use it |
| D40 | Review cards rotate through their occurrences by `reps` | Always the first crop, or random | Rotation eventually shows every context; keying on `reps` keeps any given card reproducible |
| D41 | `int` primary keys everywhere | UUIDs, or `bigint` | UUIDs serve row-merging, which this does not do; the 2.1 B ceiling is 300× beyond a heavy decade, and `int`→`bigint` is one ALTER |
| D42 | No `ocr_raw` column | Keep model output for audit | A fixture corpus with ground truth measures OCR accuracy better; retaining per-page output stores the same bytes twice on pages nobody corrected |
| D26 | Recogniser language must match the material | One recogniser for everything | A mismatched character set produces confident lookalike errors (power→Dower) |
| D48 | Remedial steps 4h → 12h → 24h; ghost mode starts on the second consecutive `again` | Native FSRS interval immediately after the first lapse | Anki schedules a relearning step before FSRS resumes; ghost needs a second failure, not the first |

---

## 11. Known risks

| Risk | Mitigation |
|---|---|
| **LLM OCR hallucination** — plausible but wrong characters pass dictionary validation (待/持) | Raw output retained, crops retained, confirmation on first encounter, OCR-correction pairs feed discrimination sets |
| **Cold start** — empty ledger on day one | Accept and state plainly; it becomes useful in months. Anki/WaniKani seeding would have helped and is deferred |
| **Grammar is the real N4 bottleneck** — a frequency deck will not fix て-form or passive | Out of scope by design; pair with a separate grammar track |
| **Kana-only material** — no kanji, and mojibake in a ledger built on kanji | Detected and surfaced per page; such sources contribute vocabulary only |
| **Dictionary service unavailable** | Local cache; degrade to recording without enrichment |
| **SQLite/Postgres divergence** | Intersection types, no SQL views, dual-backend migration test in CI |
| **Target host cannot run the OCR runtime** — no AVX means no PaddlePaddle | Run PP-OCR through ONNXRuntime/RapidOCR, which has no AVX requirement; or place OCR on AVX-capable hardware |

---

## 12. Later / not now

- Anki and WaniKani progress import, from the deferred Epic 8
- Production cards (write a character from its reading) — deferred until handwriting is an actual goal
- Multi-user with per-user ledgers
- On-device OCR (removes the per-image cost and the privacy exposure)
- Grammar integration
- Confidence scoring on OCR output, propagated into how eagerly a word is trusted

---

## Appendix — diagrams

`docs/diagrams/` holds the sequence/flow diagrams and the entity-relationship diagram. To follow.
