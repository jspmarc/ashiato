defmodule Ashiato.Sources do
  @moduledoc """
  Where a page came from: a game, a manga, a book — or real life.

  `name IS NULL` marks the default source: the unsorted / real-world bucket,
  displayed as 現実世界. `sources_user_id_name_chapter_index` is unique on
  `(user_id, name, chapter)` only `WHERE name IS NOT NULL`, so the default
  source is deliberately exempt from the index — there is exactly one catch-all
  bucket per user, and SQL would otherwise need a sentinel name for it.
  Idempotency of the default source is therefore enforced by
  `priv/repo/seeds.exs`, not by the database.

  Every page requires a `source_id`, and that default source exists from day
  one precisely so nothing is ever unsourced.
  """

  use Ecto.Schema

  schema "sources" do
    belongs_to :user, Ashiato.Users

    field :name, :string
    field :kind, Ecto.Enum, values: [:game, :manga, :book, :signage, :other]
    field :chapter, :string, default: ""

    timestamps(type: :utc_datetime)

    has_many :pages, Ashiato.Pages, foreign_key: :source_id
  end
end
