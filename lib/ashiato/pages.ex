defmodule Ashiato.Pages do
  @moduledoc """
  One photographed / uploaded screen (or one PDF page).

  Page identity is `(user_id, text_hash)`, unique via `one_page_per_distinct_text`.
  The hash is a SHA-256 of the normalised text: a fixed 64 bytes whatever the
  page length, since a raw-text index entry would outgrow the btree.

  `text_origin` stays nullable because the migration allows NULL.
  `revision` defaults to 1 and is bumped whenever the page's content changes,
  which is what discards stale job results.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "pages" do
    belongs_to :user, Ashiato.Users
    # never null: a default source exists from day one
    belongs_to :source, Ashiato.Sources
    # set only when this page came from a PDF
    belongs_to :document, Ashiato.Documents

    field :page_index, :integer
    # object key in S3-compatible storage, not a filesystem path
    field :image_key, :string
    field :image_store, Ecto.Enum, values: [:local, :s3], default: :local
    field :image_expires_at, :utc_datetime
    field :text_origin, Ecto.Enum, values: [:ocr, :embedded]
    # user-corrected text; everything downstream uses this
    field :accepted_text, :string
    field :text_hash, :string
    field :revision, :integer, default: 1

    field :status, Ecto.Enum,
      values: [:uploaded, :detecting, :text_ready, :translating, :ready, :failed]

    timestamps(type: :utc_datetime)

    has_many :encounters, Ashiato.Encounters, foreign_key: :page_id
  end

  @doc """
  Changeset for creating a page, and for its status and revision updates.
  `user_id` is set on the struct, not cast. The unique constraint turns a
  re-upload of the same screen into an error rather than a raise.
  """
  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :source_id,
      :document_id,
      :page_index,
      :image_key,
      :image_store,
      :image_expires_at,
      :text_origin,
      :accepted_text,
      :text_hash,
      :revision,
      :status
    ])
    |> validate_required([:source_id, :image_key, :text_hash, :status])
    |> unique_constraint([:user_id, :text_hash], name: :one_page_per_distinct_text)
    # declared twice: Postgres reports the index name, ecto_sqlite3 derives one from the columns
    |> unique_constraint([:user_id, :text_hash])
  end
end
