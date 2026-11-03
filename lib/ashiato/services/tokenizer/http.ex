defmodule Ashiato.Tokenizer.Http do
  @behaviour Ashiato.Tokenizer

  @moduledoc """
  HTTP client for the tokenizer endpoint on `jp-dict-api` (docs/requirements.md §7.2).

  One `Req.post!` to `{base_url}/tokenize` with a `{"text": ...}` JSON body, expecting a reply of
  the shape `{"tokens": [{"surface" => ..., "lemma" => ..., "reading" => ..., "part_of_speech" => ...}]}`.
  The base URL comes from application config (`:base_url` under `Ashiato.Tokenizer`) or the
  `JP_DICT_API_URL` environment variable.

  Readings are normalised to hiragana **here**, not in the service: SudachiPy emits katakana and
  lexeme identity is `lemma + reading`, so an unconverted reading would mint a second row for a
  word the ledger already knows (§6.1).
  """

  @impl true
  @spec tokenize(String.t()) :: {:ok, [Ashiato.Tokenizer.token()]} | {:error, term()}
  def tokenize(text) do
    response = Req.post!(req(), url: "/tokenize", json: %{text: text})
    parse(response)
  rescue
    exception -> {:error, exception}
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

  # `:plug` is never set in production; tests inject `Req.Test` through it so the mapping is
  # exercised without a socket.
  defp req do
    env = Application.get_env(:ashiato, Ashiato.Tokenizer, [])
    opts = Keyword.take(env, [:plug])

    case base_url() do
      nil -> Req.new(opts)
      base_url -> Req.new(Keyword.put(opts, :base_url, base_url))
    end
  end

  defp base_url do
    Application.get_env(:ashiato, Ashiato.Tokenizer, [])[:base_url] ||
      System.get_env("JP_DICT_API_URL")
  end

  defp parse(%Req.Response{status: 200, body: body}) do
    {:ok, Enum.map(body["tokens"] || [], &parse_token/1)}
  end

  defp parse(%Req.Response{status: status}), do: {:error, {:unexpected_status, status}}

  defp parse_token(%{
         "surface" => surface,
         "lemma" => lemma,
         "reading" => reading,
         "part_of_speech" => part_of_speech
       }) do
    %{
      surface: surface,
      lemma: lemma,
      reading: to_hiragana(reading),
      part_of_speech: part_of_speech
    }
  end
end
