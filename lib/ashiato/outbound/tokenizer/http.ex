defmodule Ashiato.Tokenizer.Http do
  @behaviour Ashiato.Tokenizer

  alias Ashiato.Utils

  @moduledoc """
  HTTP client for the tokenizer endpoint on `jp-dict-api` (docs/requirements.md §7.2).

  One `Ashiato.HTTP.post/2` to `{base_url}/tokenize` with a `{"text": ...}` JSON body, expecting a reply of
  the shape `{"tokens": [{"surface" => ..., "lemma" => ..., "reading" => ..., "part_of_speech" => ...}]}`.
  The base URL comes from application config (`:base_url` under `Ashiato.Tokenizer`), populated
  from `JP_DICT_API_URL` in `config/runtime.exs`.

  Readings are normalised to hiragana **here**, not in the service: SudachiPy emits katakana and
  lexeme identity is `lemma + reading`, so an unconverted reading would mint a second row for a
  word the ledger already knows (§6.1).
  """

  @impl true
  @doc """
  Posts `text` to the tokenizer and maps the reply onto `t:Ashiato.Tokenizer.token/0` maps.

  A non-200 reply, a malformed envelope, one malformed token, a transport failure, or an
  undecodable body each come back as `{:error, term()}`: this runs on the ingest pipeline, where
  raising would take the caller's supervision tree down over a bad service reply.
  """
  @spec tokenize(String.t()) :: {:ok, [Ashiato.Tokenizer.token()]} | {:error, term()}
  def tokenize(text) do
    with {:ok, base_url} <- base_url(),
         {:ok, body} <- Ashiato.HTTP.post(request_url(base_url), request_opts(text)) do
      parse(body)
    end
  end

  defp request_url(base_url), do: String.trim_trailing(base_url, "/") <> "/tokenize"

  # `:plug` is never set in production; tests inject a test plug through it so the mapping
  # is exercised without a socket.
  defp request_opts(text) do
    Application.get_env(:ashiato, Ashiato.Tokenizer, [])
    |> Keyword.take([:plug])
    |> Keyword.put(:json, %{text: text})
  end

  defp base_url do
    case Application.get_env(:ashiato, Ashiato.Tokenizer, [])[:base_url] do
      nil -> {:error, :base_url_not_configured}
      base_url -> {:ok, base_url}
    end
  end

  defp parse(body) do
    case body do
      # the envelope is part of the contract too: a 200 without a token list is a broken
      # reply, not an empty page, and must not record zero encounters silently.
      %{"tokens" => tokens} when is_list(tokens) -> parse_tokens(tokens)
      _ -> {:error, {:malformed_reply, shape(body)}}
    end
  end

  defp parse_tokens(tokens) do
    tokens
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case parse_token(entry) do
        {:ok, token} -> {:cont, {:ok, [token | acc]}}
        :error -> {:halt, {:error, {:malformed_token, index}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = error -> error
    end
  end

  defp parse_token(%{
         "surface" => surface,
         "lemma" => lemma,
         "reading" => reading,
         "part_of_speech" => part_of_speech
       })
       when is_binary(surface) and is_binary(lemma) and is_binary(reading) and
              is_binary(part_of_speech) do
    {:ok,
     %{
       surface: surface,
       lemma: lemma,
       reading: Utils.to_hiragana(reading),
       part_of_speech: part_of_speech
     }}
  end

  # A token missing a field would otherwise raise inside Utils.to_hiragana/1 and crash the
  # caller instead of naming the bad entry.
  defp parse_token(_entry), do: :error

  # An error term reaches logs, and a reply here can be a whole page of the user's text.
  # The map size is enough to debug a provider that changed its contract; neither the content
  # nor provider-controlled keys are something to write down.
  defp shape(body) when is_map(body), do: {:map, map_size(body)}
  defp shape(_body), do: :not_an_object
end
