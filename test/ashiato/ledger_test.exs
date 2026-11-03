defmodule Ashiato.LedgerTest do
  @moduledoc """
  The ledger's two identities are the whole contract, so these tests are about
  idempotency rather than happy paths:

    * a lexeme is one row per `lemma + reading + part_of_speech`, globally
    * an encounter is one row per `(user, word, page text hash)`

  Both are enforced by unique indexes, and both are easy to get subtly wrong —
  `find_or_create_lexeme` has to survive a race, and `record_encounter` has to
  turn a duplicate into a value rather than an exception.
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures

  alias Ashiato.{Encounters, Ledger, Lexemes, Pages, Repo}

  describe "find_or_create_lexeme/3" do
    test "creates the lexeme the first time and returns the same row the second" do
      assert {:ok, first} = Ledger.find_or_create_lexeme("食べる", "たべる", "verb")
      assert {:ok, second} = Ledger.find_or_create_lexeme("食べる", "たべる", "verb")

      assert first.id == second.id
      assert Repo.aggregate(Lexemes, :count) == 1
    end

    test "identity includes the reading, so homographs stay apart" do
      # 生(なま) and 生(せい) are different words with the same lemma
      assert {:ok, nama} = Ledger.find_or_create_lexeme("生", "なま", "noun")
      assert {:ok, sei} = Ledger.find_or_create_lexeme("生", "せい", "noun")

      refute nama.id == sei.id
      assert Repo.aggregate(Lexemes, :count) == 2
    end

    test "a nil reading is normalised to an empty string" do
      # NULL is distinct in a unique index, so storing nil would create a new
      # row on every call. The database default is "" for exactly this reason.
      assert {:ok, first} = Ledger.find_or_create_lexeme("ねこ", nil, "noun")
      assert {:ok, second} = Ledger.find_or_create_lexeme("ねこ", nil, "noun")

      assert first.id == second.id
      assert first.reading == ""
      assert Repo.aggregate(Lexemes, :count) == 1
    end

    test "concurrent callers end up with one row" do
      results =
        1..5
        |> Task.async_stream(
          fn _ -> Ledger.find_or_create_lexeme("同時", "どうじ", "noun") end,
          max_concurrency: 5,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %Lexemes{}}, &1))

      assert results |> Enum.map(fn {:ok, lexeme} -> lexeme.id end) |> Enum.uniq() |> length() ==
               1

      assert Repo.aggregate(Lexemes, :count) == 1
    end
  end

  describe "record_encounter/1" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)
      page = page_fixture(user_id: user.id, source_id: source.id)
      word = word_fixture(user_id: user.id)

      {:ok,
       %{
         user: user,
         source: source,
         page: page,
         word: word,
         attrs: %{
           user_id: user.id,
           word_id: word.id,
           page_id: page.id,
           source_id: source.id,
           text_hash: page.text_hash,
           crop_key: "crops/1.jpg",
           seen_on: ~D[2026-11-01]
         }
       }}
    end

    test "records the first sighting", %{attrs: attrs} do
      assert {:ok, encounter} = Ledger.record_encounter(attrs)
      assert encounter.id
      assert Repo.aggregate(Encounters, :count) == 1
    end

    test "the same sighting twice is a no-op, not an exception", %{attrs: attrs} do
      assert {:ok, first} = Ledger.record_encounter(attrs)
      assert {:ok, second} = Ledger.record_encounter(attrs)

      assert first.id == second.id
      assert Repo.aggregate(Encounters, :count) == 1
    end

    test "the same word on a different page is a second sighting", %{attrs: attrs, user: user} do
      {:ok, _} = Ledger.record_encounter(attrs)

      other_page = page_fixture(user_id: user.id, source_id: attrs.source_id)
      second = %{attrs | page_id: other_page.id, text_hash: other_page.text_hash}

      assert {:ok, _} = Ledger.record_encounter(second)
      assert Repo.aggregate(Encounters, :count) == 2
    end
  end

  describe "chrome_ratio/2" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)
      word = word_fixture(user_id: user.id)

      {:ok, %{user: user, source: source, word: word}}
    end

    test "a source with no pages has no ratio", %{user: user, source: source} do
      assert Ledger.chrome_ratio(user.id, source.id) == %{}
    end

    test "unconfirmed encounters count toward nothing", %{user: user, source: source, word: word} do
      page = page_fixture(user_id: user.id, source_id: source.id)
      {:ok, _} = record(user, source, word, page, false)

      assert Ledger.chrome_ratio(user.id, source.id) == %{}
    end

    test "the ratio is the fraction of the source's pages carrying the word",
         %{user: user, source: source, word: word} do
      pages = for _ <- 1..4, do: page_fixture(user_id: user.id, source_id: source.id)

      # on two of the four pages
      pages |> Enum.take(2) |> Enum.each(&record(user, source, word, &1, true))

      assert Ledger.chrome_ratio(user.id, source.id) == %{word.id => 0.5}
    end

    test "a word on every page is 1.0", %{user: user, source: source, word: word} do
      pages = for _ <- 1..3, do: page_fixture(user_id: user.id, source_id: source.id)
      Enum.each(pages, &record(user, source, word, &1, true))

      assert Ledger.chrome_ratio(user.id, source.id) == %{word.id => 1.0}
    end
  end

  defp record(user, source, word, page, confirmed) do
    Ledger.record_encounter(%{
      user_id: user.id,
      word_id: word.id,
      page_id: page.id,
      source_id: source.id,
      text_hash: page.text_hash,
      crop_key: "crops/#{page.id}.jpg",
      seen_on: ~D[2026-11-01],
      confirmed: confirmed
    })
  end

  # The interesting behaviour is concurrency: a stale fenced write is discarded
  # rather than raising, and pages only move forward.
  describe "page lifecycle and revision fencing" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "create_page/1 builds an uploaded page and sets user_id without casting",
         %{user: user, source: source} do
      n = System.unique_integer([:positive])

      assert {:ok, page} =
               Ledger.create_page(%{
                 user_id: user.id,
                 source_id: source.id,
                 image_key: "pages/#{n}.jpg",
                 text_hash: "hash-#{n}"
               })

      assert page.status == :uploaded
      assert page.revision == 1
      assert page.user_id == user.id
    end

    test "create_page/1 rejects a duplicate (user_id, text_hash) as an error, not a raise",
         %{user: user, source: source} do
      n = System.unique_integer([:positive])

      attrs = %{
        user_id: user.id,
        source_id: source.id,
        image_key: "pages/#{n}.jpg",
        text_hash: "hash-#{n}"
      }

      assert {:ok, _} = Ledger.create_page(attrs)
      assert {:error, changeset} = Ledger.create_page(attrs)
      assert "has already been taken" in errors_on(changeset).user_id
    end

    test "accept_text/2 sets accepted_text and bumps revision in one write",
         %{user: user, source: source} do
      page = make_page(user, source)
      assert {:ok, page} = Ledger.accept_text(page, "冷たいな！？")

      assert page.accepted_text == "冷たいな！？"
      assert page.revision == 2
    end

    test "a correction with a stale revision is rejected as :superseded",
         %{user: user, source: source} do
      page = make_page(user, source)
      stale = page

      assert {:ok, _} = Ledger.accept_text(page, "正しく読めた")
      assert {:error, :superseded} = Ledger.accept_text(stale, "別の修正")
      assert %{accepted_text: "正しく読めた", revision: 2} = Repo.get!(Pages, page.id)
    end

    test "a matching revision write succeeds and does not bump revision",
         %{user: user, source: source} do
      page = make_page(user, source)
      assert {:ok, page} = Ledger.finish_page(page, :detecting)

      assert page.status == :detecting
      assert page.revision == 1
    end

    test "a stale revision write is discarded as :superseded", %{user: user, source: source} do
      page = make_page(user, source)

      # a correction landed while the job was working: revision bumped
      assert {:ok, _} = Ledger.accept_text(page, "正しく読めた")

      # the job still carries the page it read at the start (revision 1)
      assert {:error, :superseded} = Ledger.finish_page(page, :detecting)
    end

    test "backward transitions are rejected", %{user: user, source: source} do
      page = make_page(user, source)
      assert {:ok, page} = Ledger.transition(page, :detecting)
      assert {:ok, page} = Ledger.transition(page, :text_ready)

      assert {:error, :invalid_transition} = Ledger.transition(page, :uploaded)
      assert {:error, :invalid_transition} = Ledger.transition(page, :detecting)

      assert {:ok, page} = Ledger.transition(page, :translating)
      assert {:error, :invalid_transition} = Ledger.transition(page, :text_ready)

      assert {:ok, page} = Ledger.transition(page, :ready)
      assert {:error, :invalid_transition} = Ledger.transition(page, :failed)
    end

    test ":failed is reachable from every non-terminal state", %{user: user, source: source} do
      for status <- [:uploaded, :detecting, :text_ready, :translating] do
        page = make_page(user, source, status: status)
        assert {:ok, page} = Ledger.transition(page, :failed)
        assert page.status == :failed
      end
    end
  end

  defp make_page(user, source, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    attrs = Map.new(attrs)

    {:ok, page} =
      Ledger.create_page(
        Map.merge(
          %{
            user_id: user.id,
            source_id: source.id,
            image_key: "pages/#{n}.jpg",
            text_hash: "hash-#{n}",
            status: :uploaded
          },
          attrs
        )
      )

    page
  end
end
