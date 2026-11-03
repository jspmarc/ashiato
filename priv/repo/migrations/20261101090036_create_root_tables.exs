defmodule Ashiato.Repo.Migrations.CreateRootTables do
  use Ecto.Migration

  def change do
    create table(:users) do
      timestamps(type: :utc_datetime)
    end

    create table(:lexemes) do
      add :lemma, :string,
        null: false,
        comment: "dictionary form: 食べた / 食べます / 食べる all land on 食べる"

      add :reading, :string,
        null: false,
        default: "",
        comment: "\"\" not NULL, so the unique index actually bites"

      add :part_of_speech, :string,
        null: false,
        default: "",
        comment: "from the tokenizer; drops particles, finds mimetics"

      timestamps(type: :utc_datetime)
    end

    # lexical identity is global, shared by all users (§6.1, §6.2, §6.3):
    # inflected forms collapse to the dictionary form, homophones stay apart. The
    # find-or-create path when recording words can race safely. The default Ecto
    # index name lets one declared constraint match on both Postgres and SQLite.
    create unique_index(:lexemes, [:lemma, :reading, :part_of_speech])

    create table(:settings) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :key, :string,
        null: false,
        comment: "e.g. translation_provider, new_cards_per_day, user_jlpt_level"

      add :value, :text,
        comment: "JSON-encoded, so one row per setting and no migration per option"

      add :secret, :boolean,
        null: false,
        default: false,
        comment:
          "true for API keys: encrypted at rest with a key derived from SECRET_KEY_BASE, never logged"

      # updated_at only: key-value rows are overwritten, creation moment is irrelevant
      timestamps(type: :utc_datetime)
    end

    # one row per (user, key): upsert on save, and the read path loads a user's
    # whole settings map from this index (erd.dbml "settings" note: key-value
    # chosen because the schema is still moving — no migration per toggle).
    create unique_index(:settings, [:user_id, :key])

    create table(:dict_cache_entries) do
      add :kind, :string,
        null: false,
        comment: "word | kanji"

      add :cache_key, :string, null: false

      add :dict_version, :string,
        null: false,
        comment: "JMdict release. No TTL: entries are immutable within a version."

      add :payload, :map

      add :fetched_at, :utc_datetime
    end

    # §6.9: enumerations are strings constrained twice. Ecto.Enum lives in the
    # schema; this CHECK covers everything else writing to the database.
    create constraint(:dict_cache_entries, :kind_word_or_kanji,
             check: "kind IN ('word', 'kanji')"
           )

    # cache identity (§6.9 / erd.dbml): JMdict is immutable between releases, so
    # an entry is either current or superseded wholesale when dict_version
    # flips. This is also the mass-lookup for per-page token enrichment.
    create unique_index(:dict_cache_entries, [:kind, :cache_key, :dict_version])
  end
end
