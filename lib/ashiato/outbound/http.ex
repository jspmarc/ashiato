defmodule Ashiato.HTTP do
  @moduledoc """
  The shared outbound transport: the only module that calls `Req`.

  Every outbound service sends its requests through `get/2` and `post/2`. This module owns the
  request policy — `retry: false`, because a retried POST can duplicate work, and
  `redirect: false`, because a redirect can send credentials to another host — and the
  deadlines: 10 000 ms receive and request timeouts unless the caller overrides them.

  Returned terms are safe to log: atoms, status integers, and `:unknown`. URLs, bodies,
  headers, credentials, and exception messages never appear in a returned term, and nothing
  here logs. Service reply shapes stay in the service clients.
  """

  @allowed_options [:headers, :json, :form, :params, :receive_timeout, :request_timeout, :plug]
  @default_timeout 10_000

  @doc """
  Sends a GET request. See the module documentation for the policy and error terms.
  """
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(url, opts \\ [])

  def get(url, _opts) when not is_binary(url), do: {:error, :invalid_url}
  def get(_url, opts) when not is_list(opts), do: {:error, :invalid_options}

  def get(url, opts) do
    if Keyword.keyword?(opts) do
      request(:get, url, opts)
    else
      {:error, :invalid_options}
    end
  end

  @doc """
  Sends a POST request. See the module documentation for the policy and error terms.
  """
  @spec post(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def post(url, opts \\ [])

  def post(url, _opts) when not is_binary(url), do: {:error, :invalid_url}
  def post(_url, opts) when not is_list(opts), do: {:error, :invalid_options}

  def post(url, opts) do
    if Keyword.keyword?(opts) do
      request(:post, url, opts)
    else
      {:error, :invalid_options}
    end
  end

  # The guards sit on the public heads so `URI.new/1` never receives a non-binary; the full
  # keyword check cannot be expressed as a guard, so it takes a body branch.
  defp request(method, url, opts) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        execute(method, url, opts)

      _ ->
        {:error, :invalid_url}
    end
  end

  defp req_opts(method, url, opts) do
    opts
    |> Keyword.take(@allowed_options)
    |> Keyword.put_new(:receive_timeout, @default_timeout)
    |> Keyword.put_new(:request_timeout, @default_timeout)
    |> Keyword.merge(retry: false, redirect: false, decoders: false)
    |> Keyword.put(:method, method)
    |> Keyword.put(:url, url)
  end

  defp execute(method, url, opts) do
    case Req.request(Req.new(req_opts(method, url, opts))) do
      {:ok, %Req.Response{status: 200} = response} ->
        decode_body(response)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, safe_reason(reason)}}

      {:error, %Req.HTTPError{reason: reason}} ->
        {:error, {:transport, safe_reason(reason)}}

      {:error, %Jason.DecodeError{}} ->
        {:error, :invalid_json}

      {:error, _exception} ->
        {:error, :request_failed}
    end
  rescue
    e in Req.TransportError -> {:error, {:transport, safe_reason(e.reason)}}
    e in Req.HTTPError -> {:error, {:transport, safe_reason(e.reason)}}
    _e in Jason.DecodeError -> {:error, :invalid_json}
    _exception -> {:error, :request_failed}
  end

  # An error term reaches logs; provider-controlled binaries stay out of it.
  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :unknown

  # Status mapping runs before decoding, so a broken non-200 body can never mask its status;
  # Req's own decode step is disabled (`decoders: false`) and only a 200 JSON body is decoded.
  defp decode_body(%Req.Response{body: body} = response) when is_binary(body) and body != "" do
    case Req.Response.get_header(response, "content-type") do
      [content_type | _rest] ->
        if json_media_type?(content_type) do
          case Jason.decode(body) do
            {:ok, decoded} -> {:ok, decoded}
            {:error, _} -> {:error, :invalid_json}
          end
        else
          {:ok, body}
        end

      _ ->
        {:ok, body}
    end
  end

  defp decode_body(%Req.Response{body: body}), do: {:ok, body}

  defp json_media_type?(content_type) do
    content_type
    |> String.split(";", limit: 2)
    |> Enum.at(0)
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 == "application/json" or String.ends_with?(&1, "+json")))
  end
end
