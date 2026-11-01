defmodule Ashiato.WordStates do
  @moduledoc """
  The FSRS materialisation, keyed by `word_id` (the user is `word.user_id`).

  Derived from — and rebuildable from — `Ashiato.ReviewEvents`; not a
  first-class entity, hence the primary key being the foreign key itself.

  `state` is a plain integer backed by the `word_states_state_valid` CHECK:

    * `0` new
    * `1` learning
    * `2` review
    * `3` relearning

  `stability` / `difficulty` are NULL until the first review: undefined, not
  zero. No timestamps — `last_reviewed_at` and the review log carry time.
  """

  use Ecto.Schema

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
end
