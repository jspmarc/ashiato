defmodule Ashiato.Dictionary do
  @moduledoc """
  Dictionary lookups behind a behaviour, plus a version-keyed cache façade.

  `lookup/1` and `lookup_many/1` are the public façade: they consult
  `Ashiato.Schemas.DictCacheEntry` first and only fall through to the service
  on a miss, so a cache hit never touches the network.

  The configured service is returned by `impl/0`, from
  `Application.get_env(:ashiato, Ashiato.Dictionary, [])[:impl]`, default
  `Ashiato.Dictionary.Http`. Callers depend on the behaviour, not a concrete
  module.

  ## Cache shape

  Rows are keyed `(kind, cache_key, dict_version)`. `cache_key` is the term;
  `dict_version` is what the service reports; `kind` derives from the term: a
  single CJK codepoint (U+4E00..U+9FFF) is a `"kanji"` entry, anything else a
  `"word"`. `payload` is the entry map, stored as-is.

  A row is either current or superseded wholesale, so there is no TTL. A version
  bump mutates nothing: old rows stop matching and a fresh row is inserted with
  the new version. `prune/0` deletes superseded rows once the new release is in
  use.

  The `dict_version/0` needed to build the key is memoised (`current_version/1`) and falls
  back to the newest `dict_version` already in the cache after a restart, so a cache hit
  makes no network call and keeps working while the service is down. Only a miss talks to
  the service. `refresh_version/0` re-reads the version from the service; the lookup path
  never asks for it once one is known.

  Callbacks are the raw service calls; `Http` and `Fake` implement them.
  """

  import Ecto.Query

  alias Ashiato.Repo
  alias Ashiato.Schemas.DictCacheEntry
  alias Ashiato.Utils

  @type entry :: map()

  @callback lookup(term :: String.t()) :: {:ok, entry()} | {:error, term()}
  @callback lookup_many(terms :: [String.t()]) ::
              {:ok, %{String.t() => entry()}} | {:error, term()}
  @callback dict_version() :: {:ok, String.t()} | {:error, term()}

  @doc """
  The configured service module. Callers depend on this indirection rather than
  on a concrete module.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:ashiato, __MODULE__, [])[:impl] || Ashiato.Dictionary.Http
  end

  @doc """
  Looks up one term: cache first, service on a miss. On a miss the entry is
  cached under the service's current `dict_version`; a lost insert race
  re-fetches the row the winning caller just wrote, so the entry is returned
  either way. A service error propagates without caching anything.
  """
  @spec lookup(String.t()) :: {:ok, entry()} | {:error, term()}
  def lookup(term) do
    impl = impl()

    with :ok <- validate_term(term),
         {:ok, dict_version} <- current_version(impl) do
      kind = kind_for(term)

      case Repo.get_by(
             DictCacheEntry,
             [kind: kind, cache_key: term, dict_version: dict_version],
             log: false
           ) do
        %DictCacheEntry{payload: payload} ->
          {:ok, payload}

        nil ->
          case impl.lookup(term) do
            {:ok, entry} ->
              entry = normalise(entry)
              # A cache write failure must not fail a lookup the service just answered: the
              # next call simply misses again.
              _ = cache_entry(kind, term, dict_version, entry)
              {:ok, entry}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc """
  Looks up many terms in one call: every term is checked against the cache, and
  only the misses go to the service (a fully cached batch makes no lookup
  calls). Returns `{:ok, map}` keyed by term. A service error for the missing
  terms propagates; cached entries alone are not returned in that case.
  """
  @spec lookup_many([String.t()]) :: {:ok, %{String.t() => entry()}} | {:error, term()}
  def lookup_many(terms) do
    impl = impl()

    with :ok <- validate_terms(terms),
         {:ok, dict_version} <- current_version(impl) do
      terms = Enum.uniq(terms)
      cached = cached_payloads(terms, dict_version)
      missing = Enum.reject(terms, &Map.has_key?(cached, &1))

      if missing == [] do
        {:ok, cached}
      else
        case impl.lookup_many(missing) do
          {:ok, entries} ->
            {:ok, Map.merge(cached, cache_missing(missing, entries, dict_version))}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  @doc """
  The `dict_version/0` the cache is keyed by, memoised so a cache hit makes no network call.

  The version is part of the cache key, so it has to be known before a row can be matched.
  Asking the service on every lookup would make a cache hit hit the network, and a cached
  word would become unavailable the moment the service went down. A cold memo therefore
  reads the newest `dict_version` already in the cache; only a database with no rows at all
  asks the service, and that call can never replace a cache hit.

  `refresh_version/0` changes the version; nothing on the lookup path does.
  """
  @spec current_version(module()) :: {:ok, String.t()} | {:error, term()}
  def current_version(impl) do
    key = version_key(impl)

    case :persistent_term.get(key, :cold) do
      {:ok, version} ->
        {:ok, version}

      :cold ->
        case newest_cached_version() do
          {:ok, version} ->
            :persistent_term.put(key, {:ok, version})
            {:ok, version}

          :error ->
            case impl.dict_version() do
              {:ok, version} ->
                :persistent_term.put(key, {:ok, version})
                {:ok, version}

              error ->
                error
            end
        end
    end
  end

  @doc """
  Asks the service for its current `dict_version/0` and memoises it.

  This is the only place the version is refreshed, so a new release never turns a cache hit
  into a network call. When the service is unreachable the last known version is kept and
  returned.

  The refreshed value lives in VM memory until the first row for the new version is written.
  A restart inside that window re-derives the previous version from the cache. A durable
  version store would remove that window.
  """
  @spec refresh_version() :: {:ok, String.t()} | {:error, term()}
  def refresh_version do
    impl = impl()
    key = version_key(impl)

    case impl.dict_version() do
      {:ok, version} ->
        :persistent_term.put(key, {:ok, version})
        {:ok, version}

      error ->
        case :persistent_term.get(key, :cold) do
          {:ok, version} ->
            {:ok, version}

          :cold ->
            case newest_cached_version() do
              {:ok, version} ->
                :persistent_term.put(key, {:ok, version})
                {:ok, version}

              :error ->
                error
            end
        end
    end
  end

  @doc """
  Drops the memoised `dict_version/0` so the next lookup re-derives it. Tests use this for
  isolation; the release check uses `refresh_version/0`.
  """
  @spec forget_version() :: :ok
  def forget_version do
    :persistent_term.erase(version_key(impl()))
    :ok
  end

  @doc """
  Deletes cached entries for every `dict_version` except the current one and returns the
  number of rows removed.

  A release bump keeps the old rows so they can still be served; call this once the new
  release is in use to reclaim the space.
  """
  @spec prune() :: {:ok, non_neg_integer()} | {:error, term()}
  def prune do
    with {:ok, version} <- current_version(impl()) do
      {count, _} =
        Repo.delete_all(from(e in DictCacheEntry, where: e.dict_version != ^version), log: false)

      {:ok, count}
    end
  end

  defp newest_cached_version do
    from(d in DictCacheEntry,
      order_by: [desc: d.fetched_at, desc: d.id],
      limit: 1,
      select: d.dict_version
    )
    |> Repo.all(log: false)
    |> case do
      [version] -> {:ok, version}
      [] -> :error
    end
  end

  # The store is VM-wide and the key includes the implementation, so a fake version set by
  # one test does not leak into the next and no per-user data ever lands here.
  defp version_key(impl), do: {__MODULE__, :dict_version, impl}

  # A term reaches this module from OCR and tokenizer output, so it can carry bytes that are
  # not valid UTF-8. Jason would raise while encoding the request body, breaking the
  # `{:error, term()}` contract on the ingest path.
  defp validate_term(term) when is_binary(term) do
    if String.valid?(term), do: :ok, else: {:error, :invalid_term}
  end

  defp validate_term(_term), do: {:error, :invalid_term}

  defp validate_terms(terms) when is_list(terms) do
    if Enum.all?(terms, &match?(:ok, validate_term(&1))), do: :ok, else: {:error, :invalid_term}
  end

  defp validate_terms(_terms), do: {:error, :invalid_term}

  # A fresh entry comes back with atom or string keys depending on the service; a cached
  # one always comes back from the JSON column string-keyed. Normalising before the entry
  # is cached and returned keeps one shape for callers.
  defp normalise(entry) when is_map(entry) do
    entry |> Jason.encode!() |> Jason.decode!()
  end

  # kind is half of the cache identity; deriving it from the term keeps the key deterministic.
  defp kind_for(term) do
    if Utils.cjk_codepoint?(term), do: :kanji, else: :word
  end

  defp cached_payloads(terms, dict_version) do
    from(e in DictCacheEntry,
      where: e.dict_version == ^dict_version and e.cache_key in ^terms,
      select: {e.kind, e.cache_key, e.payload}
    )
    |> Repo.all(log: false)
    |> Enum.reduce(%{}, fn {kind, term, payload}, acc ->
      if kind == kind_for(term), do: Map.put(acc, term, payload), else: acc
    end)
  end

  defp cache_missing(missing, entries, dict_version) do
    Enum.reduce(missing, %{}, fn term, acc ->
      case Map.fetch(entries, term) do
        {:ok, entry} ->
          entry = normalise(entry)
          # A failed cache write must not fail a batch the service just answered.
          _ = cache_entry(kind_for(term), term, dict_version, entry)
          Map.put(acc, term, entry)

        :error ->
          acc
      end
    end)
  end

  # House pattern (Ledger.find_or_create_lexeme/3): the unique_constraint
  # declaration turns a lost insert race into {:error, changeset}, and the
  # refetch finds the row the concurrent winner just wrote. Fields are set
  # programmatically, never cast.
  defp cache_entry(kind, cache_key, dict_version, payload) do
    %DictCacheEntry{}
    |> Ecto.Changeset.change(%{
      kind: kind,
      cache_key: cache_key,
      dict_version: dict_version,
      payload: payload,
      fetched_at: Utils.utc_now()
    })
    # keeps Ecto's default index name, matching both adapters
    |> Ecto.Changeset.unique_constraint([:kind, :cache_key, :dict_version])
    |> Repo.insert(log: false)
    |> case do
      {:ok, row} ->
        {:ok, row}

      {:error, changeset} ->
        case Repo.get_by(
               DictCacheEntry,
               [kind: kind, cache_key: cache_key, dict_version: dict_version],
               log: false
             ) do
          %DictCacheEntry{} = winner -> {:ok, winner}
          nil -> {:error, changeset}
        end
    end
  end
end
