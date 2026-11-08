defmodule Ashiato.Tokenizer do
  @moduledoc """
  Tokenizer behaviour — `POST /tokenize` on `jp-dict-api`, SudachiPy underneath, one call per page
  (docs/requirements.md §7.2).

  The measured behaviour downstream design depends on: kana is never converted to kanji, inflection
  is normalised to the dictionary form, readings arrive in katakana and are normalised to hiragana
  in the client, and a reading alone never identifies a word (identity is `lemma + reading`, §6.1).
  """

  @typedoc """
  One morphological unit.

  * `:surface` — the text exactly as it appears on the page, so kana orthography survives
    (たべる must never come back as 食べる)
  * `:lemma` — dictionary form, orthography preserved; kanji are derived from it, so a normalised
    kana lemma would credit characters the reader never saw (§6.1)
  * `:reading` — pronunciation, normalised to hiragana by the client
    (`Ashiato.Utils.to_hiragana/1`); it is half the lexeme identity
  * `:part_of_speech` — POS as reported by the tokenizer
  """
  @type token :: %{
          required(:surface) => String.t(),
          required(:lemma) => String.t(),
          required(:reading) => String.t(),
          required(:part_of_speech) => String.t()
        }

  @doc """
  Tokenizes `text` into `t:token/0` maps.

  The service emits katakana readings; the client normalises them to hiragana, because an
  unconverted reading would mint a second lexeme for a word the ledger already knows.
  """
  @callback tokenize(text :: String.t()) :: {:ok, [token()]} | {:error, term()}

  @doc """
  The configured implementation, from application config under `Ashiato.Tokenizer`.

  Later waves call `impl()` and depend on the behaviour, never on a concrete module. Defaults to
  `Ashiato.Tokenizer.Http` when unset.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ashiato, __MODULE__, [])[:impl] || Ashiato.Tokenizer.Http
  end

  @doc """
  Tokenizes `text` through `impl/0`.
  """
  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, term()}
  def tokenize(text), do: impl().tokenize(text)
end
