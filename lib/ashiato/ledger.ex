defmodule Ashiato.Ledger do
  @moduledoc """
  The ledger: the context layer that owns vocabulary identity and every
  sighting of it, and that populates `user_id` (no auth yet, so this module is
  the single place that changes when auth arrives).

  Identity is global (`Ashiato.Schemas.Lexeme`, shared by all users); everything this
  module writes downstream of it is per user, carried explicitly via `user_id`
  on the arguments.

  Beyond identity and encounters, this module owns the boundary of the review
  queue: which words qualify for introduction, the known and suspended markers,
  and the `chrome_like` flag, including how it suspends and un-suspends words.
  """

  import Ecto.Query

  alias Ashiato.Schemas.Encounter
  alias Ashiato.Schemas.Lexeme
  alias Ashiato.Schemas.Page
  alias Ashiato.Repo
  alias Ashiato.Schemas.ReviewEvent
  alias Ashiato.Schemas.Source
  alias Ashiato.Srs
  alias Ashiato.Utils
  alias Ashiato.Schemas.WordState
  alias Ashiato.Schemas.Word

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

  @grade_again 1
  @remedial_hours {4, 12, 24}

  # A word enters the queue only after being met on this many distinct pages;
  # `introduce_words/3` lets a caller override it.
  @min_encounters 2

  # Chrome-like in a source means appearing on more than this fraction of its
  # pages — strictly more, so exactly half does not clear it.
  @chrome_threshold 0.5

  # Forward edges of the ingest pipeline; `:failed` is reachable from any non-terminal state.
  @forward %{
    uploaded: [:detecting],
    detecting: [:text_ready],
    text_ready: [:translating, :ready],
    translating: [:ready]
  }

  @non_terminal [:uploaded, :detecting, :text_ready, :translating]

  @doc """
  Finds the lexeme matching `(lemma, reading, part_of_speech)` or creates it.

  Safe under races. The common path is fetch-first; if the row does not exist
  we insert, and if we lose the race against a concurrent caller the declared
  `lexemes_lemma_reading_part_of_speech_index` unique constraint surfaces as
  `{:error, changeset}`, after which we fetch the row the winner just wrote.
  Returns `{:ok, %Lexeme{}}` whether we created it or not.

  `reading` is normalised `nil` → `""` to match the database default, so the
  `lexemes_lemma_reading_part_of_speech_index` unique index actually bites
  (multiple NULLs would pass).
  """
  @spec find_or_create_lexeme(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Lexeme.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_lexeme(lemma, reading, part_of_speech) do
    reading = reading || ""
    identity = [lemma: lemma, reading: reading, part_of_speech: part_of_speech]

    case Repo.get_by(Lexeme, identity) do
      %Lexeme{} = existing ->
        {:ok, existing}

      nil ->
        # reading goes on the struct, not through the changeset: cast/3 would
        # turn "" into nil (see Lexeme.changeset/2).
        %Lexeme{reading: reading}
        |> Lexeme.changeset(%{lemma: lemma, part_of_speech: part_of_speech})
        |> Repo.insert()
        |> case do
          {:ok, lexeme} ->
            {:ok, lexeme}

          {:error, changeset} ->
            # A uniqueness race: the winner's row must be there now. Should the
            # failure have been a validation error instead, the refetch finds
            # nothing and we surface the original changeset as-is.
            case Repo.get_by(Lexeme, identity) do
              %Lexeme{} = existing -> {:ok, existing}
              nil -> {:error, changeset}
            end
        end
    end
  end

  @doc """
  Records one sighting of a word on one page. Returns `{:ok, %Encounter{}}`
  whether it was just inserted or already existed.

  Idempotent against `encounters_user_id_word_id_text_hash_index`
  (`(user_id, word_id, text_hash)`): on conflict the insert is a no-op — the
  declaration in `Encounter.changeset/2` turns the constraint violation into
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
          {:ok, Encounter.t()} | {:error, Ecto.Changeset.t()}
  def record_encounter(attrs) do
    attrs = Map.new(attrs)
    user_id = Map.fetch!(attrs, :user_id)

    %Encounter{user_id: user_id}
    |> Encounter.changeset(Map.delete(attrs, :user_id))
    |> Repo.insert()
    |> case do
      {:ok, encounter} ->
        {:ok, encounter}

      {:error, changeset} ->
        case Repo.get_by(Encounter,
               user_id: user_id,
               word_id: attrs[:word_id],
               text_hash: attrs[:text_hash]
             ) do
          %Encounter{} = existing -> {:ok, existing}
          nil -> {:error, changeset}
        end
    end
  end

  @doc """
  Grades one review of a word and advances its scheduling state.

  Fetches the word (error if missing), computes the next state with
  `Ashiato.Srs.grade/3`, applies the remedial schedule on `again`, and writes
  the review event and materialised state in one transaction.

  Everything happens in one `Repo` transaction:

    1. the `Word` row is fetched for `user_id` (error if missing)
    2. the current `WordState` is fetched; an absent row just means *new*
       (state :new) — the state is rebuildable from the log, per §6.8
    3. the review is appended to `review_events` (append-only; the log is the
       source of truth)
    4. `word_states` is upserted from it — a mere materialisation

  `user_id` is set programmatically, never cast (AGENTS Ecto house rule).

  Returns `{:ok, %WordState{}}` (with `due_at` = `now` + the scheduled
  interval) or `{:error, changeset}`. `review/2` reviews now; pass `now`
  explicitly in tests for determinism.
  """
  @spec review(integer(), Srs.grade()) :: {:ok, WordState.t()} | {:error, Ecto.Changeset.t()}
  def review(word_id, grade), do: review(word_id, grade, DateTime.utc_now())

  @spec review(integer(), Srs.grade(), DateTime.t()) ::
          {:ok, WordState.t()} | {:error, Ecto.Changeset.t()}
  def review(word_id, grade, now) when is_integer(grade) and grade in 1..4 do
    Repo.transaction(fn ->
      case do_review(word_id, grade, now) do
        {:ok, word_state} -> word_state
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, word_state} -> {:ok, word_state}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def review(_word_id, _grade, _now) do
    {:error,
     %ReviewEvent{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:grade, "must be an FSRS grade between 1 and 4")}
  end

  @spec do_review(integer(), Srs.grade(), DateTime.t()) ::
          {:ok, WordState.t()} | {:error, Ecto.Changeset.t()}
  defp do_review(word_id, grade, now) do
    case Repo.get(Word, word_id) do
      nil ->
        {:error, missing_word_changeset(word_id)}

      word ->
        # a missing row means "new"
        word_state =
          case Repo.get(WordState, word_id) do
            %WordState{} = existing -> existing
            nil -> new_word_state(word_id, now)
          end

        %{state: next, interval_days: interval} = Srs.grade(word_state, grade, now)

        # word_states columns are second-precision (:utc_datetime); the log
        # row keeps the full usec `now`
        second = DateTime.truncate(now, :second)

        {failure_streak, due_at, interval_after} =
          schedule(grade, word_state.failure_streak, second, interval)

        with {:ok, _event} <-
               append_review_event(
                 word.user_id,
                 word_id,
                 grade,
                 now,
                 next,
                 interval_after
               ),
             {:ok, word_state} <-
               upsert_word_state(word_id, next, due_at, second, failure_streak) do
          {:ok, word_state}
        end
    end
  end

  defp schedule(@grade_again, failure_streak, now, _interval) do
    streak = failure_streak + 1
    step = elem(@remedial_hours, min(streak, tuple_size(@remedial_hours)) - 1)
    {streak, DateTime.add(now, step, :hour), 0}
  end

  defp schedule(_grade, _failure_streak, now, interval) do
    {0, DateTime.add(now, interval, :day), interval}
  end

  # The log is append-only: rows are only inserted, never updated or deleted.
  @spec append_review_event(
          integer(),
          integer(),
          Srs.grade(),
          DateTime.t(),
          WordState.t(),
          integer()
        ) ::
          {:ok, ReviewEvent.t()} | {:error, Ecto.Changeset.t()}
  defp append_review_event(user_id, word_id, grade, now, next, interval_after) do
    %ReviewEvent{user_id: user_id, word_id: word_id}
    |> ReviewEvent.changeset(%{
      grade: grade,
      reviewed_at: now,
      stability_after: next.stability,
      difficulty_after: next.difficulty,
      interval_after: interval_after
    })
    |> Repo.insert()
  end

  @spec upsert_word_state(integer(), WordState.t(), DateTime.t(), DateTime.t(), integer()) ::
          {:ok, WordState.t()} | {:error, Ecto.Changeset.t()}
  defp upsert_word_state(word_id, next, due_at, last_reviewed_at, failure_streak) do
    attrs = %{
      state: next.state,
      stability: next.stability,
      difficulty: next.difficulty,
      reps: next.reps,
      lapses: next.lapses,
      failure_streak: failure_streak,
      due_at: due_at,
      last_reviewed_at: last_reviewed_at
    }

    %WordState{word_id: word_id}
    |> WordState.changeset(attrs)
    |> Repo.insert(on_conflict: [set: Map.to_list(attrs)], conflict_target: :word_id)
  end

  @spec new_word_state(integer(), DateTime.t()) :: WordState.t()
  defp new_word_state(word_id, now) do
    %WordState{
      word_id: word_id,
      state: :new,
      stability: nil,
      difficulty: nil,
      reps: 0,
      lapses: 0,
      failure_streak: 0,
      due_at: now
    }
  end

  @spec missing_word_changeset(integer()) :: Ecto.Changeset.t()
  defp missing_word_changeset(word_id) do
    %WordState{word_id: word_id}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:word_id, "does not exist")
  end

  @doc """
  Chrome detection for one source: for each word, the fraction of that source's
  pages it appears on. The ratio is a query, never stored state, so it can be
  recomputed after any change to pages or encounters. An occurrence is a
  distinct page, and unconfirmed or discarded encounters count toward nothing.
  """
  @spec chrome_ratio(integer(), integer()) :: %{optional(integer()) => float()}
  def chrome_ratio(user_id, source_id) do
    pages =
      from(p in Page,
        where: p.user_id == ^user_id and p.source_id == ^source_id,
        select: count(p.id)
      )
      |> Repo.one()

    if pages == 0 do
      %{}
    else
      from(e in Encounter,
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
      from(e in Encounter,
        join: w in Word,
        on: w.id == e.word_id,
        join: s in Source,
        on: s.id == e.source_id,
        left_join: ws in WordState,
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
    from(l in Lexeme,
      join: w in Word,
      on: w.lexeme_id == l.id and w.user_id == ^user_id,
      join: e in Encounter,
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
      from(l in Lexeme,
        join: w in Word,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounter,
        on: e.word_id == w.id and confirmed_encounter?(e),
        left_join: ws in WordState,
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
      from(l in Lexeme,
        join: w in Word,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounter,
        on: e.word_id == w.id and confirmed_encounter?(e),
        distinct: true,
        select: %{page_id: e.page_id, seen_on: e.seen_on, lemma: l.lemma}
      )
      |> Repo.all()

    # One row per met word with the fold's maturity fact. Per-glyph days and
    # dates come from the sightings above, since summing per-word counts would
    # double-count across words sharing a kanji.
    word_facts =
      from(l in Lexeme,
        join: w in Word,
        on: w.lexeme_id == l.id and w.user_id == ^user_id,
        join: e in Encounter,
        on: e.word_id == w.id and confirmed_encounter?(e),
        left_join: ws in WordState,
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

  @doc """
  Introduces words to the review queue: each qualifying lexeme gets the
  `word_states` row whose absence marks it as not yet introduced. A lexeme
  qualifies when it has been met on at least `:min_encounters` distinct pages
  and is not known, suspended, chrome-like, or already queued.

  `:force` bypasses the occurrence threshold only, minting the `words` row for a
  lexeme never met; a known, suspended, chrome-like, or already-introduced word
  is still skipped. `:min_encounters` overrides the threshold. Returns the
  introduced words in the order the lexeme ids were given.
  """
  @spec introduce_words(integer(), [integer()], keyword()) ::
          {:ok, [Word.t()]} | {:error, term()}
  def introduce_words(user_id, lexeme_ids, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    min_encounters = Keyword.get(opts, :min_encounters, @min_encounters)
    lexeme_ids = Enum.uniq(lexeme_ids)

    Repo.transaction(fn ->
      due_at = Utils.utc_now()
      words = resolve_words(user_id, lexeme_ids, force?)

      words
      |> qualify(user_id, min_encounters, force?)
      |> Enum.map(&introduce_word(&1, due_at))
      |> in_lexeme_order(lexeme_ids)
    end)
  end

  @doc """
  Marks the user's copy of a lexeme as already known, so it never becomes a
  card; encounters keep counting. Returns `{:error, :not_found}` when the user
  has no `words` row for that lexeme.
  """
  @spec mark_known(integer(), integer()) :: {:ok, Word.t()} | {:error, :not_found}
  def mark_known(user_id, lexeme_id) do
    case Repo.get_by(Word, user_id: user_id, lexeme_id: lexeme_id) do
      nil ->
        {:error, :not_found}

      %Word{} = word ->
        word
        |> Ecto.Changeset.change(known: true)
        |> Repo.update()
    end
  end

  @doc """
  Creates a page. `attrs` must carry `user_id`, `source_id`, `image_key` and
  `text_hash`; `status` defaults to `:uploaded`. A duplicate
  `(user_id, text_hash)` — the same screen re-uploaded — returns
  `{:error, changeset}` instead of inserting.
  """
  @spec create_page(map() | keyword()) :: {:ok, Page.t()} | {:error, Ecto.Changeset.t()}
  def create_page(attrs) do
    attrs = Map.new(attrs)
    user_id = Map.fetch!(attrs, :user_id)
    attrs = attrs |> Map.delete(:user_id) |> Map.put_new(:status, :uploaded)

    %Page{user_id: user_id}
    |> Page.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Accepts corrected text for a page: sets `accepted_text` and bumps `revision`
  in a single write. The bump is what makes an in-flight job notice that the
  page moved on and discard its own result.

  Fenced on the `revision` the caller read: a correction arriving with a stale
  struct matches no rows and returns `{:error, :superseded}`, so two concurrent
  corrections cannot both write the same revision.
  """
  @spec accept_text(Page.t(), String.t()) ::
          {:ok, Page.t()} | {:error, :superseded}
  def accept_text(%Page{} = page, text) do
    query = from(p in Page, where: p.id == ^page.id and p.revision == ^page.revision)

    {count, _} =
      Repo.update_all(query, set: [accepted_text: text, revision: page.revision + 1])

    case count do
      0 -> {:error, :superseded}
      1 -> {:ok, Repo.get!(Page, page.id)}
    end
  end

  @doc """
  Writes a job's final status, but only while the page still carries the
  `revision` the job started from. A stale write matches no rows and returns
  `{:error, :superseded}`; a move the pipeline forbids returns
  `{:error, :invalid_transition}`.
  """
  @spec finish_page(Page.t(), atom()) ::
          {:ok, Page.t()} | {:error, :superseded | :invalid_transition}
  def finish_page(%Page{} = page, status) do
    unless valid_transition?(page.status, status) do
      {:error, :invalid_transition}
    else
      query = from(p in Page, where: p.id == ^page.id and p.revision == ^page.revision)

      {count, _} =
        Repo.update_all(query, set: [status: status])

      case count do
        0 -> {:error, :superseded}
        1 -> {:ok, Repo.get!(Page, page.id)}
      end
    end
  end

  @doc """
  Moves a page to the next status in the ingest pipeline, or to `:failed` from
  any non-terminal state. Anything else returns `{:error, :invalid_transition}`.
  """
  @spec transition(Page.t(), atom()) :: {:ok, Page.t()} | {:error, :invalid_transition}
  def transition(%Page{} = page, status) do
    unless valid_transition?(page.status, status) do
      {:error, :invalid_transition}
    else
      page
      |> Page.changeset(%{status: status})
      |> Repo.update()
    end
  end

  defp valid_transition?(from, to) do
    to in Map.get(@forward, from, []) or
      (to == :failed and from in @non_terminal)
  end

  @doc """
  Suspends the user's copy of a lexeme: out of the review queue, history and
  coverage untouched. `reason` is one of `:manual | :chrome | :mastered |
  :leech`, and `:mastered` also stamps `mastered_at`.

  An existing suspension keeps its reason, so `:chrome` never overwrites a
  `:manual`, `:mastered` or `:leech` one — that is what lets clearing the chrome
  flag remove only its own suspensions. Returns `{:error, changeset}` for a bad
  reason and `{:error, :not_found}` when there is no `words` row.
  """
  @spec mark_suspended(integer(), integer(), atom()) ::
          {:ok, Word.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def mark_suspended(user_id, lexeme_id, reason) do
    case Repo.get_by(Word, user_id: user_id, lexeme_id: lexeme_id) do
      nil ->
        {:error, :not_found}

      %Word{} = word ->
        reason =
          if word.suspended and not is_nil(word.suspended_reason) do
            word.suspended_reason
          else
            reason
          end

        word
        |> Ecto.Changeset.cast(%{suspended: true, suspended_reason: reason}, [
          :suspended,
          :suspended_reason
        ])
        |> mastered_at(reason)
        |> Repo.update()
    end
  end

  @doc """
  Recomputes `words.chrome_like` for one user. A word is chrome-like only when
  `chrome_ratio/2` clears the threshold in every source it appears in, so a word
  common in one game but rare in a manga stays unflagged.

  Flagging suspends the word with reason `:chrome`; clearing the flag
  un-suspends it only if that was its reason, so manual and mastered suspensions
  survive. Returns the user's chrome-like words after the run.
  """
  @spec update_chrome_like(integer()) :: {:ok, [Word.t()]}
  def update_chrome_like(user_id) do
    chrome_ids = chrome_word_ids(user_id)

    Repo.transaction(fn ->
      flagged_at = Utils.utc_now()

      flag_chrome(user_id, chrome_ids, flagged_at)
      suspend_chrome(user_id, chrome_ids, flagged_at)
      unflag_chrome(user_id, chrome_ids, flagged_at)
      unsuspend_chrome(user_id, chrome_ids, flagged_at)

      chrome_words(user_id)
    end)
  end

  # ── introduction ────────────────────────────────────────────────────────────

  # Resolves lexeme ids to this user's `words` rows; `:force` mints the missing
  # ones, since a never-met lexeme has no encounters to score (R3.4 force-add).
  @spec resolve_words(integer(), [integer()], boolean()) :: [Word.t()]
  defp resolve_words(user_id, lexeme_ids, force?) do
    existing =
      Repo.all(from(w in Word, where: w.user_id == ^user_id and w.lexeme_id in ^lexeme_ids))

    if force? do
      covered = MapSet.new(existing, & &1.lexeme_id)

      minted =
        for lexeme_id <- lexeme_ids, not MapSet.member?(covered, lexeme_id) do
          {:ok, word} = find_or_create_word(user_id, lexeme_id)
          word
        end

      existing ++ minted
    else
      existing
    end
  end

  # Fetch-first, so a lost insert race ends with the winner's row rather than a
  # raise. `Word` has no changeset (both fields are set on the struct), so one
  # is built here.
  @spec find_or_create_word(integer(), integer()) :: {:ok, Word.t()}
  defp find_or_create_word(user_id, lexeme_id) do
    case Repo.get_by(Word, user_id: user_id, lexeme_id: lexeme_id) do
      %Word{} = word ->
        {:ok, word}

      nil ->
        %Word{user_id: user_id, lexeme_id: lexeme_id}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint([:user_id, :lexeme_id])
        |> Repo.insert()
        |> case do
          {:ok, word} ->
            {:ok, word}

          # lost the race: the concurrent caller's row is there now
          {:error, _changeset} ->
            {:ok, Repo.get_by!(Word, user_id: user_id, lexeme_id: lexeme_id)}
        end
    end
  end

  # The qualifying half of the introduction query; ordering and the daily cap
  # belong to the caller. `:force` runs the same query with the threshold ignored.
  @spec qualify([Word.t()], integer(), pos_integer(), boolean()) :: [Word.t()]
  defp qualify(words, user_id, min_encounters, force?) do
    word_ids = Enum.map(words, & &1.id)

    rows =
      from(w in Word,
        where: w.user_id == ^user_id and w.id in ^word_ids,
        where: w.known == false and w.suspended == false and w.chrome_like == false,
        # anti-join: `is_nil` below keeps only words with no word_states row — not yet introduced
        left_join: ws in WordState,
        on: ws.word_id == w.id,
        where: is_nil(ws.word_id),
        # distinct pages; unconfirmed and discarded encounters count toward nothing
        left_join: e in Encounter,
        on: e.word_id == w.id and e.confirmed == true and is_nil(e.discarded_at),
        group_by: w.id,
        select: {w, count(e.page_id, :distinct)}
      )
      |> Repo.all()

    if force? do
      Enum.map(rows, &elem(&1, 0))
    else
      for {word, occurrences} <- rows, occurrences >= min_encounters, do: word
    end
  end

  @spec introduce_word(Word.t(), DateTime.t()) :: Word.t()
  defp introduce_word(word, due_at) do
    %WordState{word_id: word.id, state: :new, due_at: due_at}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:word_id])
    |> case do
      # `on_conflict: :nothing` also reports {:ok, _} when a concurrent caller
      # won the row; the word is introduced either way.
      {:ok, _} ->
        word

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  @spec in_lexeme_order([Word.t()], [integer()]) :: [Word.t()]
  defp in_lexeme_order(introduced, lexeme_ids) do
    by_lexeme = Map.new(introduced, &{&1.lexeme_id, &1})
    for(lexeme_id <- lexeme_ids, word = Map.get(by_lexeme, lexeme_id), do: word)
  end

  # ── chrome_like ─────────────────────────────────────────────────────────────

  # One chrome_ratio/2 pass per source, then one ratio list per word. The lists
  # are never empty, so `all?/1` here is never vacuously true.
  @spec chrome_word_ids(integer()) :: [integer()]
  defp chrome_word_ids(user_id) do
    ratios_by_word =
      user_id
      |> source_ids()
      |> Enum.flat_map(&chrome_ratio(user_id, &1))
      |> Enum.group_by(fn {word_id, _ratio} -> word_id end, fn {_word_id, ratio} -> ratio end)

    for {word_id, ratios} <- ratios_by_word, Enum.all?(ratios, &(&1 > @chrome_threshold)) do
      word_id
    end
  end

  @spec source_ids(integer()) :: [integer()]
  defp source_ids(user_id) do
    Repo.all(from(s in Source, where: s.user_id == ^user_id, select: s.id))
  end

  @spec flag_chrome(integer(), [integer()], DateTime.t()) :: {non_neg_integer(), nil}
  defp flag_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Word,
      where: w.user_id == ^user_id and w.id in ^chrome_ids and w.chrome_like == false
    )
    |> Repo.update_all(set: [chrome_like: true, updated_at: flagged_at])
  end

  # Suspends rather than deletes, so card history and coverage survive.
  @spec suspend_chrome(integer(), [integer()], DateTime.t()) :: {non_neg_integer(), nil}
  defp suspend_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Word,
      where: w.user_id == ^user_id and w.id in ^chrome_ids and w.suspended == false
    )
    |> Repo.update_all(set: [suspended: true, suspended_reason: :chrome, updated_at: flagged_at])
  end

  # A word that has stopped appearing anywhere loses the flag too, not just one
  # that is now rare.
  @spec unflag_chrome(integer(), [integer()], DateTime.t()) :: {non_neg_integer(), nil}
  defp unflag_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Word,
      where: w.user_id == ^user_id and w.chrome_like == true and w.id not in ^chrome_ids
    )
    |> Repo.update_all(set: [chrome_like: false, updated_at: flagged_at])
  end

  # Only a `:chrome` suspension is restored, which is why the reason is stored
  # rather than inferred.
  @spec unsuspend_chrome(integer(), [integer()], DateTime.t()) :: {non_neg_integer(), nil}
  defp unsuspend_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Word,
      where:
        w.user_id == ^user_id and w.suspended == true and w.suspended_reason == :chrome and
          w.id not in ^chrome_ids
    )
    |> Repo.update_all(set: [suspended: false, suspended_reason: nil, updated_at: flagged_at])
  end

  @spec chrome_words(integer()) :: [Word.t()]
  defp chrome_words(user_id) do
    Repo.all(from(w in Word, where: w.user_id == ^user_id and w.chrome_like == true))
  end

  # ── shared ──────────────────────────────────────────────────────────────────

  @spec mastered_at(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  defp mastered_at(changeset, :mastered),
    do: Ecto.Changeset.change(changeset, mastered_at: Utils.utc_now())

  defp mastered_at(changeset, _reason), do: changeset
end
