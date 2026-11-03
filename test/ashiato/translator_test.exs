defmodule Ashiato.TranslatorTest do
  @moduledoc """
  Drives the translator through the Fake: a page is one request, a misaligned reply
  falls back to one request per line, and a provider that is not configured is an error
  rather than a silent per-line retry.
  """

  # The fake registers a named Agent and these tests write application env; both are
  # VM-global, so the module does not run concurrently.
  use ExUnit.Case, async: false

  alias Ashiato.Translator
  alias Ashiato.Translator.Fake

  setup do
    Application.put_env(:ashiato, Translator, provider: Fake)
    on_exit(fn -> Application.delete_env(:ashiato, Translator) end)
    :ok
  end

  test "a 3-line page produces 3 lines in one request" do
    start_supervised!(Fake)

    assert Translator.translate_page(["一", "二", "三"], target_lang: "en") ==
             {:ok, ["[一]", "[二]", "[三]"]}

    assert Fake.calls() == [{:page, ["一", "二", "三"]}]
  end

  test "a mismatched line count falls back to one request per line" do
    start_supervised!({Fake, mismatch: true})

    assert Translator.translate_page(["一", "二", "三"], target_lang: "en") ==
             {:ok, ["[一]", "[二]", "[三]"]}

    assert Fake.calls() == [
             {:page, ["一", "二", "三"]},
             {:page, ["一"]},
             {:page, ["二"]},
             {:page, ["三"]}
           ]
  end

  test "an empty page is no request at all" do
    start_supervised!(Fake)

    assert Translator.translate_page([], target_lang: "en") == {:ok, []}
    assert Fake.calls() == []
  end

  test "off is an error, not an empty translation" do
    Application.put_env(:ashiato, Translator, provider: :off)

    assert Translator.translate_page(["一"], target_lang: "en") == {:error, :disabled}
  end

  test "impl/0 resolves a configured provider and defaults to google_free" do
    assert Translator.impl() == Fake

    Application.put_env(:ashiato, Translator, provider: :google_free)
    assert Translator.impl() == Translator.GoogleFree

    Application.delete_env(:ashiato, Translator)
    assert Translator.impl() == Translator.GoogleFree
  end

  test "an unparsable page reply triggers the per-line fallback" do
    request = fn
      ["一", "二"], _opts -> {:error, :unparsable}
      [line], _opts -> {:ok, [line <> "!"]}
    end

    assert Translator.page_with_fallback(["一", "二"], [target_lang: "en"], request) ==
             {:ok, ["一!", "二!"]}
  end

  test "a provider error other than :unparsable is returned, never retried per line" do
    request = fn _lines, _opts -> {:error, :not_configured} end

    # Retrying per line here would multiply traffic against a provider that cannot
    # serve any of it, and would mask a configuration error as a content problem.
    assert Translator.page_with_fallback(["一", "二"], [], request) == {:error, :not_configured}
  end

  test "a missing target language is an error, not an auto-detect guess" do
    assert Translator.langs([]) == {:error, :missing_target_lang}
    assert Translator.langs(source_lang: "ja") == {:error, :missing_target_lang}
    assert Translator.langs(target_lang: "en") == {:ok, {"auto", "en"}}
    assert Translator.langs(source_lang: "ja", target_lang: "en") == {:ok, {"ja", "en"}}
  end
end
