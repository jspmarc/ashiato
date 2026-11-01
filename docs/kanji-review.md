# Kanji review: pseudocode and queries

How the derived kanji state and the discrimination drill are actually computed. Everything here runs
over three tables — `lexemes`, `words`, `encounters` — plus `word_states` for maturity. There is no kanji
table: a character's membership is derived from `lemma` (§6.2 of the requirements).
No kanji state table exists, because none is needed — these are all queries.

SQL is written to run unchanged on SQLite and Postgres: `MAX(CASE …)` instead of `BOOL_OR`, no
`ILIKE`, no `RETURNING`, no window functions in the hot path.

---

## Why these queries look the way they do

A word's kanji are the CJK codepoints in its `lemma`, so there is no kanji table to join — only two hops:
`words` (your copy of a lexeme) and `encounters` (the evidence), with a `LIKE` on the lemma when a
specific character is wanted.

`WHERE lemma LIKE '%生%'` is exact for CJK, because a glyph is one character and cannot be a substring of
another. It is a scan rather than an index lookup, which is fine at this scale and is the price of
portability: an index on a derived column would not survive the move from SQLite to Postgres.

Aggregating *across* characters is the one question SQL cannot answer portably — splitting a string into
characters is `regexp_split_to_table` on Postgres and has no SQLite equivalent — so the kanji map is one
query plus a fold in Elixir.

**A document store would not remove the work, it would move it.** These answers are set aggregations over
a many-to-many relation, which is the one thing document databases are weakest at. You would either embed
the kanji inside documents and aggregate in application code over a whole collection, or keep a
denormalised `kanji_stats` document — a stored counter, and P6 exists precisely because stored counters
drift the first time a batch is imported twice. Two further requirements would break outright: the
uniqueness invariants (`(user, text_hash)`, `(user, word_id, text_hash)`) are multi-row assertions
document stores do not enforce well, and the SQLite-dev/Postgres-prod requirement has no document
equivalent.

And the pragmatic point: these are **six Ecto functions in one module**, written once and tested.

---

## 1. The words you have met that contain a character

The core query; everything else is built on it.

```sql
-- :glyph_like = '%生%', :user_id = current user
SELECT l.id            AS lexeme_id,
       l.lemma,
       l.reading,
       l.part_of_speech,
       COUNT(DISTINCT e.page_id)  AS occurrences,   -- breadth
       COUNT(DISTINCT e.seen_on)  AS days_seen,     -- spacing
       MIN(e.seen_on)             AS first_seen,
       MAX(e.seen_on)             AS last_seen
FROM lexemes l
JOIN words w ON w.lexeme_id = l.id AND w.user_id = :user_id
JOIN encounters e ON e.word_id = w.id
                AND e.confirmed = 1          -- R2.8: unconfirmed counts toward nothing
                AND e.discarded_at IS NULL
WHERE l.lemma LIKE :glyph_like
GROUP BY l.id, l.lemma, l.reading, l.part_of_speech
ORDER BY occurrences DESC, days_seen DESC;
```

`occurrences` counts distinct pages, not tokens, so one screen repeating a word ten times cannot promote
it (§6.5).

---

## 2. Is this kanji "known"?

P3: at least one mature word containing it **and** it appears in at least two distinct words.

```sql
SELECT :glyph                                        AS glyph,
       COUNT(DISTINCT l.id)                          AS distinct_words,
       MAX(CASE WHEN ws.stability >= :maturity_days
                THEN 1 ELSE 0 END)                   AS has_mature_word,
       CASE WHEN COUNT(DISTINCT l.id) >= 2
             AND MAX(CASE WHEN ws.stability >= :maturity_days
                          THEN 1 ELSE 0 END) = 1
            THEN 1 ELSE 0 END                        AS kanji_known
FROM lexemes l
JOIN words w ON w.lexeme_id = l.id AND w.user_id = :user_id
JOIN encounters e ON e.word_id = w.id
                AND e.confirmed = 1
                AND e.discarded_at IS NULL
LEFT JOIN word_states ws ON ws.word_id = w.id
WHERE l.lemma LIKE :glyph_like;
```

Three things worth keeping:

- **No `GROUP BY` and no CTE.** The aggregate runs over the whole filtered set, and `COUNT(DISTINCT l.id)`
  absorbs the row multiplication the `encounters` join introduces.
- Maturity is on FSRS **stability** (days until recall probability falls to 90%), not interval — the
  interval is clamped by the frequency caps, so an interval-based test would make maturity depend on a cap
  setting.
- The `>= 2` clause is load-bearing: knowing 生簀 alone is word knowledge wearing a character's costume.

---

## 3. The kanji map (Epic 4, R4.2)

Two answers need different shapes. Per-word facts come from one aggregate; per-*character* counts need the
lemma split, which SQL cannot do portably, so it is a fold in Elixir.

**3a. Per-word, one query:**

```sql
SELECT l.id   AS lexeme_id,
       l.lemma,
       MAX(CASE WHEN ws.stability >= :maturity_days THEN 1 ELSE 0 END) AS has_mature_word,
       COUNT(DISTINCT e.seen_on) AS days_seen,
       MIN(e.seen_on)            AS first_seen,
       MAX(e.seen_on)            AS last_seen
FROM lexemes l
JOIN words w ON w.lexeme_id = l.id AND w.user_id = :user_id
JOIN encounters e ON e.word_id = w.id
                AND e.confirmed = 1
                AND e.discarded_at IS NULL
LEFT JOIN word_states ws ON ws.word_id = w.id
GROUP BY l.id, l.lemma;
```

**3b. The fold:** exact per-glyph counts need distinct pages per character, which means expanding to
`(page, lemma)` pairs rather than summing per-word counts — summing would double-count a page that
contains two different words with the same kanji.

```sql
SELECT DISTINCT e.page_id, e.seen_on, l.lemma
FROM lexemes l
JOIN words w ON w.lexeme_id = l.id AND w.user_id = :user_id
JOIN encounters e ON e.word_id = w.id
                AND e.confirmed = 1
                AND e.discarded_at IS NULL;
```

```
kanji_map(rows):
    acc = %{}                                  # glyph => stats
    for (page, day, lemma) in rows:
        # distinct/1 matters: a lemma with a repeated character (日日) must credit
        # that page to 日 once, not twice.
        for glyph in distinct(cjk_codepoints(lemma)):   # codepoint filter, string order
            s = acc[glyph] ||= new_stats()
            s.pages.add(page)                  # a set: exact distinct pages
            s.days.add(day)
            s.first_seen = min(s.first_seen, day)
            s.last_seen  = max(s.last_seen, day)
    join with 3a on lemma to fold in distinct_words and has_mature_word
    return acc sorted by s.pages.size desc
```

**On accelerating the `LIKE` (optional, Postgres only).** `pg_trgm` cannot help here. A trigram is three
consecutive characters, and `%生%` is a one-character pattern: it yields no discriminating trigram, so the
planner falls back to a scan. pg_trgm pays off for 3+ character substrings, which is not a query this app
makes. The thing that *would* work is dialect-specific — a generated column holding the kanji as an array,
with a GIN index over it — which is why it stays an optional Postgres-only optimisation rather than part of
the portable schema. Verify with `EXPLAIN` before believing any of it; at 50 k lexemes the scan is already
a few milliseconds.

| | GIN | GiST |
|---|---|---|
| Shape | Inverted: element → list of rows | Balanced tree of bounding predicates |
| Best at | "contains this element", many elements per row | Nearest-neighbour ordering (`<->`), cheaper updates |
| Cost | Larger, slower to build | Smaller, faster to build, lossy (needs recheck) |
| For `LIKE`/`ILIKE` with pg_trgm | Generally the better choice | Works, but usually slower for selective lookups |
| For this app | Right shape: lexemes are written once and read often | Wrong shape: we never need similarity *ordering* |

`cjk_codepoints/1` filters on codepoint ranges rather than regexing bytes, so it cannot mis-split UTF-8.
Because this only changes on ingest, the result is memoised per user and invalidated when an encounter is
written — a cache of derived data, rebuildable, which is the distinction P6 draws against a stored counter.

Coverage of the 2,136 常用漢字 is `map_size(acc)` intersected with the jōyō set the dictionary service
supplies as a cached list.

---

## 4. The discrimination drill

Cannot be one query, and should not try to be. Deciding *which characters look alike* needs the
component data, which lives in `dict_cache_entries.payload` as JSON — and JSON extraction is the one
place SQLite (`json1`) and Postgres (`jsonb`) genuinely diverge. So: SQL for the ledger side, plain
Elixir for the dictionary side, no dialect-specific SQL anywhere.

```
build_discrimination_set(glyph, user, opt):

    # ── ledger side: SQL §1 ──
    words = met_words(user, glyph)                  # distinct lexemes, ordered by occurrences
    return :not_enough_evidence if length(words) < 2

    # ── dictionary side: cached lookups, plain Elixir ──
    target = dict_kanji(glyph)                      # {onyomi, kunyomi, meanings, components, jlpt}
    return :no_components if target.components == []

    # A kanji is 寺-shaped when it is (semantic radical) + (phonetic component).
    # Confusable characters share the phonetic component and differ in radical.
    phonetic = most_common_component(target.components)
    family   = all_kanji_sharing(phonetic)          # from the dictionary, not the ledger
    peers    = family - {glyph}

    # Prefer characters the user has already MET, then characters with the same
    # jlpt/freq band, then anything. Meet-first makes the card about a real
    # confusion rather than an invented one.
    distractors = take(3, sort(peers, by: [met_before(user), freq_distance(target)]))

    # ── cards ──
    for word in words:
        reading = word.reading                       # hiragana, from the tokenizer
        emit card(
            front:  { reading: reading, options: shuffle([glyph | distractors]) },
            back:   { answer: glyph,
                      radical: radical_of(target),           # 彳 step · 扌 hand · 日 sun
                      components: target.components,
                      word: word.lemma,
                      crop: encounter_crop(user, word) }     # the sentence it was met in
        )
```

Two rules that keep this honest:

- **Never generate the drill for a kanji with fewer than two met words.** Below that threshold there is
  no evidence the user has met the character in more than one context, and the card would be a
  memory test about a single word.
- **Distractors come from components, not from a random character list.** A "pick the right kanji" card
  with三 obvious wrong answers teaches nothing; 待/持/時/特 forces attention to the radical, which is
  the actual failure mode.

---

## 5. Coverage per source (R4.1)

```sql
SELECT s.id,
       s.name,
       s.chapter,
       COUNT(*)                                                  AS tokens,
       SUM(CASE WHEN w.known = 1
                  OR ws.stability >= :maturity_days
                THEN 1 ELSE 0 END)                               AS known_tokens
FROM encounters e
JOIN words   w ON w.id = e.word_id
JOIN sources s ON s.id = e.source_id
LEFT JOIN word_states ws ON ws.word_id = w.id
WHERE e.user_id = :user_id
  AND e.source_id = :source_id
  AND e.confirmed = 1
  AND e.discarded_at IS NULL
GROUP BY s.id, s.name, s.chapter;
```

`known_tokens / tokens` is the number that predicts whether the next chapter is readable — the one
number no prebuilt tool can supply, because it is computed over the user's own material.

---

## 6. Introduction priority (R3.9)

```sql
SELECT w.id,
       l.lemma,
       l.reading,
       3 * COUNT(DISTINCT e.seen_on) + COUNT(DISTINCT e.page_id) AS priority
FROM words w
JOIN lexemes  l ON l.id = w.lexeme_id
JOIN encounters e ON e.word_id = w.id
                AND e.confirmed = 1
                AND e.discarded_at IS NULL
LEFT JOIN word_states ws ON ws.word_id = w.id
WHERE w.user_id = :user_id
  AND w.chrome_like = 0
  AND w.known = 0
  AND w.suspended = 0
  AND ws.word_id IS NULL                       -- not yet introduced
GROUP BY w.id, l.lemma, l.reading
HAVING COUNT(DISTINCT e.page_id) >= :min_encounters
ORDER BY priority DESC
LIMIT :new_cards_per_day;
```

`days_seen` carries triple weight because spaced encounter predicts retention far better than massed
repetition. Chrome-like words are excluded here — that is the flag's whole purpose.
