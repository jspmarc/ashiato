defmodule Ashiato.Ledger do
  @moduledoc """
  The ledger: the context layer that owns vocabulary identity and every
  sighting of it, and that populates `user_id` (§6.2 — no auth yet, so this
  module is the single place that changes when auth arrives).

  Identity is global (`Ashiato.Lexemes`, shared by all users); everything this
  module writes downstream of it is per user, carried explicitly via `user_id`
  on the arguments.

  Beyond identity and encounters, this module owns the boundary of the review
  queue: which words qualify for introduction (R3.4), the known and suspended
  markers (R2.3, R3.8), and the `chrome_like` flag with its R2.9 suspension
  hand-off (§6.5).
  """

  import Ecto.Query

  alias Ashiato.Encounters
  alias Ashiato.Lexemes
  alias Ashiato.Pages
  alias Ashiato.Repo
  alias Ashiato.Sources
  alias Ashiato.WordStates
  alias Ashiato.Words

  # R3.4: a word is not introduced to the queue until it has been met on at
  # least this many distinct pages. `introduce_words/3` takes `:min_encounters`
  # to override per call.
  @min_encounters 2

  # §6.5: a word appearing on more than this fraction of a source's pages is
  # chrome-like in that source. Strictly more than: being met on exactly half
  # the pages does not clear it.
  @chrome_threshold 0.5

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
  Introduces words to the review queue (R3.4): for every qualifying lexeme,
  creates the `word_states` row that the introduction query (kanji-review §6)
  reads as "not yet introduced" when it is absent — `state = 0`, `due_at` set
  to now, so the card is due immediately and FSRS owns everything after.

  A lexeme qualifies only when this user's `words` row for it

    * has been met on at least `:min_encounters` **distinct pages** (R3.4,
      §6.5 — occurrences, not tokens; confirmed and non-discarded only, R2.8)
    * is not `known` (R2.3)
    * is not `suspended`
    * is not `chrome_like` (§6.5)
    * has no `word_states` row yet — introducing twice never duplicates

  ## Options

    * `:force` (default `false`) — bypasses the occurrence threshold only. A
      known, suspended, chrome-like, or already-introduced word is still
      skipped. A lexeme that was never met has no `words` row at all; forcing
      one mints that row (the user's copy of the lexeme) and introduces it —
      the force-add override of R3.4 taken to its floor.
    * `:min_encounters` (default `#{@min_encounters}`) — the threshold itself.

  The batch runs in one transaction: every qualifying word is introduced or
  none is. Returns `{:ok, words}` — the words introduced, in the order the
  lexeme ids were given — or `{:error, reason}` if anything rolled back.
  """
  @spec introduce_words(integer(), [integer()], keyword()) ::
          {:ok, [Words.t()]} | {:error, term()}
  def introduce_words(user_id, lexeme_ids, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    min_encounters = Keyword.get(opts, :min_encounters, @min_encounters)
    lexeme_ids = Enum.uniq(lexeme_ids)

    Repo.transaction(fn ->
      due_at = utc_now()
      words = words_pool(user_id, lexeme_ids, force?)

      words
      |> qualify(user_id, min_encounters, force?)
      |> Enum.map(&introduce_word(&1, due_at))
      |> in_lexeme_order(lexeme_ids)
    end)
  end

  @doc """
  Marks the user's copy of a lexeme as already known (R2.3): it never becomes a
  card. Known words are excluded from `introduce_words/3` and from the
  introduction query, while encounters keep counting — the ledger remembers the
  sightings even when the word needs no studying.

  Returns `{:ok, %Words{}}`, or `{:error, :not_found}` when the user has no
  `words` row for that lexeme (nothing was ever met, so there is nothing to
  mark).
  """
  @spec mark_known(integer(), integer()) :: {:ok, Words.t()} | {:error, :not_found}
  def mark_known(user_id, lexeme_id) do
    case Repo.get_by(Words, user_id: user_id, lexeme_id: lexeme_id) do
      nil ->
        {:error, :not_found}

      %Words{} = word ->
        word
        |> Ecto.Changeset.change(known: true)
        |> Repo.update()
    end
  end

  @doc """
  Suspends the user's copy of a lexeme (R3.8): out of the queue, history
  preserved, coverage unaffected.

  `reason` must be one of the `words.suspended_reason` Ecto.Enum values —
  `:manual | :chrome | :mastered | :leech` — and is validated by casting
  through that same Ecto.Enum, so anything else arrives as
  `{:error, changeset}`. `:mastered` also stamps `mastered_at` (R3.8: suspend +
  mark mastered); any other reason leaves an existing stamp alone.

  Suspending never touches `chrome_like`: `update_chrome_like/1` owns that
  flag. Suspending a word that is already suspended keeps its original
  reason — `:chrome` never clobbers a `:manual` (or `:mastered` / `:leech`)
  suspension, which is what keeps clearing the flag from wiping one.

  Returns `{:ok, %Words{}}`, `{:error, changeset}` for a bad reason, or
  `{:error, :not_found}`.
  """
  @spec mark_suspended(integer(), integer(), atom()) ::
          {:ok, Words.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def mark_suspended(user_id, lexeme_id, reason) do
    case Repo.get_by(Words, user_id: user_id, lexeme_id: lexeme_id) do
      nil ->
        {:error, :not_found}

      %Words{} = word ->
        # An existing suspension keeps its reason: a :manual (or :mastered /
        # :leech) suspension must never be converted into :chrome, or clearing
        # the chrome flag would wipe it (R2.9, why the reason is stored).
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
  Recomputes `words.chrome_like` for every word of one user (§6.5, §6.6 — the
  ratio is a query, never stored state, so this is rerun whenever pages or
  encounters change).

  `chrome_ratio/2` runs once per source of the user. A word is chrome-like only
  when its ratio clears `@chrome_threshold` (more than half the pages) in
  **every** source it appears in — the sources where it has at least one
  confirmed, non-discarded page. So a HUD word that trips the threshold in one
  game but is rare in a manga stays unflagged, and a word that has stopped
  appearing anywhere loses a stale flag.

  R2.9 wiring:

    * when the flag lands on a word that is not already suspended, the word is
      suspended with `suspended_reason = :chrome` — history and coverage
      survive, nothing is deleted;
    * when the flag is cleared, the word is un-suspended **only** if its reason
      was `:chrome`. A `:manual`, `:mastered`, or `:leech` suspension survives —
      which is why the reason is stored rather than inferred.

  Returns `{:ok, words}` — the user's chrome-like words after the run.
  """
  @spec update_chrome_like(integer()) :: {:ok, [Words.t()]}
  def update_chrome_like(user_id) do
    chrome_ids = chrome_word_ids(user_id)

    Repo.transaction(fn ->
      flagged_at = utc_now()

      flag_chrome(user_id, chrome_ids, flagged_at)
      suspend_chrome(user_id, chrome_ids, flagged_at)
      unflag_chrome(user_id, chrome_ids, flagged_at)
      unsuspend_chrome(user_id, chrome_ids, flagged_at)

      chrome_words(user_id)
    end)
  end

  # ── introduction ────────────────────────────────────────────────────────────

  # Every lexeme id resolved to this user's `words` row. Rows only exist for
  # met lexemes — except under `:force`, which mints the missing ones: a
  # never-met lexeme has no encounters to score, so it qualifies vacuously once
  # the threshold is bypassed.
  defp words_pool(user_id, lexeme_ids, force?) do
    existing =
      Repo.all(from(w in Words, where: w.user_id == ^user_id and w.lexeme_id in ^lexeme_ids))

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

  # Same fetch-first shape as find_or_create_lexeme/3: on a lost insert race
  # the `(user_id, lexeme_id)` unique index is declared on the changeset, the
  # violation arrives as `{:error, changeset}`, and the winner's row is
  # fetched. `Words` has no changeset of its own — both fields are set
  # programmatically, never cast (AGENTS Ecto house rule) — so the changeset is
  # built here, empty, around the struct.
  defp find_or_create_word(user_id, lexeme_id) do
    case Repo.get_by(Words, user_id: user_id, lexeme_id: lexeme_id) do
      %Words{} = word ->
        {:ok, word}

      nil ->
        %Words{user_id: user_id, lexeme_id: lexeme_id}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.unique_constraint([:user_id, :lexeme_id])
        |> Repo.insert()
        |> case do
          {:ok, word} ->
            {:ok, word}

          # lost the race: the concurrent caller's row is there now
          {:error, _changeset} ->
            {:ok, Repo.get_by!(Words, user_id: user_id, lexeme_id: lexeme_id)}
        end
    end
  end

  # The qualification half of the introduction query (kanji-review §6), minus
  # the priority ordering — the caller decides order and the daily cap (R3.9).
  # Occurrences are counted in SQL and filtered here, so `:force` is the same
  # query with the threshold ignored.
  defp qualify(words, user_id, min_encounters, force?) do
    word_ids = Enum.map(words, & &1.id)

    rows =
      from(w in Words,
        where: w.user_id == ^user_id and w.id in ^word_ids,
        where: w.known == false and w.suspended == false and w.chrome_like == false,
        # "not yet introduced": the word_states row does not exist
        left_join: ws in WordStates,
        on: ws.word_id == w.id,
        where: is_nil(ws.word_id),
        # occurrences per §6.5: distinct pages; unconfirmed and discarded
        # encounters count toward nothing (R2.8)
        left_join: e in Encounters,
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

  defp introduce_word(word, due_at) do
    %WordStates{word_id: word.id, state: 0, due_at: due_at}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:word_id])
    |> case do
      # on_conflict: :nothing also reports {:ok, _} when a concurrent caller
      # won the row — the word is introduced either way, so it stays in the
      # result. `word_states` has no changeset to declare the constraint; the
      # conflict target names the primary key itself.
      {:ok, _} ->
        word

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp in_lexeme_order(introduced, lexeme_ids) do
    by_lexeme = Map.new(introduced, &{&1.lexeme_id, &1})
    for(lexeme_id <- lexeme_ids, word = Map.get(by_lexeme, lexeme_id), do: word)
  end

  # ── chrome_like ─────────────────────────────────────────────────────────────

  # One pass of chrome_ratio/2 per source, folded into word => [ratio, ...]
  # over the sources where the word appears (R2.8 counting rules apply:
  # chrome_ratio already excludes unconfirmed and discarded encounters). The
  # lists are never empty, so all?/1 is never vacuously true here.
  defp chrome_word_ids(user_id) do
    user_id
    |> source_ids()
    |> Enum.reduce(%{}, fn source_id, acc ->
      chrome_ratio(user_id, source_id)
      |> Enum.reduce(acc, fn {word_id, ratio}, acc ->
        Map.update(acc, word_id, [ratio], &[ratio | &1])
      end)
    end)
    |> Enum.filter(fn {_word_id, ratios} ->
      Enum.all?(ratios, &(&1 > @chrome_threshold))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp source_ids(user_id) do
    Repo.all(from(s in Sources, where: s.user_id == ^user_id, select: s.id))
  end

  # §6.5: the flag lands on every word chrome-like in all of its sources.
  defp flag_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Words,
      where: w.user_id == ^user_id and w.id in ^chrome_ids and w.chrome_like == false
    )
    |> Repo.update_all(set: [chrome_like: true, updated_at: flagged_at])
  end

  # R2.9: an existing card is suspended with reason chrome, never deleted.
  # Already-suspended words keep their reason — a :manual (or :mastered /
  # :leech) suspension is never overwritten by the flag.
  defp suspend_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Words,
      where: w.user_id == ^user_id and w.id in ^chrome_ids and w.suspended == false
    )
    |> Repo.update_all(set: [suspended: true, suspended_reason: :chrome, updated_at: flagged_at])
  end

  # A word no longer chrome-like everywhere loses the flag — including a word
  # that has stopped appearing anywhere at all.
  defp unflag_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Words,
      where: w.user_id == ^user_id and w.chrome_like == true and w.id not in ^chrome_ids
    )
    |> Repo.update_all(set: [chrome_like: false, updated_at: flagged_at])
  end

  # R2.9: clearing the flag restores the card — but only a :chrome suspension.
  # The reason is stored rather than inferred, which is what makes this safe:
  # a :manual (or :mastered / :leech) suspension survives untouched. This also
  # heals a :chrome suspension whose flag is already gone.
  defp unsuspend_chrome(user_id, chrome_ids, flagged_at) do
    from(w in Words,
      where:
        w.user_id == ^user_id and w.suspended == true and w.suspended_reason == :chrome and
          w.id not in ^chrome_ids
    )
    |> Repo.update_all(set: [suspended: false, suspended_reason: nil, updated_at: flagged_at])
  end

  defp chrome_words(user_id) do
    Repo.all(from(w in Words, where: w.user_id == ^user_id and w.chrome_like == true))
  end

  # ── shared ──────────────────────────────────────────────────────────────────

  # R3.8: suspend + mark mastered. Only :mastered stamps the date.
  defp mastered_at(changeset, :mastered),
    do: Ecto.Changeset.change(changeset, mastered_at: utc_now())

  defp mastered_at(changeset, _reason), do: changeset

  # `words` timestamps, `word_states.due_at` and `words.mastered_at` are
  # :utc_datetime columns — whole seconds.
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
