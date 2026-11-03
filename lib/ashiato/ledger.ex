defmodule Ashiato.Ledger do
  @moduledoc """
  The ledger: the context layer that owns vocabulary identity and every
  sighting of it, and that populates `user_id` (§6.2 — no auth yet, so this
  module is the single place that changes when auth arrives).

  Identity is global (`Ashiato.Lexemes`, shared by all users); everything this
  module writes downstream of it is per user, carried explicitly via `user_id`
  on the arguments.
  """

  import Ecto.Query

  alias Ashiato.Encounters
  alias Ashiato.Lexemes
  alias Ashiato.Pages
  alias Ashiato.Repo
  alias Ashiato.Sources
  alias Ashiato.Utils
  alias Ashiato.WordStates
  alias Ashiato.Words

  # Mature(word) ⇔ stability ≥ 21 days. Stability, not interval: the interval
  # is clamped by the band caps, and with a cap below the threshold no word
  # could ever mature. Kept in one place because the threshold will become
  # user-configurable.
  @maturity_days 21

  # A confirmed, non-discarded encounter: the only rows that count toward the
  # queries below.
  defmacrop confirmed_encounter?(e) do
    quote do
      unquote(e).confirmed and is_nil(unquote(e).discarded_at)
    end
  end

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
        where: confirmed_encounter?(e),
        select: {e.word_id, count(e.page_id, :distinct)},
        group_by: e.word_id
      )
      |> Repo.all()
      |> Map.new(fn {word_id, occurrences} -> {word_id, occurrences / pages} end)
    end
  end

  @doc """
  Per-source coverage: how many of the tokens the user has met in one source
  are known, and the resulting ratio.

  Known means `words.known` OR the word's FSRS stability has reached the
  21-day maturity threshold — a word the user marked, or one the scheduler
  predicts will stick, both count. `tokens` is the raw count of encounter
  rows (one row per `(user, word, text_hash)`, so a re-uploaded page cannot
  inflate it). Unconfirmed and discarded encounters count toward nothing.

  Returns `%{tokens: n, known_tokens: n, ratio: f}` with
  `ratio = known_tokens / tokens`; a source with no confirmed, non-discarded
  encounters returns `%{tokens: 0, known_tokens: 0, ratio: 0.0}`.
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
        where: confirmed_encounter?(e),
        select: %{
          tokens: count(e.id),
          known_tokens: filter(count(e.id), w.known or ws.stability >= ^@maturity_days)
        }
      )
      |> Repo.one()

    tokens = row.tokens
    known_tokens = row.known_tokens || 0

    ratio = if tokens == 0, do: 0.0, else: known_tokens / tokens
    %{tokens: tokens, known_tokens: known_tokens, ratio: ratio}
  end

  @doc """
  The words a user has met that contain a given character, filtered with
  `LIKE '%生%'` (exact for CJK: a glyph is one character and cannot be a
  substring of another).

  `occurrences` and `days_seen` count distinct pages and distinct days, so
  one screen repeating a word ten times cannot promote it. Ordered
  occurrences DESC, days_seen DESC — breadth first, then spacing.
  """
  @spec kanji_met_words(integer(), String.t()) :: [
          %{
            lexeme_id: integer(),
            lemma: String.t(),
            reading: String.t() | nil,
            part_of_speech: String.t() | nil,
            occurrences: integer(),
            days_seen: integer(),
            first_seen: Date.t(),
            last_seen: Date.t()
          }
        ]
  def kanji_met_words(user_id, glyph) do
    from(l in Lexemes,
      join: w in Words,
      on: w.lexeme_id == l.id and w.user_id == ^user_id,
      join: e in Encounters,
      on: e.word_id == w.id and confirmed_encounter?(e),
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
  A kanji is known when at least one word containing it is mature AND it
  appears in at least two distinct words.

  One aggregate over the whole filtered set — no GROUP BY, because
  `COUNT(DISTINCT l.id)` already absorbs the row multiplication the
  encounters join introduces. Maturity rides on stability, never the
  cap-clamped interval, expressed as `FILTER(MAX(ws.stability),
  ws.stability >= threshold)`: the plain `MAX(...)` stays NULL when no
  reached-threshold stability exists, while the CASE/0 equivalent would
  coerce every word into "not mature" and lose the distinction between a
  state row and its absence.
  """
  @spec kanji_known?(integer(), String.t()) :: boolean()
  def kanji_known?(user_id, glyph) do
    row =
      from(l in Lexemes,
        join: w in Words,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounters,
        on: e.word_id == w.id and confirmed_encounter?(e),
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
  The dashboard: one entry per distinct CJK glyph the user has met, ordered
  by distinct pages DESC then glyph ASC.

  Per-glyph counts cannot be one portable SQL aggregate — splitting a lemma
  into characters has no cross-dialect spelling (SQLite regexp vs Postgres
  arrays vs Lua function) — so two building blocks are folded here instead:
  distinct `(page, day, lemma)` rows carrying the per-glyph evidence, and
  per-word maturity facts folded in per glyph. Folding over (page, lemma)
  pairs, plus deduping each lemma's codepoints, keeps a page carrying two
  words with the same kanji — and a glyph repeated inside one lemma (日日) —
  from being counted twice.
  """
  @spec kanji_map(integer()) :: [
          %{
            glyph: String.t(),
            occurrences: integer(),
            days_seen: integer(),
            first_seen: Date.t(),
            last_seen: Date.t(),
            distinct_words: integer(),
            has_mature_word: boolean()
          }
        ]
  def kanji_map(user_id) do
    # distinct (page, day, lemma) rows — the exact per-glyph evidence.
    sightings =
      from(l in Lexemes,
        join: w in Words,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounters,
        on: e.word_id == w.id and confirmed_encounter?(e),
        distinct: true,
        select: %{page_id: e.page_id, seen_on: e.seen_on, lemma: l.lemma}
      )
      |> Repo.all()

    # One row per met word with the fold's maturity fact. Per-glyph days and
    # dates come from the sightings above, since summing per-word counts would
    # double-count across words sharing a kanji.
    word_facts =
      from(l in Lexemes,
        join: w in Words,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounters,
        on: e.word_id == w.id and confirmed_encounter?(e),
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

    stats =
      sightings
      |> Enum.flat_map(fn sighting ->
        Enum.map(Utils.cjk_codepoints(sighting.lemma), &{&1, sighting})
      end)
      |> Enum.reduce(%{}, fn {glyph, sighting}, acc ->
        Map.update(acc, glyph, new_stats(sighting), &add_sighting(&1, sighting))
      end)

    stats
    |> fold_word_facts(word_facts)
    |> Enum.map(&glyph_entry/1)
    |> Enum.sort_by(&{-&1.occurrences, &1.glyph})
  end

  # Merges each met word's facts into the glyphs of its lemma. Every glyph
  # here is already a key of the sightings fold above (same join base), so the
  # merge is strictly in place.
  defp fold_word_facts(stats, word_facts) do
    word_facts
    |> Enum.flat_map(fn fact ->
      Enum.map(Utils.cjk_codepoints(fact.lemma), &{&1, fact})
    end)
    |> Enum.reduce(stats, fn {glyph, fact}, acc ->
      Map.update!(acc, glyph, &add_word_fact(&1, fact))
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
        mature?: stats.mature? or fact.has_mature_word != nil
    }
  end

  defp glyph_entry({glyph, stats}) do
    %{
      glyph: glyph,
      occurrences: MapSet.size(stats.pages),
      days_seen: MapSet.size(stats.days),
      first_seen: Enum.min(stats.days, Date),
      last_seen: Enum.max(stats.days, Date),
      distinct_words: MapSet.size(stats.word_ids),
      has_mature_word: stats.mature?
    }
  end
end
