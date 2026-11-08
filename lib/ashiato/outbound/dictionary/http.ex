defmodule Ashiato.Dictionary.Http do
  @timeout 10_000
  @max_concurrency 8

  @moduledoc """
  HTTP client for `jp-dict-api`. `JP_DICT_API_URL` must be set; there is no default.

  Endpoints:

    * `GET /lookup/{term}` → `{"words": [...] | null, "kanji": {...} | null}`
    * `GET /version` → plain-text release identifier

  The API has no batch lookup, so `lookup_many/1` sends one request per term. An
  entry is the whole lookup reply, cached as the payload.

  Retries are off: one attempt per request. Each request has a total deadline of
  #{@timeout} ms, so a trickling reply cannot keep the call open indefinitely.
  """

  @behaviour Ashiato.Dictionary

  @impl true
  @doc """
  Looks up one term. A reply with neither words nor kanji is `{:error, :not_found}`.
  A reply that is not the documented object is a broken reply, not a `nil` result:
  caching `nil` would push a crash to the first map access, far from here.
  """
  @spec lookup(String.t()) :: {:ok, map()} | {:error, term()}
  def lookup(term) do
    case request("/lookup/" <> URI.encode(term, &URI.char_unreserved?/1)) do
      {:ok, %{"words" => words, "kanji" => kanji} = entry} ->
        cond do
          not valid_words?(words) -> {:error, :unexpected_response}
          not valid_kanji?(kanji) -> {:error, :unexpected_response}
          empty_reply?(words, kanji) -> {:error, :not_found}
          true -> {:ok, entry}
        end

      {:ok, _body} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @doc """
  Looks up many terms, one request per term, at most #{@max_concurrency} at a time.
  Returns `{:ok, map}` keyed by term, or the first error.
  """
  @spec lookup_many([String.t()]) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def lookup_many(terms) do
    Ashiato.Dictionary.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(terms, &fetch/1,
      max_concurrency: @max_concurrency,
      timeout: @timeout + 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, %{}}, fn
      {:ok, {term, {:ok, entry}}}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, term, entry)}}
      {:ok, {_term, {:error, reason}}}, _acc -> {:halt, {:error, reason}}
      {:exit, _reason}, _acc -> {:halt, {:error, :lookup_failed}}
    end)
  end

  @impl true
  @doc """
  The dictionary release identifier, read as plain text from `GET /version`.
  """
  @spec dict_version() :: {:ok, String.t()} | {:error, term()}
  def dict_version do
    case request("/version") do
      {:ok, body} when is_binary(body) ->
        case String.trim(body) do
          "" -> {:error, :unexpected_response}
          version -> {:ok, version}
        end

      {:ok, _body} ->
        {:error, :unexpected_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Catch inside the worker: an uncaught exception would put the term in an OTP crash
  # report before async_stream_nolink can turn it into a return value.
  defp fetch(term) do
    {term, lookup(term)}
  rescue
    _exception -> {term, {:error, :lookup_failed}}
  catch
    _kind, _reason -> {term, {:error, :lookup_failed}}
  end

  defp valid_words?(nil), do: true
  defp valid_words?(words) when is_list(words), do: Enum.all?(words, &is_map/1)
  defp valid_words?(_words), do: false

  defp valid_kanji?(nil), do: true
  defp valid_kanji?(kanji), do: is_map(kanji)

  defp empty_reply?(words, kanji), do: (is_nil(words) or words == []) and is_nil(kanji)

  @spec safe_reason(term()) :: atom()
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :unknown

  @spec request(String.t()) :: {:ok, term()} | {:error, term()}
  defp request(path) do
    with {:ok, base} <- base_url() do
      req = Req.new(Keyword.take(Application.get_env(:ashiato, Ashiato.Dictionary, []), [:plug]))

      case Req.request(req,
             url: base <> path,
             redirect: false,
             retry: false,
             receive_timeout: @timeout,
             request_timeout: @timeout
           ) do
        {:ok, %Req.Response{status: 200, body: body}} ->
          {:ok, body}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:unexpected_status, status}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, {:transport, safe_reason(reason)}}

        {:error, %{__exception__: true}} ->
          {:error, :unexpected_response}

        {:error, _reason} ->
          {:error, :transport_error}
      end
    end
  end

  @spec base_url() :: {:ok, String.t()} | {:error, :base_url_not_configured | :invalid_base_url}
  defp base_url do
    case Application.get_env(:ashiato, Ashiato.Dictionary, [])[:base_url] do
      nil ->
        {:error, :base_url_not_configured}

      url ->
        case URI.new(url) do
          {:ok, %URI{scheme: scheme, host: host, query: nil, fragment: nil}}
          when scheme in ["http", "https"] and host != nil and host != "" ->
            {:ok, String.trim_trailing(url, "/")}

          _ ->
            {:error, :invalid_base_url}
        end
    end
  end
end
