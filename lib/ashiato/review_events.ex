defmodule Ashiato.ReviewEvents do
  @moduledoc """
  Append-only review log; the source of truth for scheduling (§6.8).

  Replaying a word's history `(word_id, reviewed_at)` rebuilds `word_states`,
  which is a mere materialisation of this log.

  `grade` is the FSRS grade as a plain integer, 1..4 (backed by the
  `review_events_grade_valid` CHECK): 1 = again, 2 = hard, 3 = good, 4 = easy.
  No timestamps of our own — `reviewed_at` *is* the timestamp, with usec
  precision. `interval_after` may be 0: a lapse resets the interval.
  """

  use Ecto.Schema

  schema "review_events" do
    belongs_to :user, Ashiato.Users
    belongs_to :word, Ashiato.Words

    # FSRS grade 1..4
    field :grade, :integer
    field :reviewed_at, :utc_datetime_usec
    # every review yields a new state: null would mean "not computed", which must not happen
    field :stability_after, :float
    field :difficulty_after, :float
    field :interval_after, :integer
  end
end
