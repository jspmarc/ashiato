defmodule Ashiato.Translator.Llm do
  @moduledoc """
  OpenAI-compatible chat completions (D44) — the only provider that can use
  surrounding lines, speaker, and register.

  The page is asked for as a **JSON array of strings**. When the reply does not
  parse as an array, the shared per-line fallback takes over. The endpoint comes
  from `OPENAI_BASE_URL` (default `https://api.openai.com/v1`; any
  OpenAI-compatible server works, D11) and the key from `OPENAI_API_KEY`.
  """
  use Ashiato.Translator

  @default_base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"

  @doc """
  Options: `:model` — the model to request, default `"gpt-4o-mini"`.

  A missing or empty `OPENAI_API_KEY` returns `{:error, :not_configured}`; the key
  is only ever placed in the authorization header, never logged.
  """
  @spec page_request([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def page_request(lines, opts) do
    key = System.get_env("OPENAI_API_KEY")
    base_url = System.get_env("OPENAI_BASE_URL") || @default_base_url

    if Translator.configured?(key) do
      request(lines, opts, base_url, key)
    else
      {:error, :not_configured}
    end
  end

  defp request(lines, opts, base_url, key) do
    with {:ok, {_source, target}} <- Translator.langs(opts) do
      body = %{
        model: Keyword.get(opts, :model, @default_model),
        temperature: 0,
        messages: [
          %{role: "system", content: system_prompt(target)},
          %{
            role: "user",
            content: "Translate these lines (a JSON array): " <> Jason.encode!(lines)
          }
        ]
      }

      Translator.http_post(
        base_url <> "/chat/completions",
        headers: [{"authorization", "Bearer " <> key}],
        json: body,
        decode: &decode/1
      )
    end
  end

  defp system_prompt(target) do
    "You are a translator. Translate every line into #{target}. " <>
      "Reply with ONLY a JSON array of strings: the translations in order, " <>
      "exactly one per input line. No commentary, no code fences."
  end

  # A refusal or a tool-call reply carries `content: nil`; trimming it would raise in the
  # worker, so it is treated as unparsable and the per-line fallback takes over.
  defp decode(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    case parse_array(content) do
      {:ok, lines} when is_list(lines) ->
        if Enum.all?(lines, &is_binary/1) do
          {:ok, Enum.map(lines, &String.trim/1)}
        else
          {:error, :unparsable}
        end

      _other ->
        {:error, :unparsable}
    end
  end

  defp decode(_other), do: {:error, :unparsable}

  defp parse_array(content) do
    content
    |> String.trim()
    |> strip_fences()
    |> Jason.decode()
  end

  defp strip_fences("```" <> rest) do
    rest
    |> String.split("\n", parts: 2)
    |> List.last()
    |> String.trim()
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp strip_fences(text), do: text
end
