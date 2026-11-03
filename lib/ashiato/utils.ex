defmodule Ashiato.Utils do
  @moduledoc """
  Pure string/collection helpers shared across contexts.
  """

  @doc """
  The distinct CJK codepoints of a string, in string order.

  Filtering codepoints rather than regexing bytes means the string can never
  be mis-split mid-UTF-8-sequence, and the dedupe means a glyph repeated
  inside one string is credited once.
  """
  @spec cjk_codepoints(String.t()) :: [String.t()]
  def cjk_codepoints(string) do
    string
    |> String.codepoints()
    |> Enum.filter(&cjk_codepoint?/1)
    |> Enum.uniq()
  end

  @doc """
  True when the string is a single CJK Unified Ideograph (U+4E00..U+9FFF).
  Hiragana, katakana, latin and punctuation all fall outside the block.
  """
  @spec cjk_codepoint?(String.t()) :: boolean()
  def cjk_codepoint?(codepoint) do
    case String.to_charlist(codepoint) do
      [cp] when cp in 0x4E00..0x9FFF -> true
      _ -> false
    end
  end
end
