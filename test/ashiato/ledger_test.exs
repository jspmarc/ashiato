defmodule Ashiato.LedgerTest do
  @moduledoc """
  The ledger's two identities are the whole contract, so these tests are about
  idempotency rather than happy paths:

    * a lexeme is one row per `lemma + reading + part_of_speech`, globally
    * an encounter is one row per `(user, word, page text hash)`

  Both are enforced by unique indexes, and both are easy to get subtly wrong —
  `find_or_create_lexeme` has to survive a race, and `record_encounter` has to
  turn a duplicate into a value rather than an exception.

  The coverage and kanji queries at the bottom are tested the way
  `docs/kanji-review.md` derives them: fixtures whose numbers can be stated by
  hand, over the counting rules that make them honest (R2.8 — unconfirmed and
  discarded encounters count toward nothing).
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures

  alias Ashiato.{Encounters, Ledger, Lexemes, Repo, WordStates}

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

  describe "coverage/2" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "a word met on 3 pages of 5 gives numbers you can state by hand", %{
      user: user,
      source: source
    } do
      pages = for _ <- 1..5, do: page_fixture(user_id: user.id, source_id: source.id)
      word = word_fixture(user_id: user.id)

      pages |> Enum.take(3) |> Enum.each(&record(user, source, word, &1, true))

      assert Ledger.coverage(user.id, source.id) == %{tokens: 3, known_tokens: 0, ratio: 0.0}
    end

    test "a known word and an unknown word on the same pages give 0.5", %{
      user: user,
      source: source
    } do
      pages = for _ <- 1..3, do: page_fixture(user_id: user.id, source_id: source.id)
      known = word_fixture(user_id: user.id, known: true)
      unknown = word_fixture(user_id: user.id)

      Enum.each(pages, &record(user, source, known, &1, true))
      Enum.each(pages, &record(user, source, unknown, &1, true))

      assert Ledger.coverage(user.id, source.id) == %{tokens: 6, known_tokens: 3, ratio: 0.5}
    end

    test "stability at the maturity threshold counts as known, below it does not", %{
      user: user,
      source: source
    } do
      pages = for _ <- 1..4, do: page_fixture(user_id: user.id, source_id: source.id)
      mature = word_fixture(user_id: user.id)
      young = word_fixture(user_id: user.id)

      mature_state(mature, 21.0)
      mature_state(young, 20.0)

      pages |> Enum.take(2) |> Enum.each(&record(user, source, mature, &1, true))
      pages |> Enum.drop(2) |> Enum.each(&record(user, source, young, &1, true))

      assert Ledger.coverage(user.id, source.id) == %{tokens: 4, known_tokens: 2, ratio: 0.5}
    end

    test "unconfirmed and discarded encounters count toward nothing", %{
      user: user,
      source: source
    } do
      page1 = page_fixture(user_id: user.id, source_id: source.id)
      page2 = page_fixture(user_id: user.id, source_id: source.id)
      page3 = page_fixture(user_id: user.id, source_id: source.id)
      word = word_fixture(user_id: user.id)

      {:ok, _} = record(user, source, word, page1, false)
      {:ok, discarded} = record(user, source, word, page2, true)
      discard(discarded)
      {:ok, _} = record(user, source, word, page3, true)

      assert Ledger.coverage(user.id, source.id) == %{tokens: 1, known_tokens: 0, ratio: 0.0}
    end

    test "coverage is per source — another source's encounters do not leak in", %{
      user: user,
      source: source
    } do
      page = page_fixture(user_id: user.id, source_id: source.id)
      word = word_fixture(user_id: user.id)
      {:ok, _} = record(user, source, word, page, true)

      other_source = source_fixture(user_id: user.id)
      other_page = page_fixture(user_id: user.id, source_id: other_source.id)
      {:ok, _} = record(user, other_source, word, other_page, true)

      assert Ledger.coverage(user.id, source.id) == %{tokens: 1, known_tokens: 0, ratio: 0.0}
    end

    test "a source with no confirmed, non-discarded encounters has no coverage", %{
      user: user,
      source: source
    } do
      assert Ledger.coverage(user.id, source.id) == %{tokens: 0, known_tokens: 0, ratio: 0.0}
    end
  end

  describe "kanji_met_words/2" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "returns the met words containing the glyph, with page and day facts", %{
      user: user,
      source: source
    } do
      word = kanji_word(user, "生")
      p1 = page_fixture(user_id: user.id, source_id: source.id)
      p2 = page_fixture(user_id: user.id, source_id: source.id)
      p3 = page_fixture(user_id: user.id, source_id: source.id)

      record_on(user, source, word, p1, true, ~D[2026-11-01])
      record_on(user, source, word, p2, true, ~D[2026-11-01])
      record_on(user, source, word, p3, true, ~D[2026-11-03])

      lexeme_id = word.lexeme_id

      assert [
               %{
                 lexeme_id: ^lexeme_id,
                 lemma: "生",
                 occurrences: 3,
                 days_seen: 2,
                 first_seen: ~D[2026-11-01],
                 last_seen: ~D[2026-11-03]
               }
             ] = Ledger.kanji_met_words(user.id, "生")
    end

    test "the glyph matches inside longer lemmas, ordered by occurrences", %{
      user: user,
      source: source
    } do
      word = kanji_word(user, "生")
      longer = kanji_word(user, "一生懸命")

      Enum.each(1..3, fn _ ->
        page = page_fixture(user_id: user.id, source_id: source.id)
        record_on(user, source, word, page, true, ~D[2026-11-01])
      end)

      page = page_fixture(user_id: user.id, source_id: source.id)
      record_on(user, source, longer, page, true, ~D[2026-11-01])

      assert [%{lemma: "生", occurrences: 3}, %{lemma: "一生懸命", occurrences: 1}] =
               Ledger.kanji_met_words(user.id, "生")
    end

    test "ties on occurrences break by days_seen", %{user: user, source: source} do
      sparse = kanji_word(user, "生もの")
      spaced = kanji_word(user, "生簀")

      p1 = page_fixture(user_id: user.id, source_id: source.id)
      p2 = page_fixture(user_id: user.id, source_id: source.id)
      p3 = page_fixture(user_id: user.id, source_id: source.id)
      p4 = page_fixture(user_id: user.id, source_id: source.id)

      # both on two pages; 生もの crammed into one day, 生簀 spread over two
      record_on(user, source, sparse, p1, true, ~D[2026-11-01])
      record_on(user, source, sparse, p2, true, ~D[2026-11-01])
      record_on(user, source, spaced, p3, true, ~D[2026-11-01])
      record_on(user, source, spaced, p4, true, ~D[2026-11-02])

      assert [%{lemma: "生簀"}, %{lemma: "生もの"}] = Ledger.kanji_met_words(user.id, "生")
    end

    test "unconfirmed and discarded encounters count toward nothing", %{
      user: user,
      source: source
    } do
      word = kanji_word(user, "生")
      p1 = page_fixture(user_id: user.id, source_id: source.id)
      p2 = page_fixture(user_id: user.id, source_id: source.id)
      p3 = page_fixture(user_id: user.id, source_id: source.id)

      record_on(user, source, word, p1, false, ~D[2026-11-01])
      {:ok, discarded} = record_on(user, source, word, p2, true, ~D[2026-11-02])
      discard(discarded)
      record_on(user, source, word, p3, true, ~D[2026-11-03])

      assert [%{occurrences: 1, days_seen: 1}] = Ledger.kanji_met_words(user.id, "生")
    end

    test "a kana-only lemma never matches a kanji glyph", %{user: user, source: source} do
      word = kanji_word(user, "ねこ")
      page = page_fixture(user_id: user.id, source_id: source.id)
      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])

      assert Ledger.kanji_met_words(user.id, "生") == []
    end

    test "words are per user", %{user: user} do
      mine = kanji_word(user, "生")
      my_source = source_fixture(user_id: user.id)
      my_page = page_fixture(user_id: user.id, source_id: my_source.id)
      {:ok, _} = record_on(user, my_source, mine, my_page, true, ~D[2026-11-01])

      other = user_fixture()
      theirs = kanji_word(other, "生")
      other_source = source_fixture(user_id: other.id)
      other_page = page_fixture(user_id: other.id, source_id: other_source.id)
      {:ok, _} = record_on(other, other_source, theirs, other_page, true, ~D[2026-11-01])

      mine_lexeme_id = mine.lexeme_id
      theirs_lexeme_id = theirs.lexeme_id

      assert [%{lexeme_id: ^mine_lexeme_id}] = Ledger.kanji_met_words(user.id, "生")
      assert [%{lexeme_id: ^theirs_lexeme_id}] = Ledger.kanji_met_words(other.id, "生")
    end
  end

  describe "kanji_known?/2" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "false with one word, however mature — two distinct words is load-bearing", %{
      user: user,
      source: source
    } do
      word = kanji_word(user, "生")
      page = page_fixture(user_id: user.id, source_id: source.id)
      unconfirmed_page = page_fixture(user_id: user.id, source_id: source.id)

      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])
      {:ok, _} = record_on(user, source, word, unconfirmed_page, false, ~D[2026-11-02])
      mature_state(word, 30.0)

      refute Ledger.kanji_known?(user.id, "生")
    end

    test "true with two distinct words once one is mature", %{user: user, source: source} do
      word = kanji_word(user, "生")
      other = kanji_word(user, "先生")
      page = page_fixture(user_id: user.id, source_id: source.id)

      # both on the same page: distinct_words counts lexemes, not pages
      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])
      {:ok, _} = record_on(user, source, other, page, true, ~D[2026-11-01])
      mature_state(word, 30.0)

      assert Ledger.kanji_known?(user.id, "生")
    end

    test "false with two distinct words but none mature", %{user: user, source: source} do
      word = kanji_word(user, "生")
      other = kanji_word(user, "先生")
      page = page_fixture(user_id: user.id, source_id: source.id)

      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])
      {:ok, _} = record_on(user, source, other, page, true, ~D[2026-11-01])
      # below the §6.6/§8 maturity default of 21 days
      mature_state(word, 20.0)

      refute Ledger.kanji_known?(user.id, "生")
    end

    test "false when the glyph was never met", %{user: user} do
      refute Ledger.kanji_known?(user.id, "生")
    end
  end

  describe "kanji_map/1" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "per-glyph stats you can state by hand, ordered pages DESC then glyph ASC", %{
      user: user,
      source: source
    } do
      japan = kanji_word(user, "日本")
      today = kanji_word(user, "本日")
      shelf = kanji_word(user, "本棚")

      p1 = page_fixture(user_id: user.id, source_id: source.id)
      p2 = page_fixture(user_id: user.id, source_id: source.id)
      p3 = page_fixture(user_id: user.id, source_id: source.id)

      # 日本 and 本日 share p1, so 本 must credit that page once, not twice.
      # Glyphs of 本棚 (棚) appear too; ties on occurrences break glyph ASC
      # (日 U+65E5 < 本 U+672C by codepoint).
      record_on(user, source, japan, p1, true, ~D[2026-11-01])
      record_on(user, source, japan, p2, true, ~D[2026-11-02])
      record_on(user, source, today, p1, true, ~D[2026-11-01])
      record_on(user, source, shelf, p3, true, ~D[2026-11-05])

      assert [
               %{
                 glyph: "本",
                 # 日本 (p1, p2) + 本日 (p1) + 本棚 (p3): p1 counted once
                 # despite two 本-words on it — 3 pages, 3 days, 3 words
                 occurrences: 3,
                 days_seen: 3,
                 first_seen: ~D[2026-11-01],
                 last_seen: ~D[2026-11-05],
                 distinct_words: 3,
                 has_mature_word: false
               },
               %{
                 glyph: "日",
                 occurrences: 2,
                 days_seen: 2,
                 first_seen: ~D[2026-11-01],
                 last_seen: ~D[2026-11-02],
                 distinct_words: 2,
                 has_mature_word: false
               },
               %{
                 glyph: "棚",
                 occurrences: 1,
                 days_seen: 1,
                 first_seen: ~D[2026-11-05],
                 last_seen: ~D[2026-11-05],
                 distinct_words: 1,
                 has_mature_word: false
               }
             ] = Ledger.kanji_map(user.id)
    end

    test "a lemma with a repeated character credits it once per page", %{
      user: user,
      source: source
    } do
      word = kanji_word(user, "日日")
      p1 = page_fixture(user_id: user.id, source_id: source.id)
      p2 = page_fixture(user_id: user.id, source_id: source.id)

      record_on(user, source, word, p1, true, ~D[2026-11-01])
      record_on(user, source, word, p2, true, ~D[2026-11-01])

      assert [%{glyph: "日", occurrences: 2, days_seen: 1, distinct_words: 1}] =
               Ledger.kanji_map(user.id)
    end

    test "a kana-only lemma contributes no kanji", %{user: user, source: source} do
      word = kanji_word(user, "ねこ")
      page = page_fixture(user_id: user.id, source_id: source.id)
      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])

      assert Ledger.kanji_map(user.id) == []
    end

    test "has_mature_word is true when any word containing the glyph is mature", %{
      user: user,
      source: source
    } do
      word = kanji_word(user, "生")
      other = kanji_word(user, "先生")
      page = page_fixture(user_id: user.id, source_id: source.id)

      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])
      {:ok, _} = record_on(user, source, other, page, true, ~D[2026-11-01])
      mature_state(word, 30.0)
      mature_state(other, 20.0)

      # 先生 contributes 先 as well; the OR-fold over 生's two words decides
      # its has_mature_word, even though 先生 itself is not mature
      assert [
               %{glyph: "先", distinct_words: 1, has_mature_word: false},
               %{glyph: "生", distinct_words: 2, has_mature_word: true}
             ] = Ledger.kanji_map(user.id)
    end

    test "has_mature_word stays false below the maturity threshold", %{user: user, source: source} do
      word = kanji_word(user, "生")
      page = page_fixture(user_id: user.id, source_id: source.id)

      {:ok, _} = record_on(user, source, word, page, true, ~D[2026-11-01])
      mature_state(word, 20.0)

      assert [%{glyph: "生", has_mature_word: false}] = Ledger.kanji_map(user.id)
    end

    test "unconfirmed encounters contribute nothing", %{user: user, source: source} do
      word = kanji_word(user, "生")
      page = page_fixture(user_id: user.id, source_id: source.id)

      {:ok, _} = record_on(user, source, word, page, false, ~D[2026-11-01])

      assert Ledger.kanji_map(user.id) == []
    end

    test "an empty ledger has an empty map", %{user: user} do
      assert Ledger.kanji_map(user.id) == []
    end
  end

  defp record(user, source, word, page, confirmed) do
    record_on(user, source, word, page, confirmed, ~D[2026-11-01])
  end

  defp record_on(user, source, word, page, confirmed, seen_on) do
    Ledger.record_encounter(%{
      user_id: user.id,
      word_id: word.id,
      page_id: page.id,
      source_id: source.id,
      text_hash: page.text_hash,
      crop_key: "crops/#{page.id}.jpg",
      seen_on: seen_on,
      confirmed: confirmed
    })
  end

  # A word whose lexeme has a specific lemma: the kanji queries are all about
  # what the lemma contains, so tests name their lemmas deliberately.
  defp kanji_word(user, lemma) do
    lexeme = lexeme_fixture(lemma: lemma)
    word_fixture(user_id: user.id, lexeme_id: lexeme.id)
  end

  # word_states rows are built directly: word_id is the primary key, and the
  # FSRS scheduler is out of scope here — only the stability column matters.
  # due_at is NOT NULL ("set when the word is introduced"), so a mature word
  # carries a past introduction and review timestamp.
  defp mature_state(word, stability) do
    reviewed_at = ~U[2026-10-01 00:00:00Z]

    Repo.insert!(%WordStates{
      word_id: word.id,
      state: 2,
      stability: stability,
      due_at: reviewed_at,
      last_reviewed_at: reviewed_at
    })
  end

  defp discard(encounter) do
    encounter
    |> Ecto.Changeset.change(discarded_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Repo.update!()
  end
end
