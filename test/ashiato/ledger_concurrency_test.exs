defmodule Ashiato.LedgerConcurrencyTest do
  @moduledoc """
  Proves the review serialisation on PostgreSQL: two concurrent reviews of the
  same word both apply, and the second schedule is computed from the first.

  The shared sandbox cannot show this — `start_owner!(shared: true)` checks out
  one connection, so two tasks would serialise on it inside one transaction and
  the lost update would stay invisible. Here every review runs in
  `Sandbox.unboxed_run/2`, so each task gets its own connection and its
  transaction really commits. Committed rows are deleted in `on_exit` in
  dependency order, so reruns are idempotent.
  """

  use ExUnit.Case, async: false

  @moduletag :postgres

  import Ecto.Query

  alias Ashiato.{Ledger, Repo}
  alias Ashiato.Schemas.{Lexeme, ReviewEvent, User, Word, WordState}

  setup do
    lemma = "同時#{System.unique_integer([:positive])}"

    {user, lexeme, word} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = Repo.insert!(%User{})
        lexeme = Repo.insert!(%Lexeme{lemma: lemma, reading: "", part_of_speech: "noun"})
        word = Repo.insert!(%Word{user_id: user.id, lexeme_id: lexeme.id})
        {user, lexeme, word}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(re in ReviewEvent, where: re.word_id == ^word.id))
        Repo.delete_all(from(ws in WordState, where: ws.word_id == ^word.id))
        Repo.delete_all(from(w in Word, where: w.id == ^word.id))
        Repo.delete_all(from(l in Lexeme, where: l.id == ^lexeme.id))
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)
    end)

    %{word: word}
  end

  test "two concurrent first-ever reviews both apply", %{word: word} do
    results = concurrent_reviews(word.id)
    assert Enum.all?(results, &match?({:ok, %WordState{}}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      events = Repo.all(from(re in ReviewEvent, where: re.word_id == ^word.id, order_by: re.id))
      assert [%ReviewEvent{} = first, %ReviewEvent{} = second] = events
      assert [first.grade, second.grade] == [3, 3]

      state = Repo.get!(WordState, word.id)
      assert state.reps == 2
      assert state.state == :review
      assert state.failure_streak == 0
      assert state.lapses == 0
      # the later event belongs to the review that read the first one's
      # committed state; its schedule is what the materialised row carries
      assert state.stability == second.stability_after
      assert state.difficulty == second.difficulty_after
    end)
  end

  test "two concurrent reviews of an already-reviewed word both apply", %{word: word} do
    prior =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> Ledger.review(word.id, 3) end)

    assert {:ok, %WordState{reps: 1}} = prior

    results = concurrent_reviews(word.id)
    assert Enum.all?(results, &match?({:ok, %WordState{}}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      events = Repo.all(from(re in ReviewEvent, where: re.word_id == ^word.id, order_by: re.id))
      assert [%ReviewEvent{}, %ReviewEvent{}, %ReviewEvent{} = last] = events

      state = Repo.get!(WordState, word.id)
      assert state.reps == 3
      assert state.stability == last.stability_after
      assert state.difficulty == last.difficulty_after
    end)
  end

  # Two tasks race `introduce_words/3` with `force: true` on the same
  # never-met lexeme, each on its own connection. With the old
  # insert-then-refetch-on-constraint path the loser's refetch ran inside a
  # transaction the unique violation had already aborted (PG 25P02); the
  # upsert turns the race into a no-op insert plus a plain refetch, so both
  # tasks return `{:ok, _}` — the loser may see the word already introduced
  # and return an empty list — and exactly one `words` row exists.
  test "two concurrent force-introductions of a never-met lexeme create one word" do
    lemma = "並行#{System.unique_integer([:positive])}"

    {user, lexeme} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = Repo.insert!(%User{})
        lexeme = Repo.insert!(%Lexeme{lemma: lemma, reading: "", part_of_speech: "noun"})
        {user, lexeme}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        word_ids = Repo.all(from(w in Word, where: w.user_id == ^user.id, select: w.id))

        Repo.delete_all(from(re in ReviewEvent, where: re.word_id in ^word_ids))
        Repo.delete_all(from(ws in WordState, where: ws.word_id in ^word_ids))
        Repo.delete_all(from(w in Word, where: w.user_id == ^user.id))
        Repo.delete_all(from(l in Lexeme, where: l.id == ^lexeme.id))
        Repo.delete_all(from(u in User, where: u.id == ^user.id))
      end)
    end)

    parent = self()

    tasks =
      for n <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, n})

          receive do
            :go -> :ok
          end

          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Ledger.introduce_words(user.id, [lexeme.id], force: true)
          end)
        end)
      end

    for n <- 1..2, do: assert_receive({:ready, ^n}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 30_000))

    assert Enum.all?(results, &match?({:ok, _}, &1))

    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      words = Repo.all(from(w in Word, where: w.user_id == ^user.id))
      assert length(words) == 1
      assert hd(words).lexeme_id == lexeme.id
    end)
  end

  # Two tasks, each with its own connection, held at a barrier until both are
  # ready, so the reviews actually overlap instead of racing by chance.
  defp concurrent_reviews(word_id) do
    parent = self()

    tasks =
      for n <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, n})

          receive do
            :go -> :ok
          end

          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            Ledger.review(word_id, 3)
          end)
        end)
      end

    for n <- 1..2, do: assert_receive({:ready, ^n}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 30_000))
  end
end
