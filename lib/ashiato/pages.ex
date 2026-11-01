defmodule Ashiato.Pages do
  @moduledoc """
  One photographed / uploaded screen (or one PDF page).

  Page identity is `(user_id, text_hash)` unique — `one_page_per_distinct_text`.
  The hash is a SHA-256 of the *normalised* text: a fixed 64 bytes whatever the
  page length (a Postgres btree entry caps around 2.7 kB, so raw text would not
  fit), and normalization happens once here rather than on every lookup.
  Re-uploading the same screen therefore creates nothing new.

  Migration deviation from the ERD (migration is authoritative): `text_origin`
  was created `null: true`, so the schema keeps it nil-able even though the ERD
  note reads "not null". `revision` defaults to 1 in the database and is bumped
  on re-photograph or correction, discarding stale job results.
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
  Changeset used by `Ashiato.Ledger.create_page/1` (and the status / revision
  updates).

  `user_id` is NOT cast: it is set programmatically on the struct (AGENTS Ecto
  house rule — fields set programmatically are never cast). The
  `one_page_per_distinct_text` unique constraint is declared so a re-upload of
  the same screen arrives as `{:error, changeset}` rather than a raised
  `Ecto.ConstraintError`. Two declarations: Postgres reports the index by its
  name, `ecto_sqlite3` derives one from the columns and ignores `name:`.
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
    |> unique_constraint([:user_id, :text_hash])
  end
end
