defmodule Ashiato.Words do
  @moduledoc """
  The reviewable unit: one card per (`user_id`, `lexeme_id`) unique.

  `chrome_like` is true only when the word clears the chrome ratio in **every**
  source it appears in (§6.5) — computed by `Ashiato.Ledger.chrome_ratio/2`, so
  HUD text in one game never suppresses real vocabulary met in a manga.
  """

  use Ecto.Schema

  schema "words" do
    belongs_to :user, Ashiato.Users
    belongs_to :lexeme, Ashiato.Lexemes

    field :known, :boolean, default: false
    field :suspended, :boolean, default: false
    field :suspended_reason, Ecto.Enum, values: [:manual, :chrome, :mastered, :leech]
    field :mastered_at, :utc_datetime
    field :chrome_like, :boolean, default: false

    timestamps(type: :utc_datetime)

    has_many :encounters, Ashiato.Encounters, foreign_key: :word_id
    has_one :word_state, Ashiato.WordStates, foreign_key: :word_id
  end
end
