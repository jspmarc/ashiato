defmodule Ashiato.DictionaryTest do
  @moduledoc """
  Drives the cache façade through the Fake: a cache hit makes zero service
  lookups, a version bump ignores old rows instead of mutating them (P9), and
  `lookup_many/1` returns a map keyed by term while fetching only the misses.
  """

  use Ashiato.DataCase, async: false

  alias Ashiato.Dictionary
  alias Ashiato.Repo
  alias Ashiato.Schemas.DictCacheEntry

  @entry_a %{"gloss" => "eat", "reading" => "たべる"}
  @entry_b %{"gloss" => "bridge", "reading" => "はし"}
  @entry_c %{"gloss" => "chopsticks", "reading" => "はし"}

  # The fake is selected through the same application config production uses, and the
  # memoised dict_version is process-global, so each test starts from a cold memo.
  setup do
    Application.put_env(:ashiato, Dictionary, service: Dictionary.Fake)
    Dictionary.forget_version()

    on_exit(fn ->
      Application.delete_env(:ashiato, Dictionary)
      Dictionary.forget_version()
    end)

    :ok
  end

  test "a cache hit performs zero service lookups" do
    start_supervised!({Dictionary.Fake, version: "2026-1", entries: %{"食べる" => @entry_a}})

    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    assert Dictionary.Fake.calls() == 1

    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    assert Dictionary.Fake.calls() == 1
    assert Repo.aggregate(DictCacheEntry, :count) == 1
  end

  test "a cache hit does not even ask for the dictionary version" do
    start_supervised!({Dictionary.Fake, version: "2026-1", entries: %{"食べる" => @entry_a}})

    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    assert Dictionary.Fake.version_calls() == 1

    # the version is part of the cache key, so an un-memoised version call would mean a
    # cache hit still touches the network -- and dies with the service
    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    assert Dictionary.Fake.version_calls() == 1
  end

  test "a miss and a cache hit return the same shape" do
    # The service may hand back atom keys; a row round-tripped through the JSON column
    # always comes back string-keyed. Wave 3 must not have to care which call it made.
    start_supervised!({Dictionary.Fake, version: "2026-1", entries: %{"食べる" => %{gloss: "eat"}}})

    assert {:ok, first} = Dictionary.lookup("食べる")
    assert {:ok, second} = Dictionary.lookup("食べる")
    assert first == second
    assert Map.has_key?(first, "gloss")
  end

  test "a term that is not valid UTF-8 is refused before any request" do
    start_supervised!({Dictionary.Fake, version: "2026-1", entries: %{}})

    assert Dictionary.lookup(<<"食べ", 0xFF>>) == {:error, :invalid_term}
    assert Dictionary.lookup_many([<<"食べ", 0xFF>>]) == {:error, :invalid_term}
    assert Dictionary.Fake.calls() == 0
  end

  test "a version bump ignores the old row and inserts a new one, leaving the old row untouched" do
    start_supervised!({Dictionary.Fake, version: "2026-1", entries: %{"食べる" => @entry_a}})

    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    old = Repo.get_by!(DictCacheEntry, dict_version: "2026-1")
    snapshot = Map.take(old, [:id, :kind, :cache_key, :dict_version, :payload, :fetched_at])

    Dictionary.Fake.set_version("2026-2")
    # a new release is picked up by the scheduled check (§6.9), not by each lookup asking
    assert Dictionary.refresh_version() == {:ok, "2026-2"}

    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    assert Dictionary.Fake.calls() == 2

    assert Repo.all(from(e in DictCacheEntry, select: e.dict_version, order_by: e.dict_version)) ==
             ["2026-1", "2026-2"]

    assert Repo.get!(DictCacheEntry, old.id) |> Map.take(Map.keys(snapshot)) == snapshot
    assert Repo.get_by!(DictCacheEntry, dict_version: "2026-2").payload == @entry_a
  end

  test "lookup_many returns a map keyed by term and fetches only the misses" do
    start_supervised!(
      {Dictionary.Fake,
       version: "2026-1", entries: %{"食べる" => @entry_a, "橋" => @entry_b, "箸" => @entry_c}}
    )

    assert {:ok, %{"食べる" => @entry_a, "橋" => @entry_b}} =
             Dictionary.lookup_many(["食べる", "橋"])

    assert Dictionary.Fake.calls() == 1
    assert Repo.aggregate(DictCacheEntry, :count) == 2

    assert {:ok, %{"食べる" => @entry_a, "橋" => @entry_b, "箸" => @entry_c}} =
             Dictionary.lookup_many(["食べる", "橋", "箸"])

    assert Dictionary.Fake.calls() == 2
    assert List.last(Dictionary.Fake.requests()) == {:lookup_many, ["箸"]}
  end
end
