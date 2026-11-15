defmodule Ashiato.FixturesTest do
  @moduledoc """
  Fixtures resolve ownership before building defaults, so a page and its
  source never disagree about the user and no fixture call leaves an unused
  row behind. These tests pin both directions of the resolution and the
  row counts around it.
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures

  alias Ashiato.Repo
  alias Ashiato.Schemas.{Lexeme, Source, User}

  test "a default page and its source share one user, and only one user exists" do
    page = page_fixture()
    source = Repo.get!(Source, page.source_id)

    assert page.user_id == source.user_id
    assert Repo.aggregate(User, :count, :id) == 1
  end

  test "page_fixture with user_id creates its source under that user" do
    user = user_fixture()

    page = page_fixture(user_id: user.id)

    assert Repo.get!(Source, page.source_id).user_id == user.id
    assert Repo.aggregate(User, :count, :id) == 1
  end

  test "page_fixture with source_id takes the source's user and creates nothing else" do
    source = source_fixture()

    page = page_fixture(source_id: source.id)

    assert page.user_id == source.user_id
    assert Repo.aggregate(User, :count, :id) == 1
    assert Repo.aggregate(Source, :count, :id) == 1
  end

  test "source_fixture with user_id creates no extra user" do
    user = user_fixture()

    source = source_fixture(user_id: user.id)

    assert source.user_id == user.id
    assert Repo.aggregate(User, :count, :id) == 1
  end

  test "word_fixture with lexeme_id creates no extra lexeme" do
    lexeme = lexeme_fixture()

    word = word_fixture(lexeme_id: lexeme.id)

    assert word.lexeme_id == lexeme.id
    assert Repo.aggregate(Lexeme, :count, :id) == 1
  end
end
