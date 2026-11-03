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
  alias Ashiato.ReviewEvents
  alias Ashiato.Srs
  alias Ashiato.WordStates
  alias Ashiato.Words

  @grade_again 1
  @remedial_hours {4, 12, 24}

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
  Grades one review of a word and advances its scheduling state.

  Fetches the word (error if missing), computes the next state with
  `Ashiato.Srs.grade/3`, applies the remedial schedule on `again`, and writes
  the review event and materialised state in one transaction.

  Everything happens in one `Repo` transaction:

    1. the `Words` row is fetched for `user_id` (error if missing)
    2. the current `WordStates` is fetched; an absent row just means *new*
       (state :new) — the state is rebuildable from the log, per §6.8
    3. the review is appended to `review_events` (append-only; the log is the
       source of truth)
    4. `word_states` is upserted from it — a mere materialisation

  `user_id` is set programmatically, never cast (AGENTS Ecto house rule).

  Returns `{:ok, %WordStates{}}` (with `due_at` = `now` + the scheduled
  interval) or `{:error, changeset}`. `review/2` reviews now; pass `now`
  explicitly in tests for determinism.
  """
  @spec review(integer(), Srs.grade()) :: {:ok, WordStates.t()} | {:error, Ecto.Changeset.t()}
  def review(word_id, grade), do: review(word_id, grade, DateTime.utc_now())

  @spec review(integer(), Srs.grade(), DateTime.t()) ::
          {:ok, WordStates.t()} | {:error, Ecto.Changeset.t()}
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
     %ReviewEvents{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:grade, "must be an FSRS grade between 1 and 4")}
  end

  @spec do_review(integer(), Srs.grade(), DateTime.t()) ::
          {:ok, WordStates.t()} | {:error, Ecto.Changeset.t()}
  defp do_review(word_id, grade, now) do
    case Repo.get(Words, word_id) do
      nil ->
        {:error, missing_word_changeset(word_id)}

      word ->
        # a missing row means "new"
        word_state =
          case Repo.get(WordStates, word_id) do
            %WordStates{} = existing -> existing
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
          WordStates.t(),
          integer()
        ) ::
          {:ok, ReviewEvents.t()} | {:error, Ecto.Changeset.t()}
  defp append_review_event(user_id, word_id, grade, now, next, interval_after) do
    %ReviewEvents{user_id: user_id, word_id: word_id}
    |> ReviewEvents.changeset(%{
      grade: grade,
      reviewed_at: now,
      stability_after: next.stability,
      difficulty_after: next.difficulty,
      interval_after: interval_after
    })
    |> Repo.insert()
  end

  @spec upsert_word_state(integer(), WordStates.t(), DateTime.t(), DateTime.t(), integer()) ::
          {:ok, WordStates.t()} | {:error, Ecto.Changeset.t()}
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

    %WordStates{word_id: word_id}
    |> WordStates.changeset(attrs)
    |> Repo.insert(on_conflict: [set: Map.to_list(attrs)], conflict_target: :word_id)
  end

  @spec new_word_state(integer(), DateTime.t()) :: WordStates.t()
  defp new_word_state(word_id, now) do
    %WordStates{
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
    %WordStates{word_id: word_id}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:word_id, "does not exist")
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
end
