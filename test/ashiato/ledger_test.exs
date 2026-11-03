defmodule Ashiato.LedgerTest do
  @moduledoc """
  The ledger's identities are the foundation, and the review pipeline sits on
  top of them:

    * a lexeme is one row per `lemma + reading + part_of_speech`, globally
    * an encounter is one row per `(user, word, page text hash)`
    * a review appends exactly one log row and upserts the one state row

  Both identities are enforced by unique indexes, and both are easy to get
  subtly wrong — `find_or_create_lexeme` has to survive a race, and
  `record_encounter` has to turn a duplicate into a value rather than an
  exception. The review tests pin the log/state split: append-only events and
  one rebuildable state row.

  They also cover the introduction threshold and the derived `chrome_like` flag,
  including its hand-off with suspensions, and the page lifecycle with its
  revision fencing.

  The coverage and kanji queries at the bottom are tested the way
  `docs/kanji-review.md` derives them: fixtures whose numbers can be stated by
  hand, over the counting rules that make them honest (R2.8 — unconfirmed and
  discarded encounters count toward nothing).
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures

  alias Ashiato.{Ledger, Repo, Srs}
  alias Ashiato.Schemas.{Encounter, Lexeme, Page, ReviewEvent, WordState}

  describe "find_or_create_lexeme/3" do
    test "creates the lexeme the first time and returns the same row the second" do
      assert {:ok, first} = Ledger.find_or_create_lexeme("食べる", "たべる", "verb")
      assert {:ok, second} = Ledger.find_or_create_lexeme("食べる", "たべる", "verb")

      assert first.id == second.id
      assert Repo.aggregate(Lexeme, :count) == 1
    end

    test "identity includes the reading, so homographs stay apart" do
      # 生(なま) and 生(せい) are different words with the same lemma
      assert {:ok, nama} = Ledger.find_or_create_lexeme("生", "なま", "noun")
      assert {:ok, sei} = Ledger.find_or_create_lexeme("生", "せい", "noun")

      refute nama.id == sei.id
      assert Repo.aggregate(Lexeme, :count) == 2
    end

    test "a nil reading is normalised to an empty string" do
      # NULL is distinct in a unique index, so nil would insert a new row every call.
      assert {:ok, first} = Ledger.find_or_create_lexeme("ねこ", nil, "noun")
      assert {:ok, second} = Ledger.find_or_create_lexeme("ねこ", nil, "noun")

      assert first.id == second.id
      assert first.reading == ""
      assert Repo.aggregate(Lexeme, :count) == 1
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

      assert Enum.all?(results, &match?({:ok, %Lexeme{}}, &1))

      assert results |> Enum.map(fn {:ok, lexeme} -> lexeme.id end) |> Enum.uniq() |> length() ==
               1

      assert Repo.aggregate(Lexeme, :count) == 1
    end
  end

  describe "review/2 and review/3" do
    setup do
      user = user_fixture()
      word = word_fixture(user_id: user.id)

      {:ok, %{user: user, word: word}}
    end

    test "review/2 delegates to review/3 with now", %{word: word} do
      assert {:ok, %WordState{} = state} = Ledger.review(word.id, 3)
      assert state.word_id == word.id
      assert state.state == :review
      assert length(Repo.all(ReviewEvent)) == 1
    end

    test "appends exactly one review_events row per grade", %{word: word} do
      day1 = ~U[2026-11-01 12:00:00.000000Z]
      day2 = ~U[2026-11-02 12:00:00.000000Z]

      assert {:ok, _} = Ledger.review(word.id, 3, day1)
      assert Repo.aggregate(ReviewEvent, :count) == 1

      assert {:ok, _} = Ledger.review(word.id, 4, day2)

      # exactly one row per grade, in reviewed_at order
      events = Repo.all(from re in ReviewEvent, order_by: re.reviewed_at)
      assert [first, second] = events

      assert first.grade == 3
      # :utc_datetime_usec loads back with usec precision ({0, 6}), so compare
      # the instant, not the struct
      assert same_instant?(first.reviewed_at, day1)
      # every review yields a new state: never "not computed"
      assert first.stability_after
      assert first.difficulty_after
      assert first.interval_after in 0..36500

      assert second.grade == 4
      assert same_instant?(second.reviewed_at, day2)
      assert second.stability_after
      assert second.difficulty_after
      assert second.interval_after in 0..36500
    end

    test "upserts the single word_states row for the word", %{word: word} do
      day1 = ~U[2026-11-01 12:00:00Z]
      assert {:ok, state1} = Ledger.review(word.id, 3, day1)

      assert Repo.aggregate(WordState, :count) == 1
      assert state1.word_id == word.id
      assert state1.state == :review
      assert state1.reps == 1
      assert state1.lapses == 0
      # S0(3) = w2; D0(3) = w4 - e^(2 * w5) + 1; the interval is
      # round(2.3065) = 2 days
      assert state1.stability == 2.3065
      assert state1.difficulty == 2.118103970459015
      assert state1.last_reviewed_at == day1
      assert state1.due_at == DateTime.add(day1, 2 * 86_400, :second)

      day2 = ~U[2026-11-02 12:00:00Z]
      assert {:ok, state2} = Ledger.review(word.id, 4, day2)
      # the upsert replaced the row, it did not add one
      assert Repo.aggregate(WordState, :count) == 1

      # and the row mirrors the FSRS result for the state review 1 left behind
      %{state: expected, interval_days: interval} = Srs.grade(state1, 4, day2)

      assert state2.state == expected.state
      assert state2.stability == expected.stability
      assert state2.difficulty == expected.difficulty
      assert state2.reps == expected.reps
      assert state2.lapses == expected.lapses
      assert state2.last_reviewed_at == day2
      assert state2.due_at == DateTime.add(day2, interval * 86_400, :second)
    end

    test "a first lapse schedules the 4-hour remedial step", %{word: word} do
      day1 = ~U[2026-11-01 12:00:00.000000Z]
      day2 = ~U[2026-11-11 12:00:00Z]

      assert {:ok, review_state} = Ledger.review(word.id, 3, day1)
      assert {:ok, lapsed} = Ledger.review(word.id, 1, day2)

      %{state: expected} = Srs.grade(review_state, 1, day2)

      assert lapsed.state == :relearning
      assert lapsed.lapses == 1
      assert lapsed.reps == 2
      assert lapsed.failure_streak == 1
      assert lapsed.stability == expected.stability
      assert lapsed.due_at == DateTime.add(day2, 4, :hour)

      assert [lapse_event] =
               Repo.all(from re in ReviewEvent, where: re.word_id == ^word.id and re.grade == 1)

      assert lapse_event.interval_after == 0
      assert same_instant?(lapse_event.reviewed_at, day2)
    end

    test "consecutive agains escalate into ghost steps, and a pass clears the streak", %{
      word: word
    } do
      t0 = ~U[2026-11-01 12:00:00Z]
      assert {:ok, _} = Ledger.review(word.id, 3, t0)

      failure1 = DateTime.add(t0, 86_400, :second)
      assert {:ok, state1} = Ledger.review(word.id, 1, failure1)
      assert state1.failure_streak == 1
      assert state1.due_at == DateTime.add(failure1, 4, :hour)

      failure2 = DateTime.add(failure1, 4 * 3_600, :second)
      assert {:ok, state2} = Ledger.review(word.id, 1, failure2)
      assert state2.failure_streak == 2
      assert state2.due_at == DateTime.add(failure2, 12, :hour)

      failure3 = DateTime.add(failure2, 12 * 3_600, :second)
      assert {:ok, state3} = Ledger.review(word.id, 1, failure3)
      assert state3.failure_streak == 3
      assert state3.due_at == DateTime.add(failure3, 24, :hour)

      failure4 = DateTime.add(failure3, 24 * 3_600, :second)
      assert {:ok, state4} = Ledger.review(word.id, 1, failure4)
      assert state4.failure_streak == 4
      assert state4.due_at == DateTime.add(failure4, 24, :hour)

      passed_at = DateTime.add(failure4, 24 * 3_600, :second)
      assert {:ok, passed} = Ledger.review(word.id, 3, passed_at)
      assert passed.failure_streak == 0
      assert passed.state == :review

      [pass_event] =
        Repo.all(
          from re in ReviewEvent, where: re.word_id == ^word.id and re.reviewed_at == ^passed_at
        )

      assert pass_event.interval_after > 0
      assert passed.due_at == DateTime.add(passed_at, pass_event.interval_after * 86_400, :second)

      failure_events =
        Repo.all(
          from re in ReviewEvent,
            where: re.word_id == ^word.id and re.grade == 1,
            order_by: re.reviewed_at
        )

      assert Enum.map(failure_events, & &1.interval_after) == [0, 0, 0, 0]
    end

    test "an unknown word or an out-of-range grade is an error, not a raise", %{word: word} do
      assert {:error, %Ecto.Changeset{}} = Ledger.review(999_999, 3, ~U[2026-11-01 12:00:00Z])

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Ledger.review(word.id, 5, ~U[2026-11-01 12:00:00Z])

      assert errors[:grade]
      # nothing was written
      assert Repo.aggregate(ReviewEvent, :count) == 0
      assert Repo.aggregate(WordState, :count) == 0
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
      assert Repo.aggregate(Encounter, :count) == 1
    end

    test "the same sighting twice is a no-op, not an exception", %{attrs: attrs} do
      assert {:ok, first} = Ledger.record_encounter(attrs)
      assert {:ok, second} = Ledger.record_encounter(attrs)

      assert first.id == second.id
      assert Repo.aggregate(Encounter, :count) == 1
    end

    test "the same word on a different page is a second sighting", %{attrs: attrs, user: user} do
      {:ok, _} = Ledger.record_encounter(attrs)

      other_page = page_fixture(user_id: user.id, source_id: attrs.source_id)
      second = %{attrs | page_id: other_page.id, text_hash: other_page.text_hash}

      assert {:ok, _} = Ledger.record_encounter(second)
      assert Repo.aggregate(Encounter, :count) == 2
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

  # :utc_datetime and :utc_datetime_usec load back with different microsecond
  # precisions ({0, 0} vs {0, 6}), so compare the instant, not the struct
  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

  describe "introduce_words/3" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "a word below the threshold is not introduced", %{user: user, source: source} do
      %{lexeme: lexeme} = met_word(user, source, 1)

      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id])
      assert Repo.aggregate(WordState, :count) == 0
    end

    test "a word at the threshold is introduced, due immediately and new",
         %{user: user, source: source} do
      %{lexeme: lexeme, word: word} = met_word(user, source)

      assert {:ok, [introduced]} = Ledger.introduce_words(user.id, [lexeme.id])
      assert introduced.id == word.id

      assert [%WordState{} = state] = Repo.all(WordState)
      assert state.word_id == word.id
      assert state.state == :new
      assert %DateTime{} = state.due_at
    end

    test "unconfirmed and discarded encounters do not count toward the threshold",
         %{user: user, source: source} do
      lexeme = lexeme_fixture()
      word = word_fixture(user_id: user.id, lexeme_id: lexeme.id)

      [met, unconfirmed, discarded] =
        for _ <- 1..3, do: page_fixture(user_id: user.id, source_id: source.id)

      record(user, source, word, met, true)
      # unconfirmed and discarded: neither counts toward the threshold
      record(user, source, word, unconfirmed, false)

      record(user, source, word, discarded, true, %{
        discarded_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id])
      assert Repo.aggregate(WordState, :count) == 0
    end

    test "force: true bypasses the threshold", %{user: user, source: source} do
      %{lexeme: lexeme} = met_word(user, source, 1)

      assert {:ok, [_introduced]} = Ledger.introduce_words(user.id, [lexeme.id], force: true)
      assert Repo.aggregate(WordState, :count) == 1
    end

    test "force bypasses only the threshold, not the other filters",
         %{user: user, source: source} do
      known = met_word(user, source, 1)
      Repo.update!(change(known.word, known: true))

      chrome = met_word(user, source, 1)
      Repo.update!(change(chrome.word, chrome_like: true))

      suspended = met_word(user, source, 1)
      assert {:ok, _} = Ledger.mark_suspended(user.id, suspended.lexeme.id, :manual)

      lexeme_ids = [known.lexeme.id, chrome.lexeme.id, suspended.lexeme.id]

      assert {:ok, []} = Ledger.introduce_words(user.id, lexeme_ids, force: true)
      assert Repo.aggregate(WordState, :count) == 0
    end

    test "the threshold is overridable per call", %{user: user, source: source} do
      %{lexeme: lexeme} = met_word(user, source, 3)

      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id], min_encounters: 4)
      assert {:ok, [_]} = Ledger.introduce_words(user.id, [lexeme.id], min_encounters: 3)
    end

    test "a word already introduced is not duplicated", %{user: user, source: source} do
      %{lexeme: lexeme} = met_word(user, source)

      assert {:ok, [_first]} = Ledger.introduce_words(user.id, [lexeme.id])

      # a repeat call and a duplicated id both see the existing word_states row
      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id])
      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id, lexeme.id])

      assert Repo.aggregate(WordState, :count) == 1
    end

    test "a lexeme with no words row is skipped unless forced", %{user: user} do
      lexeme = lexeme_fixture()

      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id])

      assert {:ok, [minted]} = Ledger.introduce_words(user.id, [lexeme.id], force: true)
      assert minted.lexeme_id == lexeme.id
      assert Repo.aggregate(WordState, :count) == 1
    end

    test "returns only the introduced words, in the order given",
         %{user: user, source: source} do
      below = met_word(user, source, 1)
      first = met_word(user, source)
      second = met_word(user, source)

      ids = [below.lexeme.id, second.lexeme.id, first.lexeme.id]
      assert {:ok, [w1, w2]} = Ledger.introduce_words(user.id, ids)

      assert w1.id == second.word.id
      assert w2.id == first.word.id
    end
  end

  describe "mark_known/2" do
    test "marks the user's copy of the lexeme known" do
      user = user_fixture()
      word = word_fixture(user_id: user.id)

      assert {:ok, known} = Ledger.mark_known(user.id, word.lexeme_id)
      assert known.known
      assert Repo.reload!(word).known
    end

    test "a lexeme the user has no words row for is an error" do
      user = user_fixture()
      lexeme = lexeme_fixture()

      assert {:error, :not_found} = Ledger.mark_known(user.id, lexeme.id)
    end
  end

  describe "mark_suspended/3" do
    setup do
      user = user_fixture()
      word = word_fixture(user_id: user.id)

      {:ok, %{user: user, word: word}}
    end

    test "suspends with the given reason", %{user: user, word: word} do
      assert {:ok, suspended} = Ledger.mark_suspended(user.id, word.lexeme_id, :manual)
      assert suspended.suspended
      assert suspended.suspended_reason == :manual
    end

    test "mastering also stamps mastered_at", %{user: user, word: word} do
      assert {:ok, mastered} = Ledger.mark_suspended(user.id, word.lexeme_id, :mastered)
      assert %DateTime{} = mastered.mastered_at
    end

    test "the reason must come from the Ecto.Enum", %{user: user, word: word} do
      assert {:error, changeset} = Ledger.mark_suspended(user.id, word.lexeme_id, :bogus)
      assert %{suspended_reason: ["is invalid"]} = errors_on(changeset)

      refute Repo.reload!(word).suspended
    end

    test "suspending again never clobbers an existing reason", %{user: user, word: word} do
      assert {:ok, first} = Ledger.mark_suspended(user.id, word.lexeme_id, :manual)
      assert {:ok, second} = Ledger.mark_suspended(user.id, word.lexeme_id, :chrome)

      # the manual reason survives, so clearing the chrome flag cannot wipe it
      assert first.suspended_reason == :manual
      assert second.suspended_reason == :manual
    end

    test "a lexeme the user has no words row for is an error" do
      user = user_fixture()
      lexeme = lexeme_fixture()

      assert {:error, :not_found} = Ledger.mark_suspended(user.id, lexeme.id, :manual)
    end
  end

  describe "update_chrome_like/1" do
    setup do
      {:ok, %{user: user_fixture()}}
    end

    test "flags a word chrome-like in every source it appears in", %{user: user} do
      %{word: word} = chrome_word(user)

      assert {:ok, [flagged]} = Ledger.update_chrome_like(user.id)
      assert flagged.id == word.id
      assert Repo.reload!(word).chrome_like
    end

    test "a word chrome in one game but rare in a manga stays unflagged", %{user: user} do
      game = source_fixture(user_id: user.id)
      game_pages = for _ <- 1..2, do: page_fixture(user_id: user.id, source_id: game.id)

      # both words are on every game page; only one of them is also met in a manga
      hud = word_fixture(user_id: user.id)
      real = word_fixture(user_id: user.id)
      Enum.each(game_pages, &record(user, game, hud, &1, true))
      Enum.each(game_pages, &record(user, game, real, &1, true))

      manga = source_fixture(user_id: user.id, kind: :manga)
      manga_pages = for _ <- 1..3, do: page_fixture(user_id: user.id, source_id: manga.id)
      Enum.each(Enum.take(manga_pages, 1), &record(user, manga, real, &1, true))

      # HUD word: chrome in its only source. Real word: not chrome in every source.
      assert {:ok, [flagged]} = Ledger.update_chrome_like(user.id)
      assert flagged.id == hud.id
      refute Repo.reload!(real).chrome_like
    end

    test "when the flag lands, an existing card is suspended with reason chrome",
         %{user: user} do
      %{lexeme: lexeme, word: word} = chrome_word(user)

      assert {:ok, [_]} = Ledger.introduce_words(user.id, [lexeme.id])
      assert {:ok, [_]} = Ledger.update_chrome_like(user.id)

      reloaded = Repo.reload!(word)
      assert reloaded.chrome_like
      assert reloaded.suspended and reloaded.suspended_reason == :chrome

      # suspended, never deleted: the card and its history survive
      assert Repo.get!(WordState, word.id)
    end

    test "when the flag lands on a suspended word, its reason is not clobbered", %{user: user} do
      %{lexeme: lexeme, word: word} = chrome_word(user)

      assert {:ok, _} = Ledger.mark_suspended(user.id, lexeme.id, :manual)
      assert {:ok, [_flagged]} = Ledger.update_chrome_like(user.id)

      reloaded = Repo.reload!(word)
      assert reloaded.chrome_like
      assert reloaded.suspended and reloaded.suspended_reason == :manual
    end

    test "clearing the flag un-suspends a chrome suspension", %{user: user} do
      %{word: word} = chrome_word(user)

      assert {:ok, [_]} = Ledger.update_chrome_like(user.id)
      assert Repo.reload!(word).suspended

      # no longer chrome-like everywhere: met on one of two manga pages
      meet_rarely_elsewhere(user, word)
      assert {:ok, []} = Ledger.update_chrome_like(user.id)

      reloaded = Repo.reload!(word)
      refute reloaded.chrome_like
      refute reloaded.suspended
      assert reloaded.suspended_reason == nil
    end

    for reason <- [:manual, :mastered, :leech] do
      test "clearing the flag leaves a #{reason} suspension intact", %{user: user} do
        reason = unquote(reason)
        %{lexeme: lexeme, word: word} = chrome_word(user)

        # the flag lands on an already-suspended word without touching it…
        assert {:ok, _} = Ledger.mark_suspended(user.id, lexeme.id, reason)
        assert {:ok, [_]} = Ledger.update_chrome_like(user.id)

        reloaded = Repo.reload!(word)
        assert reloaded.chrome_like
        assert reloaded.suspended and reloaded.suspended_reason == reason

        # …and clearing the flag leaves the suspension alone too
        meet_rarely_elsewhere(user, word)
        assert {:ok, []} = Ledger.update_chrome_like(user.id)

        reloaded = Repo.reload!(word)
        refute reloaded.chrome_like
        assert reloaded.suspended and reloaded.suspended_reason == reason
      end
    end
  end

  # A word met on `n` distinct confirmed pages of one source.
  defp met_word(user, source, n \\ 2) do
    lexeme = lexeme_fixture()
    word = word_fixture(user_id: user.id, lexeme_id: lexeme.id)

    for _ <- 1..n do
      page = page_fixture(user_id: user.id, source_id: source.id)
      record(user, source, word, page, true)
    end

    %{lexeme: lexeme, word: word}
  end

  # A word on every page of a fresh source: chrome-like in its only source.
  defp chrome_word(user) do
    source = source_fixture(user_id: user.id)
    lexeme = lexeme_fixture()
    word = word_fixture(user_id: user.id, lexeme_id: lexeme.id)
    pages = for _ <- 1..2, do: page_fixture(user_id: user.id, source_id: source.id)
    Enum.each(pages, &record(user, source, word, &1, true))

    %{lexeme: lexeme, word: word, source: source}
  end

  # Meets `word` on one of two manga pages: exactly half does not clear the
  # threshold, so the word stops being chrome-like in every source.
  defp meet_rarely_elsewhere(user, word) do
    manga = source_fixture(user_id: user.id, kind: :manga)
    [met, _unmet] = for _ <- 1..2, do: page_fixture(user_id: user.id, source_id: manga.id)
    record(user, manga, word, met, true)

    manga
  end

  defp record(user, source, word, page, confirmed, opts \\ %{}) do
    attrs =
      Map.merge(
        %{
          user_id: user.id,
          word_id: word.id,
          page_id: page.id,
          source_id: source.id,
          text_hash: page.text_hash,
          crop_key: "crops/#{page.id}.jpg",
          seen_on: ~D[2026-11-01],
          confirmed: confirmed
        },
        opts
      )

    Ledger.record_encounter(attrs)
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
      assert %{accepted_text: "正しく読めた", revision: 2} = Repo.get!(Page, page.id)
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

    Repo.insert!(%WordState{
      word_id: word.id,
      state: :review,
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
