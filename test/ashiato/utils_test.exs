defmodule Ashiato.UtilsTest do
  use ExUnit.Case, async: true

  alias Ashiato.Utils

  test "a katakana reading comes back as hiragana, ー untouched" do
    assert Utils.to_hiragana("キャッチャー") == "きゃっちゃー"
    assert Utils.to_hiragana("ケーキ") == "けーき"
  end
end
