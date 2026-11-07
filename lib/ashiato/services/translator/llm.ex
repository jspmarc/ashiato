defmodule Ashiato.Translator.Llm do
  @moduledoc """
  OpenAI-compatible Responses API client.

  The page is requested as a JSON object with a `translations` array, enforced by
  a strict JSON schema. When the reply does not match that shape, the shared
  per-line fallback takes over. The endpoint comes from `OPENAI_BASE_URL`
  (default `https://api.openai.com/v1`) and the key from `OPENAI_API_KEY`.
  """
  use Ashiato.Translator

  @default_base_url "https://api.openai.com/v1"
  @default_model "gpt-4o-mini"

  @translation_schema %{
    type: "object",
    properties: %{
      translations: %{type: "array", items: %{type: "string"}}
    },
    required: ["translations"],
    additionalProperties: false
  }

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
      model = Keyword.get(opts, :model, @default_model)
      resp_url = String.trim_trailing(base_url, "/") <> "/responses"
      chat_url = String.trim_trailing(base_url, "/") <> "/chat/completions"
      headers = [{"authorization", "Bearer " <> key}]

      body = %{
        model: model,
        temperature: 0,
        input: [
          %{role: "system", content: system_prompt(target)},
          %{role: "user", content: "Translate these lines: " <> Jason.encode!(lines)}
        ],
        text: %{
          format: %{
            type: "json_schema",
            name: "translation",
            strict: true,
            schema: @translation_schema
          }
        }
      }

      case Translator.http_post(resp_url, headers: headers, json: body, decode: &decode/1) do
        {:ok, _} = ok ->
          ok

        {:error, {:http, status}} when status in [400, 404, 405] ->
          # Some backends do not implement /responses yet; retry via chat-completions.
          chat_body = %{
            model: model,
            temperature: 0,
            messages: [
              %{role: "system", content: system_prompt(target)},
              %{role: "user", content: "Translate these lines: " <> Jason.encode!(lines)}
            ],
            response_format: %{
              type: "json_schema",
              json_schema: %{
                name: "translation",
                strict: true,
                schema: @translation_schema
              }
            }
          }

          Translator.http_post(chat_url,
            headers: headers,
            json: chat_body,
            decode: &decode_chat/1
          )

        {:error, _reason} = err ->
          err
      end
    end
  end

  defp system_prompt(target) do
    "You are a translator. Translate every line into #{target}. " <>
      "Return the translations in order, exactly one per input line."
  end

  defp decode(%{"status" => "completed", "output" => output}) when is_list(output) do
    output
    |> Enum.find_value(&output_text/1)
    |> case do
      text when is_binary(text) -> parse_translations(text)
      _other -> {:error, :unparsable}
    end
  end

  defp decode(_other), do: {:error, :unparsable}

  defp output_text(%{"type" => "message", "content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "output_text", "text" => text} when is_binary(text) -> text
      _other -> nil
    end)
  end

  defp output_text(_item), do: nil

  defp decode_chat(%{
         "choices" => [
           %{"finish_reason" => "stop", "message" => %{"content" => text}} | _rest
         ]
       })
       when is_binary(text),
       do: parse_translations(text)

  defp decode_chat(_other), do: {:error, :unparsable}

  defp parse_translations(text) do
    case Jason.decode(text) do
      {:ok, %{"translations" => lines} = decoded}
      when map_size(decoded) == 1 and is_list(lines) ->
        valid_lines(lines)

      _other ->
        {:error, :unparsable}
    end
  end

  defp valid_lines(lines) do
    if Enum.all?(lines, &is_binary/1) do
      {:ok, Enum.map(lines, &String.trim/1)}
    else
      {:error, :unparsable}
    end
  end
end
