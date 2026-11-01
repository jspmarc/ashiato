defmodule Ashiato.Ledger do
  @moduledoc """
  The ledger: the context layer that owns vocabulary identity and every
  sighting of it, and that populates `user_id` (§6.2 — no auth yet, so this
  module is the single place that changes when auth arrives).

  Identity is global (`Ashiato.Lexemes`, shared by all users); everything this
  module writes downstream of it is per user, carried explicitly via `user_id`
  on the arguments.

  The derived, per-user questions — coverage (R4.1) and the kanji map (R4.2) —
  are answered here too, always as queries over the event log and never as
  stored counters (P6). The SQL they port lives in `docs/kanji-review.md`.
  """

  import Ecto.Query

  alias Ashiato.Encounters
  alias Ashiato.Lexemes
  alias Ashiato.Pages
  alias Ashiato.Repo
  alias Ashiato.Sources
  alias Ashiato.WordStates
  alias Ashiato.Words

  # The §6.6/§8 maturity default (21 days): mature(word) ⇔ stability ≥
  # maturity_threshold. Stability and not interval, because the interval is
  # clamped by the band caps (R3.5) — with a cap set below the threshold no
  # word could ever mature — while stability is FSRS's own measure of memory
  # strength and is unaffected by the clamp. Every kanji/coverage query below
  # pins this attribute; §8 makes it configurable, so it stays in one place.
  @maturity_days 21

  @doc """
  Finds the lexeme matching `(lemma, reading, part_of_speech)` or creates it.

  Safe under races. The common path is fetch-first; if the row does not exist
  we insert, and if we lose the race against a concurrent caller the declared
  `lexemes_identity` unique constraint surfaces as `{:error, changeset}`, after
  which we fetch the row the winner just wrote. Returns `{:ok, %Lexemes{}}`
  whether we created it or not.

  `reading` is normalised `nil` → `""` to match the database default, so the
  `lexemes_identity` unique index actually bites (multiple NULLs would pass).
  """
  @spec find_or_create_lexeme(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Lexemes.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_lexeme(lemma, reading, part_of_speech) do
    reading = reading || ""
    identity = [lemma: lemma, reading: reading, part_of_speech: part_of_speech]

    case Repo.get_by(Lexemes, identity) do
      %Lexemes{} = existing ->
        {:ok, existing}

      nil ->
        # reading goes on the struct, not through the changeset: cast/3 would
        # turn "" into nil (see Lexemes.changeset/2).
        %Lexemes{reading: reading}
        |> Lexemes.changeset(%{lemma: lemma, part_of_speech: part_of_speech})
        |> Repo.insert()
        |> case do
          {:ok, lexeme} ->
            {:ok, lexeme}

          {:error, changeset} ->
            # A uniqueness race: the winner's row must be there now. Should the
            # failure have been a validation error instead, the refetch finds
            # nothing and we surface the original changeset as-is.
            case Repo.get_by(Lexemes, identity) do
              %Lexemes{} = existing -> {:ok, existing}
              nil -> {:error, changeset}
            end
        end
    end
  end

  @doc """
  Records one sighting of a word on one page. Returns `{:ok, %Encounters{}}`
  whether it was just inserted or already existed.

  Idempotent against `one_encounter_per_word_per_page`
  (`(user_id, word_id, text_hash)`): on conflict the insert is a no-op — the
  declaration in `Encounters.changeset/2` turns the constraint violation into
  `{:error, changeset}` instead of a raise — and the row that already exists is
  fetched and returned. A duplicate therefore never raises and never writes;
  since encounters are only ever soft-deleted (`discarded_at`), that row is
  still there to find.

  `attrs` may be a map or keyword list with atom keys and must include
  `user_id`, `word_id`, `page_id`, `source_id`, `text_hash`, `crop_key`,
  `seen_on` (a `Date`), and optionally `confirmed` (default `false`) and
  `bbox`. `user_id` is set programmatically, never cast.
  """
  @spec record_encounter(keyword() | map()) ::
          {:ok, Encounters.t()} | {:error, Ecto.Changeset.t()}
  def record_encounter(attrs) do
    attrs = Map.new(attrs)
    # user_id is set programmatically, never cast (AGENTS Ecto house rule)
    user_id = Map.fetch!(attrs, :user_id)

    %Encounters{user_id: user_id}
    |> Encounters.changeset(Map.delete(attrs, :user_id))
    |> Repo.insert()
    |> case do
      {:ok, encounter} ->
        {:ok, encounter}

      {:error, changeset} ->
        case Repo.get_by(Encounters,
               user_id: user_id,
               word_id: attrs[:word_id],
               text_hash: attrs[:text_hash]
             ) do
          %Encounters{} = existing -> {:ok, existing}
          nil -> {:error, changeset}
        end
    end
  end

  @doc """
  Chrome detection for one source: for each word, the fraction of that source's
  pages on which the word appears.

  This is a **query, never stored state** — re-run it whenever pages or
  encounters change, so re-tuning the threshold costs nothing but time (§6.6).
  It is what decides `words.chrome_like` (§6.5): a word whose ratio clears the
  configured threshold (default 50%) is *chrome-like in this source*, but the
  `chrome_like` flag is only ever set when the word is chrome-like in **every**
  source it appears in — otherwise a HUD word met in one game would suppress
  real vocabulary read in a manga.

  Counting rules: an occurrence is a *distinct page* (counted once per page,
  breadth, not raw token count), and unconfirmed or soft-deleted (discarded)
  encounters count toward nothing (R2.8). The denominator is every page of the
  source. Returns a map of `word_id => ratio` in 0.0..1.0, empty when the
  source has no pages yet.
  """
  @spec chrome_ratio(integer(), integer()) :: %{optional(integer()) => float()}
  def chrome_ratio(user_id, source_id) do
    pages =
      from(p in Pages,
        where: p.user_id == ^user_id and p.source_id == ^source_id,
        select: count(p.id)
      )
      |> Repo.one()

    if pages == 0 do
      %{}
    else
      from(e in Encounters,
        where: e.user_id == ^user_id and e.source_id == ^source_id,
        where: is_nil(e.discarded_at) and e.confirmed,
        select: {e.word_id, count(e.page_id, :distinct)},
        group_by: e.word_id
      )
      |> Repo.all()
      |> Map.new(fn {word_id, occurrences} -> {word_id, occurrences / pages} end)
    end
  end

  @doc """
  Per-source coverage (R4.1, kanji-review.md §5): for one source, how many of
  the tokens the user has met there are known, and the resulting ratio.

  Known means `words.known` OR the word's FSRS stability has reached the
  §6.6/§8 maturity default (21 days) — a word the user marked, or one the
  scheduler says has stuck, both count. Unconfirmed and discarded encounters
  count toward nothing (R2.8). `tokens` is the raw count of encounter rows
  (§6.5 depth): one row per `(user, word, text_hash)`, so a re-uploaded page
  cannot inflate it.

  Returns `%{tokens: n, known_tokens: n, ratio: f}` with
  `ratio = known_tokens / tokens`; a source with no confirmed, non-discarded
  encounters returns `%{tokens: 0, known_tokens: 0, ratio: 0.0}`. This is the
  number that predicts whether the next chapter is readable, computed over the
  user's own material — the one number no prebuilt tool supplies.

  §5's `SUM(CASE WHEN w.known = 1 OR ws.stability >= :maturity_days THEN 1
  ELSE 0 END)` runs here as an aggregate FILTER over the identical predicate
  and rows: Ecto has no CASE expression and this module writes no fragments,
  and `COUNT(...) FILTER (WHERE ...)` is the same number of rows (SQLite 3.30+
  and Postgres both speak FILTER).
  """
  @spec coverage(integer(), integer()) :: %{
          tokens: integer(),
          known_tokens: integer(),
          ratio: float()
        }
  def coverage(user_id, source_id) do
    row =
      from(e in Encounters,
        join: w in Words,
        on: w.id == e.word_id,
        join: s in Sources,
        on: s.id == e.source_id,
        left_join: ws in WordStates,
        on: ws.word_id == w.id,
        where: e.user_id == ^user_id and e.source_id == ^source_id,
        where: e.confirmed and is_nil(e.discarded_at),
        select: %{
          tokens: count(e.id),
          known_tokens: filter(count(e.id), w.known or ws.stability >= ^@maturity_days)
        }
      )
      |> Repo.one()

    tokens = row.tokens
    # COUNT over an empty set is 0, never NULL — the `|| 0` is belt and braces.
    known_tokens = row.known_tokens || 0

    ratio = if tokens == 0, do: 0.0, else: known_tokens / tokens
    %{tokens: tokens, known_tokens: known_tokens, ratio: ratio}
  end

  @doc """
  The words a user has met that contain a given character (kanji-review.md
  §1): filtered with `LIKE '%生%'`, exact for CJK because a glyph is one
  character and cannot be a substring of another. It is a scan rather than an
  index lookup — the price of staying portable between SQLite and Postgres.

  `occurrences` counts distinct pages, not tokens, so one screen repeating a
  word ten times cannot promote it (§6.5); `days_seen` counts distinct days.
  Unconfirmed and discarded encounters count toward nothing (R2.8). Ordered
  occurrences DESC, days_seen DESC — breadth first, then spacing. This is the
  core query the discrimination drill (§4) builds its cards on.
  """
  @spec kanji_met_words(integer(), String.t()) :: [map()]
  def kanji_met_words(user_id, glyph) do
    from(l in Lexemes,
      join: w in Words,
      on: w.lexeme_id == l.id and w.user_id == ^user_id,
      join: e in Encounters,
      on: e.word_id == w.id and e.confirmed and is_nil(e.discarded_at),
      where: like(l.lemma, ^"%#{glyph}%"),
      group_by: [l.id, l.lemma, l.reading, l.part_of_speech],
      order_by: [desc: count(e.page_id, :distinct), desc: count(e.seen_on, :distinct)],
      select: %{
        lexeme_id: l.id,
        lemma: l.lemma,
        reading: l.reading,
        part_of_speech: l.part_of_speech,
        occurrences: count(e.page_id, :distinct),
        days_seen: count(e.seen_on, :distinct),
        first_seen: min(e.seen_on),
        last_seen: max(e.seen_on)
      }
    )
    |> Repo.all()
  end

  @doc """
  P3: a kanji is known when at least one word containing it is mature AND it
  appears in at least two distinct words (kanji-review.md §2).

  One aggregate over the whole filtered set — no GROUP BY and no CTE, because
  `COUNT(DISTINCT l.id)` already absorbs the row multiplication the encounters
  join introduces. Maturity rides on stability, never the cap-clamped interval
  (§6.6), expressed as the §2 `MAX(CASE WHEN ws.stability >= threshold THEN 1
  ELSE 0 END)` form: Ecto has no CASE expression, so the identical predicate
  runs as `FILTER(MAX(ws.stability), ws.stability >= threshold)`, which is
  non-nil exactly when that MAX(CASE) is 1 — NULL-safe on both the missing
  word_states row and the not-yet-reviewed one.

  The `>= 2` clause is load-bearing: knowing 生簀 alone is word knowledge
  wearing a character's costume.
  """
  @spec kanji_known?(integer(), String.t()) :: boolean()
  def kanji_known?(user_id, glyph) do
    row =
      from(l in Lexemes,
        join: w in Words,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounters,
        on: e.word_id == w.id and e.confirmed and is_nil(e.discarded_at),
        left_join: ws in WordStates,
        on: ws.word_id == w.id,
        where: like(l.lemma, ^"%#{glyph}%"),
        select: %{
          distinct_words: count(l.id, :distinct),
          has_mature_word: filter(max(ws.stability), ws.stability >= ^@maturity_days)
        }
      )
      |> Repo.one()

    row.distinct_words >= 2 and row.has_mature_word != nil
  end

  @doc """
  The dashboard (Epic 4, R4.2, kanji-review.md §3): one entry per distinct CJK
  glyph the user has met, ordered by distinct pages DESC then glyph ASC.

  Per-glyph counts cannot be one portable SQL aggregate — splitting a lemma
  into characters has no cross-dialect spelling — so §3b supplies distinct
  `(page, day, lemma)` rows and the fold below expands each lemma's CJK
  codepoints (a codepoint filter, not a byte regex, so UTF-8 cannot be
  mis-split). Building over (page, lemma) pairs rather than summing per-word
  counts is what keeps a page carrying two different words with the same kanji
  from being counted twice, and the fold credits a glyph repeated inside one
  lemma (日日) once, not twice.

  `distinct_words` and `has_mature_word` are the §3a per-word facts folded in
  per glyph; every glyph of a §3a lemma is necessarily already a key of the
  §3b fold, both queries sharing the same confirmed, non-discarded join base.
  Maturity is the §6.6/§8 default (21 days) via the same FILTER(MAX(...))
  stand-in for §2's MAX(CASE ...) described in `kanji_known?/2`.
  """
  @spec kanji_map(integer()) :: [map()]
  def kanji_map(user_id) do
    # §3b: distinct (page, day, lemma) rows — the exact per-glyph evidence.
    sightings =
      from(l in Lexemes,
        join: w in Words,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounters,
        on: e.word_id == w.id and e.confirmed and is_nil(e.discarded_at),
        distinct: true,
        select: %{page_id: e.page_id, seen_on: e.seen_on, lemma: l.lemma}
      )
      |> Repo.all()

    # §3a: one row per met word. Only distinct_words and has_mature_word are
    # selected: the fold's per-glyph days and dates come from §3b, since
    # summing per-word counts would double-count across words sharing a kanji.
    word_facts =
      from(l in Lexemes,
        join: w in Words,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounters,
        on: e.word_id == w.id and e.confirmed and is_nil(e.discarded_at),
        left_join: ws in WordStates,
        on: ws.word_id == w.id,
        group_by: [l.id, l.lemma],
        select: %{
          lexeme_id: l.id,
          lemma: l.lemma,
          has_mature_word: filter(max(ws.stability), ws.stability >= ^@maturity_days)
        }
      )
      |> Repo.all()

    # The fold: glyph => stats. distinct/1 on the codepoints is what credits a
    # repeated glyph (日日) once per page, and the (page, lemma) rows above are
    # what credits a page shared by two words with the same kanji once.
    stats =
      Enum.reduce(sightings, %{}, fn sighting, acc ->
        Enum.reduce(cjk_codepoints(sighting.lemma), acc, fn glyph, acc ->
          Map.update(acc, glyph, new_stats(sighting), &add_sighting(&1, sighting))
        end)
      end)

    stats
    |> fold_word_facts(word_facts)
    |> Enum.map(&glyph_entry/1)
    |> Enum.sort_by(&{-&1.occurrences, &1.glyph})
  end

  # §3a fold: merges each met word's facts into the glyphs of its lemma. Every
  # glyph here is already a key of the §3b fold (same join base), so the merge
  # is strictly in place.
  defp fold_word_facts(stats, word_facts) do
    Enum.reduce(word_facts, stats, fn fact, acc ->
      Enum.reduce(cjk_codepoints(fact.lemma), acc, fn glyph, acc ->
        Map.update!(acc, glyph, &add_word_fact(&1, fact))
      end)
    end)
  end

  defp new_stats(sighting) do
    %{
      pages: MapSet.new([sighting.page_id]),
      days: MapSet.new([sighting.seen_on]),
      word_ids: MapSet.new(),
      mature?: false
    }
  end

  defp add_sighting(stats, sighting) do
    %{
      stats
      | pages: MapSet.put(stats.pages, sighting.page_id),
        days: MapSet.put(stats.days, sighting.seen_on)
    }
  end

  defp add_word_fact(stats, fact) do
    %{
      stats
      | word_ids: MapSet.put(stats.word_ids, fact.lexeme_id),
        # has_mature_word is non-nil exactly when §2's MAX(CASE ...) is 1.
        mature?: stats.mature? or fact.has_mature_word != nil
    }
  end

  defp glyph_entry({glyph, stats}) do
    %{
      glyph: glyph,
      # occurrences is §6.5 breadth: distinct pages, counted once per page.
      occurrences: MapSet.size(stats.pages),
      days_seen: MapSet.size(stats.days),
      first_seen: Enum.min(stats.days, Date),
      last_seen: Enum.max(stats.days, Date),
      distinct_words: MapSet.size(stats.word_ids),
      has_mature_word: stats.mature?
    }
  end

  # kanji-review.md §3b: the distinct CJK codepoints of a string, in string
  # order. Filtering codepoints rather than regexing bytes means UTF-8 cannot
  # be mis-split, and the dedupe is what makes a glyph repeated inside one
  # lemma credit its page once rather than once per occurrence.
  defp cjk_codepoints(string) do
    string
    |> String.codepoints()
    |> Enum.filter(&cjk_codepoint?/1)
    |> Enum.uniq()
  end

  # U+4E00..U+9FFF: the CJK Unified Ideographs block. Hiragana, katakana,
  # latin and punctuation all fall outside it, so kana-only lemmas contribute
  # no kanji.
  defp cjk_codepoint?(codepoint) do
    case String.to_charlist(codepoint) do
      [cp] when cp in 0x4E00..0x9FFF -> true
      _ -> false
    end
  end
end
