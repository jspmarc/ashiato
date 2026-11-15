defmodule Ashiato.DictionaryTest do
  @moduledoc """
  Drives the cache façade through the Fake: a cache hit makes zero service
  lookups, a version bump ignores old rows instead of mutating them, and
  `lookup_many/1` returns a map keyed by term while fetching only the misses.
  """

  use Ashiato.DataCase, async: false

  alias Ashiato.Dictionary
  alias Ashiato.Repo
  alias Ashiato.Schemas.DictCacheEntry

  @entry_a %{"gloss" => "eat", "reading" => "たべる"}
  @entry_b %{"gloss" => "bridge", "reading" => "はし"}
  @entry_c %{"gloss" => "chopsticks", "reading" => "はし"}

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
    # always comes back string-keyed. Both calls must return the same shape.
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
    # the scheduled release check flips the version outside the lookup path
    assert {:ok, "2026-2"} = Dictionary.refresh_version()
    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    assert Dictionary.Fake.calls() == 2

    assert Repo.all(from(e in DictCacheEntry, select: e.dict_version, order_by: e.dict_version)) ==
             ["2026-1", "2026-2"]

    assert Repo.get!(DictCacheEntry, old.id) |> Map.take(Map.keys(snapshot)) == snapshot
    assert Repo.get_by!(DictCacheEntry, dict_version: "2026-2").payload == @entry_a
  end

  test "prune deletes superseded versions and keeps the current one" do
    start_supervised!({Dictionary.Fake, version: "2026-1", entries: %{"食べる" => @entry_a}})

    assert {:ok, @entry_a} = Dictionary.lookup("食べる")
    Dictionary.Fake.set_version("2026-2")
    assert {:ok, "2026-2"} = Dictionary.refresh_version()
    assert {:ok, @entry_a} = Dictionary.lookup("食べる")

    assert Dictionary.prune() == {:ok, 1}
    assert Repo.all(from e in DictCacheEntry, select: e.dict_version) == ["2026-2"]
  end

  test "a batch refresh picks up a version bump before fetching" do
    start_supervised!(
      {Dictionary.Fake, version: "2026-1", entries: %{"食べる" => @entry_a, "橋" => @entry_b}}
    )

    assert {:ok, %{"食べる" => @entry_a}} = Dictionary.lookup_many(["食べる"])

    Dictionary.Fake.set_version("2026-2")

    assert {:ok, %{"食べる" => @entry_a, "橋" => @entry_b}} =
             Dictionary.lookup_many(["食べる", "橋"])

    assert Repo.aggregate(
             from(e in DictCacheEntry, where: e.dict_version == "2026-2"),
             :count
           ) == 2
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

  describe "Http" do
    setup do
      Application.put_env(:ashiato, Dictionary,
        impl: Dictionary.Http,
        base_url: "http://dict.test",
        plug: {Req.Test, __MODULE__}
      )

      on_exit(fn -> Application.put_env(:ashiato, Dictionary, impl: Dictionary.Fake) end)
      :ok
    end

    test "maps lookup replies, fans out batches, and reads a plain-text version" do
      Req.Test.stub(__MODULE__, fn conn ->
        case Enum.map(conn.path_info, &URI.decode/1) do
          ["version"] ->
            Plug.Conn.send_resp(conn, 200, "2026-08-03\n")

          ["lookup", "食べる"] ->
            Req.Test.json(conn, %{
              "words" => [%{"word" => "食べる", "meanings" => ["eat"]}],
              "kanji" => nil
            })

          ["lookup", "橋"] ->
            Req.Test.json(conn, %{
              "words" => [%{"word" => "橋", "meanings" => ["bridge"]}],
              "kanji" => nil
            })

          ["lookup", "ない"] ->
            Req.Test.json(conn, %{"words" => nil, "kanji" => nil})
        end
      end)

      assert Dictionary.Http.dict_version() == {:ok, "2026-08-03"}
      assert {:ok, %{"words" => [%{"word" => "食べる"}]}} = Dictionary.Http.lookup("食べる")
      assert Dictionary.Http.lookup("ない") == {:error, :not_found}
      assert {:ok, %{"食べる" => _, "橋" => _}} = Dictionary.Http.lookup_many(["食べる", "橋"])
    end

    test "maps malformed JSON to invalid_json and transport errors" do
      Req.Test.stub(__MODULE__, fn conn ->
        case Enum.map(conn.path_info, &URI.decode/1) do
          ["lookup", "壊"] ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, "{not json")

          ["lookup", "落"] ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      assert Dictionary.Http.lookup("壊") == {:error, :invalid_json}
      assert Dictionary.Http.lookup("落") == {:error, {:transport, :econnrefused}}
    end

    test "a crashing worker returns an error without killing the caller" do
      Req.Test.stub(__MODULE__, fn conn ->
        case Enum.map(conn.path_info, &URI.decode/1) do
          ["lookup", "爆"] -> raise "boom"
        end
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Dictionary.Http.lookup_many(["爆"]) == {:error, :request_failed}
        end)

      refute log =~ "爆"
      assert Process.alive?(self())
    end

    test "encodes slash as one path segment" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/lookup/a%2Fb"

        Req.Test.json(conn, %{"words" => nil, "kanji" => nil})
      end)

      assert Dictionary.Http.lookup("a/b") == {:error, :not_found}
    end
  end
end
