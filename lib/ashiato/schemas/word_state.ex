defmodule Ashiato.WordStates do
  @moduledoc """
  FSRS materialisation, keyed by `word_id`.

  Derived from — and rebuildable from — `Ashiato.ReviewEvents`; not a
  first-class entity, hence the primary key being the foreign key itself.

  `state` is an `Ecto.Enum` backed by the `word_states_state_valid` CHECK:

    * `:new` — `0`
    * `:learning` — `1`
    * `:review` — `2`
    * `:relearning` — `3`

  `stability` / `difficulty` are NULL until the first review: undefined, not
  zero. `failure_streak` counts consecutive `again` grades and resets on any
  pass; it drives the remedial/ghost schedule, not FSRS. No timestamps —
  `last_reviewed_at` and the review log carry time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type state :: :new | :learning | :review | :relearning

  @primary_key {:word_id, :id, autogenerate: false}
  schema "word_states" do
    belongs_to :word, Ashiato.Words, define_field: false, foreign_key: :word_id

    field :state, Ecto.Enum,
      values: [new: 0, learning: 1, review: 2, relearning: 3],
      default: :new

    field :stability, :float
    field :difficulty, :float
    field :reps, :integer, default: 0
    field :lapses, :integer, default: 0
    field :failure_streak, :integer, default: 0
    # set when the word is introduced
    field :due_at, :utc_datetime
    field :last_reviewed_at, :utc_datetime
  end

  @doc """
  Changeset for upserting a word state.

  Only the scheduling-relevant fields are cast: state, stability, difficulty,
  reps, lapses, failure_streak, due_at, last_reviewed_at. `word_id` is the
  primary key and is never cast — it is always the word that triggered the
  review. Values are computed server-side (FSRS output plus the remedial
  schedule), so beyond presence the CHECK constraints are the guard; the row
  is a rebuildable materialisation of the review log (§6.8).
  """
  def changeset(word_state, attrs) do
    word_state
    |> cast(attrs, [
      :state,
      :stability,
      :difficulty,
      :reps,
      :lapses,
      :failure_streak,
      :due_at,
      :last_reviewed_at
    ])
    # due_at is set when the word is introduced (null: false); last_reviewed_at
    # stays NULL until the first review, so it is deliberately not required
    |> validate_required([:state, :reps, :lapses, :failure_streak, :due_at])
    |> validate_number(:failure_streak, greater_than_or_equal_to: 0)
    |> check_constraint(:state, name: :word_states_state_valid)
    |> check_constraint(:failure_streak, name: :word_states_failure_streak_valid)
  end
end
