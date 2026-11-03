defmodule Ashiato.WordStates do
  @moduledoc """
  FSRS materialisation, keyed by `word_id`.

  `state` backed by the `word_states_state_valid` CHECK: `0` new,
  `1` learning, `2` review, `3` relearning. `stability`/`difficulty` are
  NULL until the first review. No timestamps — `last_reviewed_at` and
  `Ashiato.ReviewEvents` carry time.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:word_id, :id, autogenerate: false}
  schema "word_states" do
    belongs_to :word, Ashiato.Words, define_field: false, foreign_key: :word_id

    field :state, :integer, default: 0
    field :stability, :float
    field :difficulty, :float
    field :reps, :integer, default: 0
    field :lapses, :integer, default: 0
    # set when the word is introduced
    field :due_at, :utc_datetime
    field :last_reviewed_at, :utc_datetime
  end

  @doc """
  Changeset for upserting a word state.

  `word_id` is never cast — it is the word that triggered the review.
  `due_at` is required (`null: false` on the column); `last_reviewed_at`
  stays NULL until the first review.
  """
  def changeset(word_state, attrs) do
    word_state
    |> cast(attrs, [:state, :stability, :difficulty, :reps, :lapses, :due_at, :last_reviewed_at])
    # due_at is set when the word is introduced (null: false); last_reviewed_at
    # stays NULL until the first review, so it is deliberately not required
    |> validate_required([:state, :reps, :lapses, :due_at])
    |> check_constraint(:state, name: :word_states_state_valid)
  end
end
