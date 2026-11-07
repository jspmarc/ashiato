defmodule Ashiato.Utils do
  @moduledoc """
  Small shared helpers: pure string/collection helpers, plus timestamps that
  match the `:utc_datetime` columns.
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

  @doc """
  Converts katakana to hiragana, leaving every other character untouched.

  Katakana U+30A1..U+30F6 map to hiragana by subtracting 0x60. `ー` (U+30FC) is outside that range
  and passes through, so the prolonged sound mark survives in either script.
  """
  @spec to_hiragana(String.t()) :: String.t()
  def to_hiragana(text) do
    text
    |> String.codepoints()
    |> Enum.map(&to_hiragana_codepoint/1)
    |> IO.iodata_to_binary()
  end

  defp to_hiragana_codepoint(<<codepoint::utf8>>) when codepoint in 0x30A1..0x30F6 do
    <<codepoint - 0x60::utf8>>
  end

  defp to_hiragana_codepoint(codepoint), do: codepoint

  @doc """
  Splits text on newlines and trims each line.
  """
  @spec split_trim(String.t()) :: [String.t()]
  def split_trim(text), do: text |> String.split("\n") |> Enum.map(&String.trim/1)

  @doc """
  The current time truncated to whole seconds, matching the `:utc_datetime`
  columns.
  """
  @spec utc_now() :: DateTime.t()
  def utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
