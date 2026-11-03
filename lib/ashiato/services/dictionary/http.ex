defmodule Ashiato.Dictionary.Http do
  @moduledoc """
  The real `jp-dict-api` client (§7.1). `JP_DICT_API_URL` must be set; there is
  no sensible default because the service does not exist yet.

  Endpoints:

    * `GET  /version`     → `{"version": "..."}`
    * `POST /lookup`      `{"term": ...}` → `{"entry": {...}}`
    * `POST /lookup_many` `{"terms": [...]}` → `{"entries": {term => entry}}`

  Retries are off on purpose: the app degrades to recording encounters without
  enrichments when the service is down (§7.1), so a retry would just stretch the
  degradation window without changing the outcome. Tests never call this module.
  """

  @behaviour Ashiato.Dictionary

  @impl true
  @spec lookup(String.t()) :: {:ok, map()} | {:error, term()}
  def lookup(term) do
    case request(:post, "/lookup", %{term: term}) do
      {:ok, %{"entry" => entry}} -> {:ok, entry}
      {:ok, _body} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec lookup_many([String.t()]) :: {:ok, %{String.t() => map()}} | {:error, term()}
  def lookup_many(terms) do
    case request(:post, "/lookup_many", %{terms: terms}) do
      {:ok, %{"entries" => entries}} when is_map(entries) -> {:ok, entries}
      {:ok, _body} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec dict_version() :: {:ok, String.t()} | {:error, term()}
  def dict_version do
    case request(:get, "/version", nil) do
      {:ok, %{"version" => version}} when is_binary(version) -> {:ok, version}
      {:ok, _body} -> {:error, :unexpected_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec request(:get | :post, String.t(), map() | nil) :: {:ok, term()} | {:error, term()}
  defp request(method, path, body) do
    with {:ok, base} <- base_url() do
      case call(method, base <> path, body) do
        {:ok, %Req.Response{status: 200, body: decoded}} -> {:ok, decoded}
        {:ok, %Req.Response{status: status}} -> {:error, {:unexpected_status, status}}
        {:error, exception} -> {:error, exception}
      end
    end
  end

  @spec call(:get | :post, String.t(), map() | nil) ::
          {:ok, Req.Response.t()} | {:error, term()}
  defp call(:get, url, nil), do: Req.get(url, retry: false)
  defp call(:post, url, body), do: Req.post(url, json: body, retry: false)

  @spec base_url() :: {:ok, String.t()} | {:error, :jp_dict_api_url_unset}
  defp base_url do
    case System.fetch_env("JP_DICT_API_URL") do
      {:ok, url} -> {:ok, String.trim_trailing(url, "/")}
      :error -> {:error, :jp_dict_api_url_unset}
    end
  end
end
