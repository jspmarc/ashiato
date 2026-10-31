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
- Native mobile app (responsive web is sufficient)
- Handwriting practice / stroke-order grading (production cards are deferred; see R3.7)
- Audio, TTS, listening practice
- Grammar SRS (grammar is tracked as a separate concern, not in this app)
- Bunpro import (no official API; only an unstable reverse-engineered one)
- Anki export of review intervals (export is a known-words list only; see R8.2)

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
| **Content word** | Noun, verb, adjective, adverb. Not particles, auxiliaries, or punctuation |
| **Coverage** | Fraction of tokens in a text whose words are already known |
| **Page** | One processed image. Identity is a hash of its normalized text |
| **Tokens** | Raw count of a word in accepted text. Depth |
| **Occurrences** | Number of distinct pages containing a word, once per page. Breadth |
| **Lexeme** | A distinct lexical item — `lemma + reading + POS`. Global and shared, not owned by a user |
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
interval because interval is clamped by the frequency caps (R3.5), which would otherwise make maturity
depend on the cap. Derived from review history, never set by hand.
The second clause is the load-bearing one. A kanji known from a single word is word knowledge
wearing a character's costume.

**P4. Three counters, not one.**
`occurrences` (distinct pages containing the word — utility ranking), `distinct_sources` (context
diversity), `days_seen` (distinct calendar days). `days_seen` is the strongest retention signal;
spaced encounter beats massed encounter. Raw token depth is tracked separately as `tokens` (§6.5).

**P5. Recall sets the interval; frequency sets the ceiling.**
FSRS owns scheduling. Frequency caps how far an interval may stretch (R3.5). Letting appearance count
drive review frequency starves the deck — twenty top words would consume every slot forever.

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
| R3.2 | M | Card front = the line crop where the word was met, with the target word masked. Card back = word, reading, meaning, kanji. One card per word. |
| R3.3 | M | Grading updates FSRS state for that word. |
| R3.4 | M | A word is not introduced to the queue until it has been encountered at least N times, N configurable (default 2), with a force-add override. |
| R3.5 | M | Interval caps by frequency band: top band ≤ 60 days, next band ≤ 120 days, tail unbounded. |
| R3.6 | M | When a word is encountered in new material while its interval is long, resurface it immediately rather than waiting for its due date. |
| R3.7 | S | Opt-in kanji discrimination drill: minimal pairs (e.g. 待/持/時/特), multiple choice, back of card explains the distinguishing radical. Generated only for kanji with ≥2 encountered words. Minimum-encounter threshold configurable, force-add available. |
| R3.8 | M | Suspend a word indefinitely; suspend + mark mastered (excluded from queue, still counted in coverage). |
| R3.9 | M | New-card introduction ordered by priority (frequency within own material × novelty), capped per day. |
| R3.10 | S | Filter new-card introduction by JLPT level relative to the user's own level setting. |
| R3.11 | S | Flag and surface leeches: words met often but repeatedly failed. |

**Acceptance (R3.2):** grading a word card never advances a kanji card, and a kanji is never presented
as "what does this mean".

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
| R5.1 | M | Merge duplicate words produced by OCR or tokenizer variance. |
| R5.2 | M | Delete an encounter or an entire source; derived stats recompute. |
| R5.3 | S | Re-run OCR on a stored page with a different model, keeping the old result for comparison. |
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

OCR is *not* in this epic. It runs on locally hosted PaddleOCR-VL and needs no AI credentials (§7.3).

| ID | Pri | Requirement |
|---|---|---|
| R7.1 | S | Mnemonic generation for a word or kanji. Stored, cached, user-editable. Regenerating over an edit requires confirmation and keeps the previous version. Records which model and prompt version produced each. |
| R7.2 | S | Generate 1–3 example sentences per word. The prompt includes the user's own recorded meaning and the source sentence, so generated sentences match the sense actually learned. Validate the target word appears with the expected reading before displaying. |
| R7.3 | S | Passage and phrase translation. |

**Note:** the user's own encounters are the primary source of example sentences. Generated ones are
supplementary.

### Epic 8 — Imports

| ID | Pri | Requirement |
|---|---|---|
| R8.1 | S | Import Anki collection. The collection file is SQLite; read it directly. |
| R8.2 | S | Import WaniKani progress via API v2 with a personal token. |
| R8.3 | M | Imported progress is treated as a **known baseline**, not as review state. Merging foreign intervals with local FSRS parameters produces nonsense. |

**Out of scope:** Bunpro. No official API exists; only a permissioned reverse-engineered one that is
explicitly unstable.

---

## 6. Data semantics

### 6.1 Identity rules

- **A word is `lemma + reading`, and that pair belongs to a lexeme.** Same spelling with a different
  reading is a different word (生物 せいぶつ vs なまもの). `reading` is non-null with a `""` default so
  the unique constraint actually bites — multiple NULLs pass a unique index on both SQLite and
  Postgres. Uniqueness is `(lemma, reading, part_of_speech)` on the **shared** `lexemes` table, not per
  user; see §6.3.
- **Page identity is a hash of its normalized text**, unique per user. Re-uploading the same screen
  creates nothing new.
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
*what to study next* and *how far an interval may stretch*.

| Signal | Drives | Never does |
|---|---|---|
| FSRS grades | stability, difficulty, interval | — |
| `occurrences` (distinct pages) | introduction order (R3.9); the frequency band that caps the interval (R3.5) | change stability or difficulty |
| `distinct_sources` | confidence that the word is a real recurring item rather than one author's idiolect; ranking tiebreak | change the interval directly |
| `days_seen` | retention evidence outside FSRS; ghost detection; "you can suspend this" prompts | change the interval directly |

Two derived rules:

- `final_interval = min(fsrs_interval, cap_for_band(occurrences))`
- **Ghost** = high `occurrences` with low `days_seen`. Massed exposure, fragile memory. Resurface
  these first.

A re-encounter (R3.6) is a genuine review event and *does* feed FSRS. That is the only place the
ledger changes scheduling, and it does so honestly — by supplying a new observation rather than by
faking an interval.

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
  (default 50%) is flagged `chrome_like` and excluded from ranking and introduction by default. The
  user can also ignore a line or a pattern explicitly.
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

Stability, not interval: interval is clamped by the band caps below, and an interval-based definition
would make maturity depend on the cap — with a cap set below the threshold, no word could ever mature.
Stability is FSRS's own measure of memory strength and is unaffected by the clamp.

**Frequency bands and interval caps (R3.5)**

| Band | `occurrences` | Cap |
|---|---|---|
| 0 | ≥ 20 | 60 days |
| 1 | 8–19 | 120 days |
| 2 | 3–7 | 240 days |
| 3 | ≤ 2 | none |

```
final_interval = min( fsrs_interval, cap_for_band(occurrences) )
```

The cap only bites on words FSRS wants to schedule far out — i.e. ones you keep getting right. That is
intentional: high-utility words should be re-proved occasionally, not retired.

**Ghost (massed exposure)**

```
density = occurrences / max(days_seen, 1)
ghost   ⇔  occurrences ≥ 5  AND  density ≥ 4
```

Five or more sightings crammed into one or two days is the signature of a word seen repeatedly in a
single session — memorised in the moment, gone in a week. Ghosts are resurfaced first and never
trusted as known.

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

### 6.7 Review history

Review history is an **append-only log**. Current state is derived from the latest event, and may be
materialised as a row for query speed, rebuildable from the log at any time.

The log is what makes these possible: re-running FSRS with newly optimised parameters over real
history, answering "why is this due in 200 days", and recomputing the queue when the
minimum-encounter threshold changes. A mutable state row destroys all three.

---

## 7. Integrations

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

### 7.3 OCR

**Default: classic PP-OCR, end to end.** Three small networks in sequence, all running locally:

1. **Detection (DB — Differentiable Binarization).** A segmentation model emits a shrunk
   "this-is-text" probability map; threshold it, extract contours, then dilate back (unclip) to recover
   full line polygons. Output: one quadrilateral per text line, which is exactly what R2.6 and R3.2 need.
2. **Orientation (optional).** A four-way classifier for upside-down lines. Needed for photographs,
   skippable for screenshots.
3. **Recognition.** Each quadrilateral is perspective-warped to an axis-aligned strip, **resized to a
   fixed height (~48 px)**, and fed to a CRNN/SVTR sequence model, CTC-decoded into characters.

Step 3 is the reason this is the default rather than a VL model. **Recognition runs on a crop, upscaled
to a fixed height, so a low-resolution frame still gives every glyph plenty of pixels.** A VLM does the
opposite: it consumes the whole image, squeezed into a fixed patch/token budget. That is a structural
advantage, not a benchmark delta — and it is precisely the failure the sample exposed.

Detection still needs enough resolution to *find* line boundaries, but locating a line is far easier
than reading a glyph.

The VL model is demoted to a **second opinion** for the disagreement check in R1.10, where it is useful
because its failure modes differ from PP-OCR's.

**Size and runtime.** Mobile detector and recogniser are single-digit to low-tens of megabytes; server
variants an order of magnitude larger. PaddlePaddle is CUDA-first — ROCm support is not something to
plan on for a 7800-class card, so **CPU is the realistic path**, and it is adequate: the reference
wrapper in this repo records that PaddleOCR oversubscribes threads badly (85 CPU-seconds for one page
on 16 threads, 22 on one), hence its hard cap at 4.

**It runs locally.** Model files are loaded into the Python process. No network, no credentials, no
per-image cost, after the one-time model download.

**What PP-OCR actually is.** PaddleOCR's classic two-stage pipeline: a **detector** (a DB —
Differentiable Binarization — model) that finds text-line quads, and a **recogniser** (SVTR-based) that
reads each cropped line. It is a Python/PaddlePaddle library.

**Evaluated: Chandra OCR 2** (Datalab) — a 4B-parameter model, 90+ languages including Japanese,
emitting HTML/Markdown/JSON with `data-bbox` per element. Tested on one real TotK dialogue screenshot
(400×225, ruby enabled), which settles the granularity question and raises a different one.

*Granularity: solved.* It returns **one bbox per text line**, which is exactly what R2.6 and R3.2 need.
PP-OCR detection would not be required if Chandra were the backend.

*Accuracy: not good enough for a ledger.* As best readable from the sample:

| Chandra output | What is actually there |
|---|---|
| ヤンバ | インパ |
| セップクじゅう | せっかくじゃ |
| 何方も一緒に海上を走りに行ってみか | 貴方も一緒に地上を飛びに行くが |
| ちよっく待って | ちょっと待って |
| 盗み攻撃を受けました | nothing — no such line in the image |
| 奥にが | 見に行く |

貴方→何方 and 地上→海上 are the worst kind: **plausible real words**, so dictionary validation (P8)
cannot catch them, and they would enter the ledger silently. One entire line was invented.

*Three findings from that sample:*

- **Ruby is OCR noise.** Furigana sit between text lines and read as stray glyphs — せっかくじゃ came
  back as katakana セップクじゅう, which looks like the model reading the ruby column. Since the
  tokenizer supplies readings anyway (§7.2), **ruby should be turned off in-game when photographing**.
  It helps a human reading raw; it hurts every OCR backend.
- **Boxes are normalised 0–1000, by contract, because the prompt asks for it.** Values read x≈940,
  y≈951 on both a 400×225 and a 1920×1080 frame because they are *fractions of the frame*, not pixels.
  This is a good backend contract — resolution-independent and identical across providers. Convert with
  `x_px = x × width / 1000`, `y_px = y × height / 1000`, and assert the range on ingest.
- **4B wants a GPU.** PaddleOCR-VL (0.9B) runs acceptably on CPU; 4B does not. Fine on a 16 GB card,
  a barrier for anyone else installing the app.

**Do not choose the default from one sample.** Run PaddleOCR-VL and Chandra over the same batch of ~10
real screenshots and count errors, weighting plausible-substitution errors as worse than garbage.

**Input requirements — these bind every backend, and matter more than model choice.**

Measured on the sample above, plus a second run with a 2B vision model on the same file:

| Backend | Result |
|---|---|
| Chandra OCR 2 (4B) | structure right, ~6 line-level errors, 1 invented line |
| LFM-3 2B VL | fabricated menu labels that do not exist, invented a dialogue line |

Both models independently produced **the same wrong token** for せっかくじゃ (セップクじゅう / セツクじゅう).
When two unrelated models converge on the same error, the fault is in the **input**, not the model: the
pixels do not resolve the glyphs. That is the resolution-and-ruby problem, and no amount of model
upgrade fixes it.

**Re-run at 1920×1080 (different screenshot, same game).** Both backends improved dramatically:

| Text | Chandra 4B | LFM 2B |
|---|---|---|
| 冷たいな！？ (dialogue) | ✅ | ✅ |
| A はなす (button prompt) | ✅ | ✅ |
| AM 10:50 (clock) | ✅ | ✅ |
| 0101 / 0008 (minimap numerals) | ❌ missed | ✅ |
| ドーネイ (speaker name) | ❌ ドーンイ | ❌ ドーンイ |

Two conclusions, one of which reverses an earlier claim:

1. **Resolution was the dominant variable, not model size.** At 400×225 both produced garbage; at
   1920×1080 both got the dialogue, the prompt, and the clock right. The earlier conclusion that a 2B
   model is categorically too weak does not survive this sample — it caught *more* than the 4B here.
   Do not select a backend on parameter count.
2. **Minimal-pair confusions survive resolution.** ネ read as ン in both models, at full resolution.
   Those two kana differ by a couple of internal strokes at UI font sizes, so no resolution gain
   separates them. This is the same class as 未/末 and 待/持 — and it is exactly what the confirmation
   flag (R2.8) exists for. Better input fixes systematic errors; only human confirmation fixes
   minimal-pair errors.

**Expect format drift.** Both models ignored `data-label="Text"` and repeated the text in the label, and
Chandra emitted malformed attributes (`data-bbox="[641,311,695,334]` — array brackets, no closing
quote). Treat the output as untrusted: parse leniently, coerce types, validate ranges, and reject a
block rather than accepting a corrupt one.

**How much text is actually there.** A full 1920×1080 game frame yielded 4–6 text blocks; the rest of
the HUD is icons. Chrome contamination is therefore smaller than feared — but minimap numerals are real
chrome text, and they are dropped downstream as non-content tokens.

Rules that follow:

1. **Never downscale before OCR.** Send the native capture. The bounding-box extents in the sample are
   consistent with a ~1691×951 native frame; a 400×225 thumbnail is roughly **18× fewer pixels**. This
   is the single largest accuracy lever available, larger than the choice of model.
2. **Crop to the text region** — the dialogue box, not the whole frame — so each glyph occupies more
   pixels. Cheaper than any model upgrade.
3. **Turn ruby off in-game** (D22). Furigana sit between lines and read as stray glyphs.
4. **Never assume source-pixel coordinates** for returned boxes (above).

**Measured: three backends, one Japanese frame.** 1920×1080 TotK screenshot, ruby off, ground truth
read at 4× zoom.

| Text | Truth | Chandra 4B | LFM-3 2B | PP-OCRv4-japan |
|---|---|---|---|---|
| speaker | ドーネイ | ドーンイ ❌ | ドーンイ ❌ | ドーネイ ✅ (0.99) |
| dialogue | 冷たいな！？ | ✅ | ✅ | ✅ |
| prompt | A はなす | ✅ | ✅ | はなす ✅ (missed the A glyph) |
| button glyph | B | ❌ | ❌ | B ✅ |
| minimap | 0101 / 0008 | ❌ ❌ | ~ ✅ | ✅ ✅ (1.00) |
| noise | — | invented a line | fabricated menu labels | one spurious "-" |

PP-OCR won every disagreement, including the ネ/ン minimal pair both VLMs missed at full resolution.
The fixed-height-crop argument holds empirically, not just theoretically.

**Measured on 18 Japanese screenshots** (Nintendo JP guide + IGN Japan, 1280×720 to 1920×1080),
CPU only, 2 threads:

| Backend | Character errors | Speed |
|---|---|---|
| **PaddleOCR** — PP-OCRv6 `medium` det+rec, `lang=japan` | **~0** | ~7.6 s/image |
| RapidOCR — `japan_PP-OCRv4_rec_mobile` on ONNXRuntime | ~7 per text-heavy screen (~6% CER) | ~0.7 s/image |

On one verified frame RapidOCR misread マップ→マツプ, アルバム→アルパム, チャレンジ→チャレソジ,
だった→だつた, ブルアパッド→プルアパツド, いると→しいると, 選ぶ→選ぷ. PaddleOCR read all seven
correctly. Ten times slower, and correct — the right trade for a few pages a day.

Its error classes, both now measurable, are the ones the confirmation flag exists for:

- **Voicing and small-kana collapse** — ッ→ツ, っ→つ, ブ→プ, ぶ→ぷ. Mostly caught downstream because
  the misread word does not exist in the dictionary (P8).
- **Convergent item names** — both backends read ブルアパッド as プルアパッド. Real glyph ambiguity,
  immune to model choice, caught only by confirmation (R2.8).

**Runtime findings that constrain deployment:**

- **Paddle 3.x + oneDNN fails on every image** with `(Unimplemented)
  ConvertPirAttribute2RuntimeAttribute …`. Both `enable_mkldnn=False` **and**
  `FLAGS_enable_pir_api=0` are required. Miss either and every image errors out.
- **PaddlePaddle's CPU wheel needs AVX.** It SIGILLs on a vCPU without it — observed here on
  `QEMU Virtual CPU version 2.5+`, exit 132. RAM is irrelevant; only an AVX-capable vCPU fixes it.
  The host now runs with CPU type `host` (Ryzen 5 8600G, AVX-512).
- **`lang="japan"` resolves to PP-OCRv6 `medium` det+rec** in PaddleOCR proper. RapidOCR's registry
  has only `japan_PP-OCRv4_rec_mobile`, which is measurably worse. The two are not the same model.
- **Box format differs by runtime:** PaddleOCR returns flat `[x1,y1,x2,y2]`, RapidOCR returns N×2
  polygons. Normalise for both.
- Ruby fragments are transcribed as their own lines by both — the empirical basis for D22.

**Language match beats model size.** Running the Japanese recogniser over an English screenshot set
produced lookalike errors — power→Dower, ravaged→Favaged, research→Yesearch, Invert→Thvert — while the
English recogniser read the same lines correctly. The failure surface is the same minimal-pair class as
ネ/ン, so the rule generalises: **the recogniser's character set must match the material.**

**OCR is a long-lived service, not a per-image CLI.** The models are the expensive part: loading
PP-OCRv6 medium takes seconds, and a per-image subprocess would pay that on every page. The 18-image
batch above took 137 s *with a single model load* — per-image invocation would multiply that.

So `ashiato-ocr` is a small resident process: load once at boot, then answer requests with
`{"lines": [{"bbox": [x1,y1,x2,y2], "text": "...", "score": 0.98}]}` in the normalised 0–1000 contract.

**Transport: a Unix domain socket, not HTTP.** Not for speed — a socket round trip is sub-millisecond
against a 7.6-second OCR call, so the transport choice is irrelevant to performance. It is chosen
because it is *simpler*: no port to publish, no bind address, no auth, nothing reachable from off the
host, and Erlang has first-class support for it — `:gen_tcp.connect({:local, path}, 0, [:binary, packet: 4])`.
Framing is a 4-byte big-endian length prefix on both sides; JSON is one compact object per frame.

**Requests carry a path, not image bytes.** The containers share a volume for uploaded images, so the
request is `{"op":"ocr","path":"/var/ashiato/pages/abc.png"}`. Base64 over a socket would inflate every
image by a third and hold it in memory twice.

**Deployment shape: pod `ashiato`, exactly two containers** — `ashiato-web` (Phoenix) and
`ashiato-ocr` (resident PaddleOCR) — sharing a volume for the Unix socket and one for page images.

**The dictionary service is deliberately outside the pod.** It is a shared, versioned data service:
different release cadence, different data volume, and eventually possibly a different host (it exists so
that installs share one copy of JMdict rather than rebuilding it). The web container reaches it over
HTTP. Co-locating it would couple two things that have no reason to share a lifecycle.

A pod shares network, pid and ipc namespaces, so web and OCR sit together with no published port, while
each keeps **its own cgroup and restart policy**. That distinction is the whole point: OCR crashed twice
during development (SIGILL on a non-AVX vCPU, then the oneDNN PIR failure), and an OCR OOM must not
take the review UI with it. A single container running both would work, at the cost of a shared cgroup
and a ~3–4 GB image where every Elixir change rebuilds behind the Python layer.

**Deployment mechanism: Quadlet.** `.pod` and `.container` unit files in
`~/.config/containers/systemd/`, which systemd materialises into user units on `daemon-reload`. Quadlet
5.4.2 ships inside the `podman` package on this host already — the generator is
`/usr/lib/systemd/system-generators/podman-system-generator`. No extra package is needed.

```text
~/.config/containers/systemd/
├── ashiato.pod                 PublishPort=4000:4000  (web only)
├── ashiato-web.container       Pod=ashiato.pod  Volume=ashiato-run:/run/ashiato
└── ashiato-ocr.container       Pod=ashiato.pod  Volume=ashiato-run:/run/ashiato
```

`jp-dict-api` gets its own unit, on its own schedule, wherever it ends up living.

**No OCR backend is available for Elixir**, and no binding exists for any of them. For this app it is therefore a **service or
a Port**, never an in-process call — exactly like the dictionary. The good news: this repository
already contains a working wrapper in `reference/python-jp-reader/core/ocr.py`, which returns
`rec_boxes` per line. That is the detector half this design needs; it can be lifted rather than
rewritten.

Alternative: an OpenAI-compatible vision endpoint, on the optional AI path. Hygiene rules apply to
either recognition backend:

- strict transcription prompt, temperature 0, no commentary
- raw output stored separately from accepted text; never overwritten
- every token dictionary-validated (P8)
- crops retained as the audit trail

### 7.4 Ingest pipeline

The state a page moves through, in order. Stages after (5) run as background work and publish progress,
so the UI fills in as results arrive rather than blocking on the slowest step.

1. **Upload** — one or more images; each becomes a page record in `uploaded`
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

---

## 8. Configuration

| Setting | Default | Purpose |
|---|---|---|
| `ai_features_enabled` | **false** | The switch for Epic 7. Not implied by credentials |
| `OPENAI_BASE_URL` / `OPENAI_API_KEY` | unset | Credentials; required for AI features to work once enabled |
| `JP_DICT_API_URL` | — | Dictionary service |
| `tokenizer_provider` | `http` | `http` or `sudachi_nif` |
| `ocr_provider` | `paddleocr_vl` | OCR recognition backend |
| Min encounters — words | 2 | Queue-entry threshold (R3.4) |
| Min encounters — kanji | 2 | Discrimination-drill threshold (R3.7) |
| Maturity threshold | 21 days (stability) | Defines *mature* for P3 |
| Band caps | 60 / 120 / 240 / none | Occurrence bands ≥20 / 8–19 / 3–7 / ≤2 (§6.6) |
| User JLPT level | unset | Gates new-card introduction (R3.10) |
| New cards per day | 10 | Introduction cap (R3.9) |
| Frequency cap — top band | 60 days | R3.5 |
| Frequency cap — second band | 120 days | R3.5 |
| Chrome page-ratio | 0.5 | Chrome flagging (§6.5) |
| Page image TTL | 30 days | R2.6 |

---

## 9. Operations

- **OCR and translation run as background jobs**, not request-blocking. A page moves through
  states (uploaded → OCR → tokens recorded → enriched → translated) with progress published so the
  UI updates as each stage and each line completes.
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
| D7 | Interval caps by frequency band | Frequency-driven review frequency | Caps encode the intuition without starving the queue |
| D8 | Re-encounter resurfacing | Random sampling of year-old cards | Uses a signal generic SRS apps do not have |
| D9 | Kanji discrimination = minimal pairs | Masked-glyph production card | Masking tests production; the reading, not vision, would disambiguate |
| D10 | Import as known baseline | Import SRS intervals | Foreign intervals and local FSRS parameters do not merge |
| D11 | `OPENAI_BASE_URL` | `OPENAI_API_BASE_URL` | Conventional name; SDKs and proxies expect it |
| D12 | Tokenizer is an HTTP endpoint on the dictionary service | Sudachi NIF via Rustler | Elixir tokenizer packages are dead (2018) or v0.2.0; one call per page makes the hop irrelevant |
| D13 | AI gated by an application setting | Gating on env vars | Env vars are credentials; a credential is not a preference |
| D14 | Classic PP-OCR end to end as default; VL model only as a second opinion | VLM-only OCR | PP-OCR recognises per line crop at fixed height, which survives low-res frames; VLMs squeeze the whole image |
| D15 | `occurrences` = distinct pages, chrome flagged | Raw token count | HUD text would otherwise dominate ranking |
| D16 | Store lemma/reading/POS, cache dictionary fields | Store everything in the ledger | Dictionary updates must not rewrite the ledger |
| D17 | Every table carries `user_id` from the start | Add it when multi-user arrives | One column now, a migration and a data backfill later |
| D18 | Shared `lexemes` table + per-user `words` | Store lemma/reading on every user's word row | Readings stored once globally; per-user cost is one join row |
| D19 | Maturity defined on FSRS **stability** | Interval ≥ 21 days (Anki's convention) | Interval is clamped by the frequency caps, so maturity would depend on the cap |
| D20 | Pod `ashiato` = web + OCR; dictionary stays a separate service | All three in one pod, or one fat container | OCR is heavy and crashy and must be co-located; the dictionary is shared, versioned, and has its own release cadence |
| D21 | OCR behind a provider behaviour | Commit to one OCR backend | Accuracy on game UI text varies wildly; the backend must be swappable by config |
| D22 | Ruby off in-game when photographing | Keep furigana on for the camera | Ruby reads as stray glyphs to every backend; the tokenizer already supplies readings |
| D23 | Never downscale before OCR; crop to the text region | Hand the backend the full frame as-is | Resolution is a bigger accuracy lever than model choice; both test models failed on the same low-res input |
| D24 | Cross-model agreement as a confidence gate (R1.10) | Trust one strong model | Agreement catches divergent errors; it cannot catch convergent ones, so it complements rather than replaces confirmation |
| D25 | PaddleOCR (PP-OCRv6 medium) as default; RapidOCR as the AVX-less fallback | One runtime only | PaddleOCR was ~0 errors vs ~6% CER for RapidOCR's v4-mobile model — 10× slower and correct |
| D27 | `enable_mkldnn=False` + `FLAGS_enable_pir_api=0` | Paddle defaults | Paddle 3.x oneDNN fails every image with a PIR attribute error otherwise |
| D28 | All NLP/vision in Python services; the app stays Elixir | Python monolith | OCR and tokenization are Python-only, so a Python process exists either way; a monolith would also cost LiveView, Ecto and OTP supervision |
| D26 | Recogniser language must match the material | One recogniser for everything | A mismatched character set produces confident lookalike errors (power→Dower) |

---

## 11. Known risks

| Risk | Mitigation |
|---|---|
| **LLM OCR hallucination** — plausible but wrong characters pass dictionary validation (待/持) | Raw output retained, crops retained, confirmation on first encounter, OCR-correction pairs feed discrimination sets |
| **Cold start** — empty ledger on day one | Accept and state plainly; imports (E8) give a baseline |
| **Grammar is the real N4 bottleneck** — a frequency deck will not fix て-form or passive | Out of scope by design; pair with a separate grammar track |
| **Kana-only material** — no kanji, and mojibake in a ledger built on kanji | Detected and surfaced per page; such sources contribute vocabulary only |
| **Dictionary service unavailable** | Local cache; degrade to recording without enrichment |
| **SQLite/Postgres divergence** | Intersection types, no SQL views, dual-backend migration test in CI |
| **Target host cannot run the OCR runtime** — no AVX means no PaddlePaddle | Run PP-OCR through ONNXRuntime/RapidOCR, which has no AVX requirement; or place OCR on AVX-capable hardware |

---

## 12. Later / not now

- Production cards (write a character from its reading) — deferred until handwriting is an actual goal
- Multi-user with per-user ledgers
- On-device OCR (removes the per-image cost and the privacy exposure)
- Grammar integration
- Confidence scoring on OCR output, propagated into how eagerly a word is trusted

---

## Appendix — diagrams

`docs/diagrams/` holds the sequence/flow diagrams and the entity-relationship diagram. To follow.
