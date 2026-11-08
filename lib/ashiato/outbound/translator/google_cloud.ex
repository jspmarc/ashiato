defmodule Ashiato.Translator.GoogleCloud do
  @moduledoc """
  Cloud Translation v2 — the official, supported contract for the engine behind
  `google_free`. One request per page: the lines go out as a `q` array and the
  aligned `translations` array comes back.
  """
  use Ashiato.Translator

  @url "https://translation.googleapis.com/language/translate/v2"

  @doc """
  Options: `:api_key` — a Cloud Translation key. Missing or empty returns
  `{:error, :not_configured}`; the key only travels as a request parameter and is
  never logged.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, opts) do
    key = Keyword.get(opts, :api_key)

    if Translator.configured?(key) do
      request(lines, opts, key)
    else
      {:error, :not_configured}
    end
  end

  defp request(lines, opts, key) do
    with {:ok, {source, target}} <- Translator.langs(opts) do
      body =
        %{q: lines, target: target, format: "text"}
        |> put_source(source)

      Translator.http_post(
        @url,
        params: [key: key],
        json: body,
        decode: &decode/1
      )
    end
  end

  defp put_source(body, "auto"), do: body
  defp put_source(body, source), do: Map.put(body, :source, source)

  defp decode(%{"data" => %{"translations" => translations}}) when is_list(translations) do
    if Enum.all?(translations, &match?(%{"translatedText" => text} when is_binary(text), &1)) do
      {:ok, Enum.map(translations, &(String.trim(&1["translatedText"]) |> unescape()))}
    else
      {:error, :unparsable}
    end
  end

  defp decode(_other), do: {:error, :unparsable}

  # The v2 API HTML-escapes some entities even when format is "text".
  defp unescape(text) do
    text
    |> String.replace("&#39;", "'")
    |> String.replace("&quot;", "\"")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
