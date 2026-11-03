defmodule Ashiato.Fixtures do
  @moduledoc """
  Test fixtures for the ledger.

  Every fixture takes an attribute map that overrides the defaults, because the
  ledger's interesting behaviour lives in its identities: a duplicate `lemma +
  reading + POS`, a repeated `(user, word, text_hash)`, a word on most pages of
  a source. Tests need to build those deliberately.
  """

  alias Ashiato.Repo
  alias Ashiato.Schemas.{Lexeme, Page, Source, User, Word}

  @doc """
  A user. One is all this app has, but tests need more than one to prove that
  lanterns do not leak across them.
  """
  def user_fixture(attrs \\ %{}) do
    %User{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  @doc """
  A source. Pass `name: nil` for the unsorted / real-world bucket, which is the
  row seeds create for the real user.
  """
  def source_fixture(attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        user_id: user_fixture().id,
        name: "ゲーム#{System.unique_integer([:positive])}",
        kind: :game
      })

    %Source{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  @doc """
  A lexeme. `lemma + reading + part_of_speech` is globally unique, so the
  defaults are unique per call.
  """
  def lexeme_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        lemma: "言葉#{n}",
        reading: "ことば#{n}",
        part_of_speech: "noun"
      })

    %Lexeme{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  @doc """
  A page. `(user_id, text_hash)` is unique, so the hash is unique per call unless
  a test overrides it to exercise the duplicate.
  """
  def page_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Enum.into(attrs, %{
        user_id: user_fixture().id,
        source_id: source_fixture().id,
        image_key: "pages/#{n}.jpg",
        text_hash: "hash-#{n}",
        status: :uploaded
      })

    %Page{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end

  @doc """
  A word: the user's copy of a lexeme.
  """
  def word_fixture(attrs \\ %{}) do
    user_id = attrs[:user_id] || user_fixture().id

    attrs =
      Enum.into(attrs, %{
        user_id: user_id,
        lexeme_id: lexeme_fixture().id
      })

    %Word{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end
