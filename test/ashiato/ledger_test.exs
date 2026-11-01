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
  exception. The review tests pin the log/state split: append-only events, one
  rebuildable state row, and band caps that shorten the interval but never the
  stability.
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures

  alias Ashiato.{Encounters, Ledger, Lexemes, Repo, ReviewEvents, Srs, WordStates}

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

  describe "review/2 and review/3" do
    setup do
      user = user_fixture()
      word = word_fixture(user_id: user.id)

      {:ok, %{user: user, word: word}}
    end

    test "review/2 delegates to review/3 with now", %{word: word} do
      assert {:ok, %WordStates{} = state} = Ledger.review(word.id, 3)
      assert state.word_id == word.id
      assert state.state == 2
      assert length(Repo.all(ReviewEvents)) == 1
    end

    test "appends exactly one review_events row per grade", %{word: word} do
      day1 = ~U[2026-11-01 12:00:00.000000Z]
      day2 = ~U[2026-11-02 12:00:00.000000Z]

      assert {:ok, _} = Ledger.review(word.id, 3, day1)
      assert Repo.aggregate(ReviewEvents, :count) == 1

      assert {:ok, _} = Ledger.review(word.id, 4, day2)

      # exactly one row per grade, in reviewed_at order
      events = Repo.all(from re in ReviewEvents, order_by: re.reviewed_at)
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

      assert Repo.aggregate(WordStates, :count) == 1
      assert state1.word_id == word.id
      assert state1.state == 2
      assert state1.reps == 1
      assert state1.lapses == 0
      # S0(3) = w2, D0(3) = w4; the interval is round(3.7145) = 4 days,
      # uncapped because the word has no confirmed encounters yet
      assert state1.stability == 3.7145
      assert state1.difficulty == 5.1618
      assert state1.last_reviewed_at == day1
      assert state1.due_at == DateTime.add(day1, 4 * 86_400, :second)

      day2 = ~U[2026-11-02 12:00:00Z]
      assert {:ok, state2} = Ledger.review(word.id, 4, day2)
      # the upsert replaced the row, it did not add one
      assert Repo.aggregate(WordStates, :count) == 1

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

    test "a lapse from review writes interval_after 0 and due_at now", %{word: word} do
      day1 = ~U[2026-11-01 12:00:00.000000Z]
      day2 = ~U[2026-11-11 12:00:00Z]

      assert {:ok, review_state} = Ledger.review(word.id, 3, day1)
      assert {:ok, lapsed} = Ledger.review(word.id, 1, day2)

      assert lapsed.state == 3
      assert lapsed.lapses == 1
      assert lapsed.reps == 2
      # interval 0: due the moment the lapse happened
      assert DateTime.truncate(lapsed.due_at, :second) == day2
      assert lapsed.stability < review_state.stability

      assert [lapse_event] =
               Repo.all(from re in ReviewEvents, where: re.word_id == ^word.id and re.grade == 1)

      assert lapse_event.interval_after == 0
      assert same_instant?(lapse_event.reviewed_at, day2)
    end

    test "an unknown word or an out-of-range grade is an error, not a raise", %{word: word} do
      assert {:error, %Ecto.Changeset{}} = Ledger.review(999_999, 3, ~U[2026-11-01 12:00:00Z])

      assert {:error, %Ecto.Changeset{errors: errors}} =
               Ledger.review(word.id, 5, ~U[2026-11-01 12:00:00Z])

      assert errors[:grade]
      # nothing was written
      assert Repo.aggregate(ReviewEvents, :count) == 0
      assert Repo.aggregate(WordStates, :count) == 0
    end

    test "the occurrence band caps the interval, never the stability", %{user: user} do
      source = source_fixture(user_id: user.id)
      day0 = ~U[2026-06-01 12:00:00Z]
      day1 = DateTime.add(day0, 30 * 86_400, :second)
      day2 = DateTime.add(day0, 60 * 86_400, :second)

      # -- 3 confirmed encounters: the 240-day band ---------------------------
      word = word_fixture(user_id: user.id)

      for _ <- 1..3 do
        page = page_fixture(user_id: user.id, source_id: source.id)
        assert {:ok, _} = record(user, source, word, page, true)
      end

      assert {:ok, state1} = Ledger.review(word.id, 4, day0)

      # S0(4) = 13.8206 days -> round(13.8206) = 14, far below the 240-day cap
      [event1] = Repo.all(from re in ReviewEvents, where: re.word_id == ^word.id)
      assert event1.interval_after == 14
      assert state1.due_at == DateTime.add(day0, 14 * 86_400, :second)

      # FSRS-4.5 clamps stability at Smax = 100 days, so the uncapped interval
      # can never exceed 100 and the 240-day band never binds: it must leave
      # every reachable interval alone
      assert {:ok, _state2} = Ledger.review(word.id, 4, day1)
      %{interval_days: uncapped} = Srs.grade(state1, 4, day1)

      [event2] =
        Repo.all(
          from re in ReviewEvents, where: re.word_id == ^word.id and re.reviewed_at == ^day1
        )

      assert event2.interval_after == uncapped

      # -- 20 confirmed encounters: the 60-day band bites ----------------------
      heavy = word_fixture(user_id: user.id)

      for _ <- 1..20 do
        page = page_fixture(user_id: user.id, source_id: source.id)
        assert {:ok, _} = record(user, source, heavy, page, true)
      end

      assert {:ok, _heavy1} = Ledger.review(heavy.id, 4, day0)
      assert {:ok, _heavy2} = Ledger.review(heavy.id, 4, day1)
      assert {:ok, heavy3} = Ledger.review(heavy.id, 4, day2)

      # stability saturates at Smax = 100, so the uncapped interval is 100
      # days — past the 60-day cap, which must now bite
      assert heavy3.stability == 100.0
      assert heavy3.due_at == DateTime.add(day2, 60 * 86_400, :second)

      [heavy_event3] =
        Repo.all(
          from re in ReviewEvents, where: re.word_id == ^heavy.id and re.reviewed_at == ^day2
        )

      assert heavy_event3.interval_after == 60

      # -- 1 confirmed encounter: uncapped, the FSRS interval passes through --
      single = word_fixture(user_id: user.id)

      page = page_fixture(user_id: user.id, source_id: source.id)
      assert {:ok, _} = record(user, source, single, page, true)

      assert {:ok, _} = Ledger.review(single.id, 4, day0)
      assert {:ok, _} = Ledger.review(single.id, 4, day1)
      assert {:ok, single3} = Ledger.review(single.id, 4, day2)

      # same review schedule as the heavy word, but no cap applies: stability
      # saturates at Smax = 100 and the interval stays the uncapped 100 days
      assert single3.stability == 100.0
      assert single3.due_at == DateTime.add(day2, 100 * 86_400, :second)

      [single_event3] =
        Repo.all(
          from re in ReviewEvents, where: re.word_id == ^single.id and re.reviewed_at == ^day2
        )

      assert single_event3.interval_after == 100
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

  # :utc_datetime and :utc_datetime_usec load back with different microsecond
  # precisions ({0, 0} vs {0, 6}), so compare the instant, not the struct
  defp same_instant?(a, b), do: DateTime.compare(a, b) == :eq

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
end
