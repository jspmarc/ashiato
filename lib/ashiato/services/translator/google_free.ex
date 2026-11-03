defmodule Ashiato.Translator.GoogleFree do
  @moduledoc """
  The undocumented free web endpoint (`translate_a/single`) — no key (D45).

  Caveats that come with it (§7.5): it is outside Google's terms, it can start
  refusing without notice, and it sends your text to Google. That is why
  `translation_enabled` is off by default and `google_cloud` exists as the
  supported contract for the same engine.
  """
  use Ashiato.Translator

  @url "https://translate.googleapis.com/translate_a/single"

  @doc """
  One page request: all lines joined with newlines. The reply's nested segment
  array is unwrapped into plain text, then split back into lines and trimmed.
  A reply in any other shape is `{:error, :unparsable}` so the shared per-line
  fallback takes over.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, opts) do
    with {:ok, {source, target}} <- Translator.langs(opts) do
      Translator.http_post(
        @url,
        form: [client: "gtx", sl: source, tl: target, dt: "t", q: Enum.join(lines, "\n")],
        decode: &decode/1
      )
    end
  end

  defp decode([segments | _]) when is_list(segments) do
    if Enum.all?(segments, &match?([text | _] when is_binary(text), &1)) do
      {:ok, segments |> Enum.map(&hd/1) |> Enum.join("") |> Translator.split_trim()}
    else
      {:error, :unparsable}
    end
  end

  defp decode(_other), do: {:error, :unparsable}
end
