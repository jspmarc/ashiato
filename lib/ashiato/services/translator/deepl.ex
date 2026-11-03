defmodule Ashiato.Translator.Deepl do
  @moduledoc """
  DeepL v2 API. One request per page: the lines go out as a JSON `text` array and
  the aligned `translations` array comes back.

  A key ending in `:fx` is a free-tier key and uses `https://api-free.deepl.com`;
  every other key uses `https://api.deepl.com`.
  """
  use Ashiato.Translator

  @pro_url "https://api.deepl.com"
  @free_url "https://api-free.deepl.com"

  @doc """
  Options: `:api_key` — the DeepL auth key. Missing or empty returns
  `{:error, :not_configured}`; the key is only ever placed in the authorization
  header, never logged.
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
        %{text: lines, target_lang: String.upcase(target)}
        |> put_source(source)

      Translator.http_post(
        base_url(key) <> "/v2/translate",
        headers: [{"authorization", "DeepL-Auth-Key " <> key}],
        json: body,
        decode: &decode/1
      )
    end
  end

  defp put_source(body, "auto"), do: body
  defp put_source(body, source), do: Map.put(body, :source_lang, String.upcase(source))

  defp base_url(":fx" <> _rest), do: @free_url
  defp base_url(_key), do: @pro_url

  defp decode(%{"translations" => translations}) when is_list(translations) do
    if Enum.all?(translations, &match?(%{"text" => text} when is_binary(text), &1)) do
      {:ok, Enum.map(translations, &String.trim(&1["text"]))}
    else
      {:error, :unparsable}
    end
  end

  defp decode(_other), do: {:error, :unparsable}
end
