defmodule Ashiato.TranslatorServiceTest do
  @moduledoc """
  Drives the provider-scoped cache through the Fake: TTL boundary, fresh-row
  survival against the delete and the insert, provider scoping, duplicate lines,
  and the missing-target contract.
  """

  # The fake registers a named Agent and these tests write application env; both are
  # VM-global, so the module does not run concurrently. `async: false` also puts the
  # sandbox in shared mode, so a `Task` (Test 2) can use the test's connection.
  use Ashiato.DataCase, async: false

  alias Ashiato.Repo
  alias Ashiato.Schemas.Translation
  alias Ashiato.Translator
  alias Ashiato.Translator.Fake
  alias Ashiato.TranslatorService

  @now ~U[2026-11-16 12:00:00Z]
  @cutoff DateTime.add(@now, -2_592_000, :second)

  setup do
    Application.put_env(:ashiato, Translator, provider: Fake)
    on_exit(fn -> Application.delete_env(:ashiato, Translator) end)
    :ok
  end

  test "a fresh row survives, an expired row is replaced, one provider call" do
    start_supervised!({Fake, replies: ["new-a", "new-b"]})
    insert_translation("fake", "en", "甲", "A-fresh", @cutoff)
    insert_translation("fake", "en", "乙", "B-expired", DateTime.add(@cutoff, -1, :second))

    assert TranslatorService.translate_page(["甲", "乙"], target_lang: "en", now: @now) ==
             {:ok, ["new-a", "new-b"]}

    assert Fake.calls() == [{:page, ["甲", "乙"]}]

    a = row("fake", "甲")
    assert a.translated_text == "A-fresh"
    assert a.fetched_at == @cutoff

    b = row("fake", "乙")
    assert b.translated_text == "new-b"
    assert b.fetched_at == @now
  end

  test "a row inserted while the provider is blocked wins the insert" do
    start_supervised!({Fake, gate: self()})

    task =
      Task.async(fn ->
        TranslatorService.translate_page(["丙"], target_lang: "en", now: @now)
      end)

    assert_receive {:translator_fake_waiting, fake_pid}, 1_000
    insert_translation("fake", "en", "丙", "winner-sentinel", @now)
    send(fake_pid, :translator_fake_release)

    assert Task.await(task) == {:ok, ["[丙]"]}
    assert row("fake", "丙").translated_text == "winner-sentinel"
  end

  test "missing, empty, or non-string target_lang errors without a provider call or write" do
    start_supervised!(Fake)

    for opts <- [[], [target_lang: nil], [target_lang: ""], [target_lang: 42]] do
      assert TranslatorService.translate_page(["一"], opts) == {:error, :missing_target_lang}
    end

    assert Fake.calls() == []
    refute row("fake", "一")
  end

  test "another provider's row is a miss and both rows coexist" do
    start_supervised!(Fake)
    insert_translation("other", "en", "丁", "other-text", @now)

    assert TranslatorService.translate_page(["丁"], target_lang: "en", now: @now) ==
             {:ok, ["[丁]"]}

    assert %Translation{translated_text: "other-text"} = row("other", "丁")
    assert %Translation{translated_text: "[丁]"} = row("fake", "丁")
  end

  test "duplicate lines cache the first occurrence and a later all-hit returns it for every duplicate" do
    start_supervised!({Fake, replies: ["t1", "t2", "t3"]})
    lines = ["一", "二", "一"]

    assert TranslatorService.translate_page(lines, target_lang: "en", now: @now) ==
             {:ok, ["t1", "t2", "t3"]}

    assert row("fake", "一").translated_text == "t1"
    assert row("fake", "二").translated_text == "t2"

    assert TranslatorService.translate_page(lines, target_lang: "en", now: @now) ==
             {:ok, ["t1", "t2", "t1"]}

    assert Fake.calls() == [{:page, lines}]
  end

  test "a provider error writes nothing; the expired row is deleted" do
    start_supervised!({Fake, error: :boom})
    insert_translation("fake", "en", "戊", "expired", DateTime.add(@cutoff, -1, :second))

    assert TranslatorService.translate_page(["戊"], target_lang: "en", now: @now) ==
             {:error, :boom}

    assert Fake.calls() == [{:page, ["戊"]}]
    refute row("fake", "戊")
  end

  test "provider_name/0 returns the declared stable names" do
    assert Fake.provider_name() == "fake"
    assert Translator.Off.provider_name() == "off"
    assert Translator.GoogleFree.provider_name() == "google_free"
    assert Translator.Llm.provider_name() == "llm"
    assert Translator.Deepl.provider_name() == "deepl"
    assert Translator.GoogleCloud.provider_name() == "google_cloud"
  end

  defp insert_translation(provider, lang, line, text, fetched_at) do
    %Translation{}
    |> Ecto.Changeset.change(%{
      provider: provider,
      lang: lang,
      source_hash: hash(line),
      translated_text: text,
      fetched_at: fetched_at
    })
    |> Repo.insert!()
  end

  defp row(provider, line) do
    Repo.get_by(Translation, provider: provider, lang: "en", source_hash: hash(line))
  end

  defp hash(line), do: Base.encode16(:crypto.hash(:sha256, line), case: :lower)
end
