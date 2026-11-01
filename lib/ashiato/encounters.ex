defmodule Ashiato.Encounters do
  @moduledoc """
  One sighting of a word on one page.

  Encounter identity is `(user_id, word_id, text_hash)` unique —
  `one_encounter_per_word_per_page` (§6.1). A single page yields many word
  encounters, so the page hash alone would collapse them into one. Identity
  ignores `page_id` on purpose: two pages with identical text are one and the
  same page row, so `(user_id, word_id, text_hash)` is the same test.

  `crop_key` is the permanent per-line crop (card front and OCR audit trail);
  only the *page* image ever expires, which is why no page geometry is stored
  here: it would die with the page, and the card shows the crop, not a box
  drawn over the original.
  `discarded_at` is a soft delete, so a bad OCR encounter never removes the
  word — which is also why identity lookups after a conflict always find the
  row. No timestamps: `seen_on` is the only date this table is about.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "encounters" do
    belongs_to :user, Ashiato.Users
    belongs_to :word, Ashiato.Words
    belongs_to :page, Ashiato.Pages
    belongs_to :source, Ashiato.Sources

    field :text_hash, :string
    # per-line crop, permanent: card front and OCR audit trail
    field :crop_key, :string
    field :crop_store, Ecto.Enum, values: [:local, :s3], default: :local
    field :seen_on, :date
    # R2.8: unconfirmed counts toward nothing
    field :confirmed, :boolean, default: false
    # soft delete so a bad OCR encounter never removes the word
    field :discarded_at, :utc_datetime
  end

  @doc """
  Changeset used by `Ashiato.Ledger.record_encounter/1`.

  `user_id` is NOT here: fields set programmatically are never cast (AGENTS
  Ecto house rule) — the ledger assigns it on the struct. The
  `one_encounter_per_word_per_page` unique constraint is declared so a duplicate
  arrives as `{:error, changeset}` rather than a raise, letting the ledger
  return the existing row.

  `confirmed` and `crop_store` are optional: when absent they are omitted from
  the insert, so the database defaults (`false` / `"local"`) apply.
  """
  def changeset(encounter, attrs) do
    encounter
    |> cast(attrs, [
      :word_id,
      :page_id,
      :source_id,
      :text_hash,
      :crop_key,
      :crop_store,
      :seen_on,
      :confirmed,
      :discarded_at
    ])
    |> validate_required([:word_id, :page_id, :source_id, :text_hash, :crop_key, :seen_on])
    # Two declarations, one constraint. Postgres reports the index by its custom
    # name; ecto_sqlite3 derives a name from the columns and ignores `name:`. Without
    # both, a duplicate raises Ecto.ConstraintError on one backend and returns
    # {:error, changeset} on the other -- and the ledger's whole idempotency contract
    # depends on the second behaviour.
    |> unique_constraint([:user_id, :word_id, :text_hash], name: :one_encounter_per_word_per_page)
    |> unique_constraint([:user_id, :word_id, :text_hash])
  end
end
