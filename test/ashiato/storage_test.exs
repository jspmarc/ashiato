defmodule Ashiato.StorageTest do
  @moduledoc """
  The storage behaviour is swappable (D29) and its key validation is the only
  defence between an OCR-supplied locator and the filesystem, so the tests pin:

    * the fake as the behaviour in isolation — round trip, recorded calls,
      idempotent delete — exactly the surface later waves will depend on
    * `Ashiato.Storage.Local` against a per-test directory: the atomic
      put/get/delete round trip, the `file://` pre-signature, and traversal
      keys rejected with nothing written outside the root

  Each test roots `Local` at its own `tmp_dir` through application env, so no
  test ever touches the default `tmp/storage` or another test's files.
  """

  use ExUnit.Case, async: false, tmp_dir: true

  alias Ashiato.Storage
  alias Ashiato.Storage.{Fake, Local}

  describe "Fake" do
    setup do
      start_supervised!(Fake)
      :ok
    end

    test "put/get/delete round trip in memory, and a deleted key reads as missing" do
      assert :ok = Fake.put("pages/1.jpg", <<1, 2, 3>>)
      assert {:ok, <<1, 2, 3>>} = Fake.get("pages/1.jpg")

      assert :ok = Fake.delete("pages/1.jpg")
      assert {:error, :enoent} = Fake.get("pages/1.jpg")
    end

    test "delete of an absent key is :ok" do
      assert :ok = Fake.delete("pages/absent.jpg")
    end

    test "records every call in order" do
      Fake.put("pages/1.jpg", <<1>>)
      Fake.get("pages/1.jpg")
      Fake.presigned_get("pages/1.jpg", 300)
      Fake.delete("pages/1.jpg")

      assert [
               {:put, "pages/1.jpg"},
               {:get, "pages/1.jpg"},
               {:presigned_get, "pages/1.jpg", 300},
               {:delete, "pages/1.jpg"}
             ] = Fake.calls()
    end

    test "presigned_get hands back a locator the OCR fake can carry" do
      Fake.put("pages/1.jpg", <<1>>)
      assert {:ok, "fake://pages/1.jpg"} = Fake.presigned_get("pages/1.jpg", 300)
    end

    test "a traversal key is rejected and nothing is stored" do
      assert {:error, :invalid_key} = Fake.put("../escape", <<1>>)
      assert Fake.objects() == %{}
      assert Fake.calls() == []
    end
  end

  describe "Local" do
    setup %{tmp_dir: tmp_dir} do
      Application.put_env(:ashiato, Storage, root: tmp_dir)

      on_exit(fn -> Application.delete_env(:ashiato, Storage) end)

      :ok
    end

    @tag :tmp_dir
    test "put writes the file and get reads it back" do
      assert :ok = Local.put("pages/1.jpg", <<1, 2, 3>>)
      path = Path.join(Local.root(), "pages/1.jpg")
      assert File.exists?(path)
      assert {:ok, <<1, 2, 3>>} = Local.get("pages/1.jpg")
    end

    @tag :tmp_dir
    test "get of a missing key is an error tuple, not a raise" do
      assert {:error, :enoent} = Local.get("pages/missing.jpg")
    end

    @tag :tmp_dir
    test "put overwrites atomically: the second write fully replaces the first" do
      :ok = Local.put("pages/1.jpg", "first")
      :ok = Local.put("pages/1.jpg", "second")
      assert {:ok, "second"} = Local.get("pages/1.jpg")

      # match_dot: the atomic-write temp file is named ".ashiato-tmp-<n>", so a default
      # wildcard would skip exactly the leftover this assertion exists to catch.
      dir = Path.dirname(path_for("pages/1.jpg"))
      assert [_only] = Path.wildcard(Path.join(dir, "*"), match_dot: true)
    end

    @tag :tmp_dir
    test "delete removes the file and is idempotent" do
      :ok = Local.put("pages/1.jpg", <<1>>)
      assert :ok = Local.delete("pages/1.jpg")
      assert {:error, :enoent} = Local.get("pages/1.jpg")
      assert :ok = Local.delete("pages/1.jpg")
    end

    @tag :tmp_dir
    test "presigned_get returns a file:// URL pointing at an existing file" do
      :ok = Local.put("pages/1.jpg", <<1, 2, 3>>)

      assert {:ok, "file://" <> path} = Local.presigned_get("pages/1.jpg", 300)
      assert File.exists?(path)
      assert {:ok, <<1, 2, 3>>} = File.read(path)
    end

    @tag :tmp_dir
    test "a traversal key is rejected and writes nothing outside the root" do
      escape_path = Path.expand(Path.join(Local.root(), "../escape"))

      assert {:error, :invalid_key} = Local.put("../escape", "nope")
      assert {:error, :invalid_key} = Local.put("/etc/passwd", "nope")
      assert {:error, :invalid_key} = Local.put("nested/../escape", "nope")
      assert {:error, :invalid_key} = Local.put("", "nope")
      assert {:error, :invalid_key} = Local.presigned_get("../escape", 300)

      refute File.exists?(escape_path)
    end

    defp path_for(key), do: Path.join(Local.root(), key)
  end

  describe "Ashiato.Storage.impl/0" do
    test "defaults to the local store" do
      assert Storage.impl() == Storage.Local
    end

    test "follows application config, so a later S3 card swaps it by configuration" do
      Application.put_env(:ashiato, Storage, impl: Storage.Fake)
      on_exit(fn -> Application.delete_env(:ashiato, Storage) end)

      assert Storage.impl() == Storage.Fake
    end
  end
end
