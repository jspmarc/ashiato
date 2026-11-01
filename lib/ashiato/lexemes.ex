defmodule Ashiato.Lexemes do
  @moduledoc """
  A lexical identity — **global**, shared by all users (§6.1, §6.3).

  `lemma + reading` is the word: same spelling with a different reading is a
  different word (生物 せいぶつ vs なまもの). `reading` is non-null with a `\"\"`
  database default so the `lexemes_identity` unique index actually bites —
  multiple NULLs would pass a unique index on both SQLite and Postgres.
  Uniqueness is `(lemma, reading, part_of_speech)` and lives here, on the shared
  table, not per user; identity is global while everything downstream is
  per user.
  """

  use Ecto.Schema

  import Ecto.Changeset,
    only: [cast: 3, validate_required: 2, unique_constraint: 2, unique_constraint: 3]

  schema "lexemes" do
    field :lemma, :string
    field :reading, :string
    field :part_of_speech, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset used by `Ashiato.Ledger.find_or_create_lexeme/3`.

  The `unique_constraint` declaration for `lexemes_identity` is what turns a
  lost insert race into `{:error, changeset}` instead of a raised
  `Ecto.ConstraintError`, so the ledger can fall back to fetching the row the
  concurrent caller just won.
  """
  def changeset(lexeme, attrs) do
    lexeme
    |> cast(attrs, [:lemma, :part_of_speech])
    # `reading` is NOT cast. cast/3 treats "" as an empty value and turns it into
    # nil, which defeats the column's NOT NULL DEFAULT '' -- and that default
    # exists so the unique index bites on kana-only words, since NULL is distinct
    # in a unique index and nil would mint a new row on every call. Callers set it
    # on the struct instead, the same way user_id is set rather than cast.
    |> validate_required([:lemma])
    # Same dual declaration as Encounters: Postgres names the index, SQLite does not.
    |> unique_constraint([:lemma, :reading, :part_of_speech], name: :lexemes_identity)
    |> unique_constraint([:lemma, :reading, :part_of_speech])
  end
end
