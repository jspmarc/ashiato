defmodule Ashiato.Repo.Migrations.CreateOtherTables do
  use Ecto.Migration

  def change do
    create table(:sources) do
      add :user_id, references(:users, type: :integer, on_delete: :delete_all), null: false

      add :name, :string,
        comment: "NULL means the catch-all bucket, displayed as 現実世界. Unique only where present."

      add :kind, :string, null: false, comment: "game | manga | book | signage | other"
      add :chapter, :string, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    # sources_identity: a named source is unique per user and chapter. The
    # default source has name NULL and is deliberately exempt, because there is
    # exactly one catch-all bucket per user and SQL would otherwise need a
    # sentinel name for it.
    create unique_index(:sources, [:user_id, :name, :chapter],
             name: "sources_identity",
             where: "name IS NOT NULL"
           )

    # §6.9: enumerations are strings constrained twice. Ecto.Enum lives in the
    # schema; this CHECK covers everything else writing to the database.
    create constraint(:sources, :sources_kind_valid,
             check: "kind IN ('game', 'manga', 'book', 'signage', 'other')"
           )

    create table(:documents) do
      add :user_id, references(:users, type: :integer, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :page_count, :integer, null: false

      add :has_text_layer, :boolean,
        null: false,
        comment: "when true the text is extracted, not OCRed"

      timestamps(type: :utc_datetime)
    end

    create table(:pages) do
      add :user_id, references(:users, type: :integer, on_delete: :delete_all), null: false
      add :source_id, references(:sources, type: :integer, on_delete: :delete_all), null: false
      add :document_id, references(:documents, type: :integer, on_delete: :delete_all)
      add :page_index, :integer, comment: "zero-based index within that document"

      add :image_key, :string,
        null: false,
        comment: "object key in S3-compatible storage, not a filesystem path"

      add :image_store, :string,
        null: false,
        default: "local",
        comment: "local | s3: which backend holds image_key"

      add :image_expires_at, :utc_datetime,
        comment:
          "sweeper deletes the object after this. Line crops are permanent; this is the full page only."

      add :text_origin, :string,
        null: true,
        comment: "ocr | embedded: PDFs with a text layer skip OCR entirely"

      add :accepted_text, :text, comment: "user-corrected text; everything downstream uses this"

      add :text_hash, :string,
        null: false,
        comment: "SHA-256 of the normalized text; page identity per user"

      add :revision, :integer,
        null: false,
        default: 1,
        comment: "bumped on re-photograph or correction; stale job results are discarded"

      add :status, :string,
        null: false,
        comment: "uploaded | detecting | text_ready | translating | ready | failed"

      timestamps(type: :utc_datetime)
    end

    # one_page_per_distinct_text: re-uploading the same screen creates nothing
    # new. The hash is fixed-length, unlike the text, which would overflow a
    # Postgres btree index entry for a page of dialogue.
    create unique_index(:pages, [:user_id, :text_hash], name: "one_page_per_distinct_text")

    # the ingest queue: pick up pages that are waiting for work, per user
    create index(:pages, [:user_id, :status])

    # ordered pages of a PDF
    create index(:pages, [:document_id, :page_index])

    # §6.9: enumerated columns are strings constrained twice.
    create constraint(:pages, :pages_status_valid,
             check:
               "status IN ('uploaded', 'detecting', 'text_ready', 'translating', 'ready', 'failed')"
           )

    create constraint(:pages, :pages_text_origin_valid,
             check: "text_origin IN ('ocr', 'embedded')"
           )

    create constraint(:pages, :pages_image_store_valid, check: "image_store IN ('local', 's3')")

    create table(:words) do
      add :user_id, references(:users, type: :integer, on_delete: :delete_all), null: false
      add :lexeme_id, references(:lexemes, type: :integer), null: false
      add :known, :boolean, null: false, default: false
      add :suspended, :boolean, null: false, default: false

      add :suspended_reason, :string,
        comment:
          "manual | chrome | mastered | leech. Needed so unsuspending cannot clobber a different reason."

      add :mastered_at, :utc_datetime

      add :chrome_like, :boolean,
        null: false,
        default: false,
        comment:
          "true only when the word clears the chrome ratio in EVERY source it appears in, so HUD-in-one-game does not kill real vocabulary elsewhere"

      timestamps(type: :utc_datetime)
    end

    # one card per word per user, and the queue lookup
    create unique_index(:words, [:user_id, :lexeme_id])

    # §6.9: enumerated columns are strings constrained twice.
    create constraint(:words, :words_suspended_reason_valid,
             check:
               "suspended_reason IS NULL OR suspended_reason IN ('manual', 'chrome', 'mastered', 'leech')"
           )

    create table(:encounters) do
      add :user_id, references(:users, type: :integer, on_delete: :delete_all), null: false
      add :word_id, references(:words, type: :integer, on_delete: :delete_all), null: false
      add :page_id, references(:pages, type: :integer, on_delete: :delete_all), null: false
      add :source_id, references(:sources, type: :integer, on_delete: :delete_all), null: false
      add :text_hash, :string, null: false

      add :crop_key, :string,
        null: false,
        comment: "per-line crop, permanent: card front and OCR audit trail"

      add :crop_store, :string, null: false, default: "local"

      add :seen_on, :date, null: false

      add :confirmed, :boolean,
        null: false,
        default: false,
        comment: "R2.8: unconfirmed counts toward nothing"

      add :discarded_at, :utc_datetime,
        comment: "soft delete so a bad OCR encounter never removes the word"
    end

    # one_encounter_per_word_per_page: a single page yields many word
    # encounters, so page text hash alone would collapse them into one.
    create unique_index(:encounters, [:user_id, :word_id, :text_hash],
             name: "one_encounter_per_word_per_page"
           )

    # the occurrence rotation and the ghost signal
    create index(:encounters, [:word_id, :seen_on])

    # per-source coverage and the chrome ratio
    create index(:encounters, [:user_id, :source_id])

    # §6.9: enumerated columns are strings constrained twice.
    create constraint(:encounters, :encounters_crop_store_valid,
             check: "crop_store IN ('local', 's3')"
           )

    create table(:review_events) do
      add :user_id, references(:users, type: :integer, on_delete: :delete_all), null: false
      add :word_id, references(:words, type: :integer, on_delete: :delete_all), null: false
      add :grade, :integer, null: false, comment: "FSRS grade 1..4"
      add :reviewed_at, :utc_datetime_usec, null: false

      add :stability_after, :float,
        null: false,
        comment:
          "every review yields a new state; null would mean \"not computed\", which must not happen"

      add :difficulty_after, :float, null: false

      add :interval_after, :integer,
        null: false,
        comment: "0 is valid: a lapse resets the interval"
    end

    # replay a word's history in order and rebuild word_states
    create index(:review_events, [:word_id, :reviewed_at])

    # §6.9: FSRS grades are the integers 1..4.
    create constraint(:review_events, :review_events_grade_valid, check: "grade IN (1, 2, 3, 4)")

    create table(:word_states, primary_key: false) do
      add :word_id, references(:words, type: :integer, on_delete: :delete_all), primary_key: true

      add :state, :integer,
        null: false,
        default: 0,
        comment: "0 new | 1 learning | 2 review | 3 relearning"

      add :stability, :float, comment: "NULL until the first review: undefined, not zero"
      add :difficulty, :float, comment: "NULL until the first review"
      add :reps, :integer, null: false, default: 0
      add :lapses, :integer, null: false, default: 0

      add :due_at, :utc_datetime,
        null: false,
        comment: "set when the word is introduced"

      add :last_reviewed_at, :utc_datetime, comment: "NULL until the first review"
    end

    # §6.9: FSRS state is one of the four integer stages above.
    create constraint(:word_states, :word_states_state_valid, check: "state IN (0, 1, 2, 3)")
  end
end
