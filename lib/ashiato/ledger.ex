defmodule Ashiato.Ledger do
  @moduledoc """
  The ledger: the context layer that owns vocabulary identity and every
  sighting of it, and that populates `user_id` (no auth yet, so this module is
  the single place that changes when auth arrives).

  Identity is global (`Ashiato.Lexemes`, shared by all users); everything this
  module writes downstream of it is per user, carried explicitly via `user_id`
  on the arguments.
  """

  import Ecto.Query

  alias Ashiato.Encounters
  alias Ashiato.Lexemes
  alias Ashiato.Pages
  alias Ashiato.Repo

  # Forward edges of the ingest pipeline; `:failed` is reachable from any non-terminal state.
  @forward %{
    uploaded: [:detecting],
    detecting: [:text_ready],
    text_ready: [:translating],
    translating: [:ready]
  }

  @non_terminal [:uploaded, :detecting, :text_ready, :translating]

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
  pages it appears on. The ratio is a query, never stored state, so it can be
  recomputed after any change to pages or encounters. An occurrence is a
  distinct page, and unconfirmed or discarded encounters count toward nothing.
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
  Creates a page. `attrs` must carry `user_id`, `source_id`, `image_key` and
  `text_hash`; `status` defaults to `:uploaded`. A duplicate
  `(user_id, text_hash)` — the same screen re-uploaded — returns
  `{:error, changeset}` instead of inserting.
  """
  @spec create_page(map() | keyword()) :: {:ok, Pages.t()} | {:error, Ecto.Changeset.t()}
  def create_page(attrs) do
    attrs = Map.new(attrs)
    user_id = Map.fetch!(attrs, :user_id)
    attrs = attrs |> Map.delete(:user_id) |> Map.put_new(:status, :uploaded)

    %Pages{user_id: user_id}
    |> Pages.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Accepts corrected text for a page: sets `accepted_text` and bumps `revision`
  in a single write. The bump is what makes an in-flight job notice that the
  page moved on and discard its own result.
  """
  @spec accept_text(Pages.t(), String.t()) :: {:ok, Pages.t()} | {:error, Ecto.Changeset.t()}
  def accept_text(%Pages{} = page, text) do
    page
    |> Pages.changeset(%{accepted_text: text, revision: page.revision + 1})
    |> Repo.update()
  end

  @doc """
  Writes a job's final status, but only while the page still carries the
  `revision` the job started from. A stale write matches no rows and returns
  `{:error, :superseded}`; a move the pipeline forbids returns
  `{:error, :invalid_transition}`.
  """
  @spec finish_page(Pages.t(), atom()) ::
          {:ok, Pages.t()} | {:error, :superseded | :invalid_transition}
  def finish_page(%Pages{} = page, status) do
    unless valid_transition?(page.status, status) do
      {:error, :invalid_transition}
    else
      query = from(p in Pages, where: p.id == ^page.id and p.revision == ^page.revision)

      {count, _} =
        Repo.update_all(query, set: [status: status])

      case count do
        0 -> {:error, :superseded}
        1 -> {:ok, Repo.get!(Pages, page.id)}
      end
    end
  end

  @doc """
  Moves a page to the next status in the ingest pipeline, or to `:failed` from
  any non-terminal state. Anything else returns `{:error, :invalid_transition}`.
  """
  @spec transition(Pages.t(), atom()) :: {:ok, Pages.t()} | {:error, :invalid_transition}
  def transition(%Pages{} = page, status) do
    unless valid_transition?(page.status, status) do
      {:error, :invalid_transition}
    else
      page
      |> Pages.changeset(%{status: status})
      |> Repo.update()
    end
  end

  defp valid_transition?(from, to) do
    to in Map.get(@forward, from, []) or
      (to == :failed and from in @non_terminal)
  end
end
