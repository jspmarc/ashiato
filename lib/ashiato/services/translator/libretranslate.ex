defmodule Ashiato.Translator.LibreTranslate do
  @moduledoc """
  Self-hosted LibreTranslate — fully offline, weakest quality (§7.5). One request
  per page: `q` goes out as an array and `translatedText` comes back as an aligned
  array.
  """
  use Ashiato.Translator

  @doc """
  Options: `:base_url` — instance root, e.g. `"https://lt.example.com"`; missing or
  empty returns `{:error, :not_configured}`. `:api_key` — optional; self-hosted
  instances often need none.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, opts) do
    base_url = Keyword.get(opts, :base_url)

    if Translator.configured?(base_url) do
      request(lines, opts, base_url)
    else
      {:error, :not_configured}
    end
  end

  defp request(lines, opts, base_url) do
    with {:ok, {source, target}} <- Translator.langs(opts) do
      body =
        %{q: lines, source: source, target: target, format: "text"}
        |> put_key(Keyword.get(opts, :api_key))

      Translator.http_post(
        String.trim_trailing(base_url, "/") <> "/translate",
        json: body,
        decode: &decode/1
      )
    end
  end

  defp put_key(body, key) do
    if Translator.configured?(key), do: Map.put(body, :api_key, key), else: body
  end

  defp decode(%{"translatedText" => text}) when is_list(text) do
    if Enum.all?(text, &is_binary/1) do
      {:ok, Enum.map(text, &String.trim/1)}
    else
      {:error, :unparsable}
    end
  end

  defp decode(_other), do: {:error, :unparsable}
end
