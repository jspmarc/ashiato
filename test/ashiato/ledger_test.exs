defmodule Ashiato.LedgerTest do
  @moduledoc """
  The ledger's two identities are the whole contract, so these tests are about
  idempotency rather than happy paths: one lexeme row per `lemma + reading +
  part_of_speech`, one encounter row per `(user, word, page text hash)`.

  They also cover the introduction threshold and the derived `chrome_like` flag,
  including its hand-off with suspensions.
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures

  alias Ashiato.{Encounters, Ledger, Lexemes, Pages, Repo, WordStates}

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
      # NULL is distinct in a unique index, so nil would insert a new row every call.
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

      pages |> Enum.take(2) |> Enum.each(&record(user, source, word, &1, true))

      assert Ledger.chrome_ratio(user.id, source.id) == %{word.id => 0.5}
    end

    test "a word on every page is 1.0", %{user: user, source: source, word: word} do
      pages = for _ <- 1..3, do: page_fixture(user_id: user.id, source_id: source.id)
      Enum.each(pages, &record(user, source, word, &1, true))

      assert Ledger.chrome_ratio(user.id, source.id) == %{word.id => 1.0}
    end
  end

  describe "introduce_words/3" do
    setup do
      user = user_fixture()
      source = source_fixture(user_id: user.id)

      {:ok, %{user: user, source: source}}
    end

    test "a word below the threshold is not introduced", %{user: user, source: source} do
      %{lexeme: lexeme} = met_word(user, source, 1)

      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id])
      assert Repo.aggregate(WordStates, :count) == 0
    end

    test "a word at the threshold is introduced, due immediately and new",
         %{user: user, source: source} do
      %{lexeme: lexeme, word: word} = met_word(user, source)

      assert {:ok, [introduced]} = Ledger.introduce_words(user.id, [lexeme.id])
      assert introduced.id == word.id

      assert [%WordStates{} = state] = Repo.all(WordStates)
      assert state.word_id == word.id
      assert state.state == 0
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
      assert Repo.aggregate(WordStates, :count) == 0
    end

    test "force: true bypasses the threshold", %{user: user, source: source} do
      %{lexeme: lexeme} = met_word(user, source, 1)

      assert {:ok, [_introduced]} = Ledger.introduce_words(user.id, [lexeme.id], force: true)
      assert Repo.aggregate(WordStates, :count) == 1
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
      assert Repo.aggregate(WordStates, :count) == 0
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

      assert Repo.aggregate(WordStates, :count) == 1
    end

    test "a lexeme with no words row is skipped unless forced", %{user: user} do
      lexeme = lexeme_fixture()

      assert {:ok, []} = Ledger.introduce_words(user.id, [lexeme.id])

      assert {:ok, [minted]} = Ledger.introduce_words(user.id, [lexeme.id], force: true)
      assert minted.lexeme_id == lexeme.id
      assert Repo.aggregate(WordStates, :count) == 1
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
      assert Repo.get!(WordStates, word.id)
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
