defmodule Ashiato.SettingsTest do
  @moduledoc """
  The settings boundary: typed JSON values in and out, secrets encrypted at
  rest and never logged, `(user_id, key)` upserts that never raise, and the
  capability gates that hide AI/translation affordances until both the switch
  and the credentials hold (D43, §7.5).

  The gate tests drive the behaviour through the fake; the storage tests pin
  the repo-backed semantics the contract names.
  """

  use Ashiato.DataCase, async: false

  import Ashiato.Fixtures
  import ExUnit.CaptureLog

  alias Ashiato.{Repo, Settings}
  alias Ashiato.Schemas.Setting

  describe "repo-backed get/put/all" do
    setup do
      Application.delete_env(:ashiato, :settings)
      {:ok, user: user_fixture()}
    end

    test "stores a non-secret as plain JSON and reads typed values back", %{user: user} do
      assert {:ok, row} = Settings.put(user.id, "new_cards_per_day", 10)
      assert row.value == "10"
      assert Settings.get(user.id, "new_cards_per_day") == 10

      Settings.put(user.id, "ai_features_enabled", true)
      assert Settings.get(user.id, "ai_features_enabled") == true

      Settings.put(user.id, "recent_sources", ["game", "manga"])
      assert Settings.get(user.id, "recent_sources") == ["game", "manga"]
    end

    test "encrypts a secret at rest and decrypts on read", %{user: user} do
      assert {:ok, row} = Settings.put(user.id, "OPENAI_API_KEY", "sk-live-1234", secret: true)

      assert row.secret
      refute row.value =~ "sk-live-1234"
      assert Settings.get(user.id, "OPENAI_API_KEY") == "sk-live-1234"
    end

    test "upserts on (user_id, key) so a second put replaces instead of raising", %{user: user} do
      assert {:ok, _} = Settings.put(user.id, "OPENAI_API_KEY", "sk-1")
      assert {:ok, _} = Settings.put(user.id, "OPENAI_API_KEY", "sk-2", secret: true)

      assert Settings.get(user.id, "OPENAI_API_KEY") == "sk-2"

      count = Repo.one(from(s in Setting, where: s.user_id == ^user.id, select: count(s.id)))
      assert count == 1
      assert Repo.get_by!(Setting, user_id: user.id, key: "OPENAI_API_KEY").secret
    end

    test "missing rows fall back to the requirement defaults", %{user: user} do
      assert Settings.get(user.id, "ai_features_enabled") == false
      assert Settings.get(user.id, "translation_enabled") == false
      assert Settings.get(user.id, "translation_provider") == "google_free"
      assert Settings.get(user.id, "min_encounters") == 2
      assert Settings.get(user.id, "new_cards_per_day") == 10
      assert Settings.get(user.id, "maturity_threshold_days") == 21
      assert Settings.get(user.id, "unknown_key", :fallback) == :fallback
    end

    test "all/1 decodes values and redacts secrets", %{user: user} do
      assert Settings.all(user.id) == %{}

      Settings.put(user.id, "new_cards_per_day", 10)
      Settings.put(user.id, "deepl_api_key", "dl-1234", secret: true)

      assert Settings.all(user.id) == %{
               "new_cards_per_day" => 10,
               "deepl_api_key" => :redacted
             }
    end

    test "a secret that fails authentication returns the default, logged without the value", %{
      user: user
    } do
      {:ok, _} = Settings.put(user.id, "OPENAI_API_KEY", "sk-tamper-me", secret: true)

      log =
        capture_log(fn ->
          Repo.update_all(from(s in Setting, where: s.user_id == ^user.id),
            set: [value: "XCP.not-the-ciphertext"]
          )

          assert Settings.get(user.id, "OPENAI_API_KEY", "fallback") == "fallback"
        end)

      assert log =~ "failed authentication"
      refute log =~ "sk-tamper-me"
    end
  end

  describe "capability gates through the fake" do
    setup do
      Application.put_env(:ashiato, :settings, Ashiato.Settings.Fake)
      start_supervised!(Ashiato.Settings.Fake)

      on_exit(fn -> Application.delete_env(:ashiato, :settings) end)

      {:ok, user: user_fixture()}
    end

    test "impl/0 defaults to the context and follows application config" do
      Application.delete_env(:ashiato, :settings)
      assert Settings.impl() == Settings

      Application.put_env(:ashiato, :settings, Ashiato.Settings.Fake)
      assert Settings.impl() == Ashiato.Settings.Fake
    end

    test "ai_capable? holds only when the switch is on and a non-empty key exists", %{user: user} do
      impl = Settings.impl()
      impl.put(user.id, "ai_features_enabled", true, [])
      impl.put(user.id, "OPENAI_API_KEY", "", [])

      refute Settings.ai_capable?(user.id)

      impl.put(user.id, "OPENAI_API_KEY", "sk-1", [])
      assert Settings.ai_capable?(user.id)

      impl.put(user.id, "ai_features_enabled", false, [])
      refute Settings.ai_capable?(user.id)
    end

    test "ai_capable? falls back to the environment for the key", %{user: user} do
      System.put_env("OPENAI_API_KEY", "sk-from-env")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      Settings.impl().put(user.id, "ai_features_enabled", true, [])

      assert Settings.ai_capable?(user.id)
    end

    test "translate_capable? follows the switch, the provider and its credentials", %{user: user} do
      impl = Settings.impl()
      impl.put(user.id, "translation_enabled", true, [])

      # no provider row: the google_free default needs nothing
      assert Settings.translate_capable?(user.id)

      impl.put(user.id, "translation_provider", "off", [])
      refute Settings.translate_capable?(user.id)

      impl.put(user.id, "translation_provider", "deepl", [])
      refute Settings.translate_capable?(user.id)

      impl.put(user.id, "deepl_api_key", "dl-1", [])
      assert Settings.translate_capable?(user.id)

      impl.put(user.id, "translation_provider", "libretranslate", [])
      refute Settings.translate_capable?(user.id)

      impl.put(user.id, "libretranslate_url", "http://localhost:5000", [])
      assert Settings.translate_capable?(user.id)

      impl.put(user.id, "translation_enabled", false, [])
      refute Settings.translate_capable?(user.id)
    end

    test "a stored null key does not fall through to the environment", %{user: user} do
      System.put_env("DEEPL_API_KEY", "dl-from-env")
      on_exit(fn -> System.delete_env("DEEPL_API_KEY") end)

      impl = Settings.impl()
      impl.put(user.id, "translation_enabled", true, [])
      impl.put(user.id, "translation_provider", "deepl", [])
      # the user cleared the key: the row exists and holds JSON null
      impl.put(user.id, "deepl_api_key", nil, [])

      refute Settings.translate_capable?(user.id)
    end

    test "translate_capable? covers the google_cloud and llm branches", %{user: user} do
      impl = Settings.impl()
      impl.put(user.id, "translation_enabled", true, [])

      impl.put(user.id, "translation_provider", "google_cloud", [])
      refute Settings.translate_capable?(user.id)
      impl.put(user.id, "google_cloud_api_key", "gc-1", [])
      assert Settings.translate_capable?(user.id)

      impl.put(user.id, "translation_provider", "llm", [])
      impl.put(user.id, "OPENAI_API_KEY", "", [])
      refute Settings.translate_capable?(user.id)
      impl.put(user.id, "OPENAI_API_KEY", "sk-1", [])
      assert Settings.translate_capable?(user.id)
    end
  end
end
