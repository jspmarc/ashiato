defmodule Ashiato.UtilsTest do
  use ExUnit.Case, async: true

  alias Ashiato.Utils

  test "a katakana reading comes back as hiragana, ー untouched" do
    assert Utils.to_hiragana("キャッチャー") == "きゃっちゃー"
    assert Utils.to_hiragana("ケーキ") == "けーき"
  end

  test "split_trim splits on newlines and trims each line" do
    assert Utils.split_trim(" 一 \n二\n 三 ") == ["一", "二", "三"]
  end
end
