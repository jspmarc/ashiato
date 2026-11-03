defmodule Ashiato.Dictionary do
  @moduledoc """
  Dictionary lookups (§7.1, `jp-dict-api`) behind a behaviour, plus the
  version-keyed cache façade (P9, §6.9) in front of it.

  **Wave 3 and later: call `Ashiato.Dictionary.lookup/1` / `lookup_many/1`.
  Never call a concrete service module.** Those two functions are the public
  façade: they consult `Ashiato.Schemas.DictCacheEntry` first and only fall
  through to the service on a miss, so a cache hit never touches the network.

  This card deviates from the shared `impl/0` convention of
  `docs/plan/wave-2.md`: the configured service is returned by `service/0`
  (from `Application.get_env(:ashiato, Ashiato.Dictionary, [])[:service]`,
  default `Ashiato.Dictionary.Http`). The difference is in name only; callers
  still depend on the behaviour, not a concrete module.

  ## Cache shape

  Rows are keyed `(kind, cache_key, dict_version)` — the unique index in the
  migration. `cache_key` is the term; `dict_version` is what the service
  reports; `kind` derives from the term: a single CJK codepoint is a `"kanji"`
  entry (KANJIDIC2 data), anything else a `"word"` (JMdict data). `payload` is
  the entry map, stored as-is.

  There is no TTL (§6.9): JMdict is immutable between releases, so a row is
  either current or superseded wholesale. **A version bump mutates nothing** —
  old rows simply stop matching and a fresh row is inserted, because the ledger
  must not silently rewrite what it claims you studied (P9).

  The `dict_version/0` needed to build the key is memoised (`current_version/1`), so a
  cache hit makes no network call and keeps working while the service is down. Only a
  miss talks to the service.

  Callbacks are the raw service calls; `Http` and `Fake` implement them.
  """

  import Ecto.Query

  alias Ashiato.Repo
  alias Ashiato.Schemas.DictCacheEntry
  alias Ashiato.Utils

  @type entry :: map()

  # How long a fetched `dict_version` is trusted before the service is asked again. Long
  # enough that a page's worth of lookups asks once, short enough that a JMdict release is
  # picked up without a restart.
  @version_ttl_ms 300_000

  @callback lookup(term :: String.t()) :: {:ok, entry()} | {:error, term()}
  @callback lookup_many(terms :: [String.t()]) ::
              {:ok, %{String.t() => entry()}} | {:error, term()}
  @callback dict_version() :: {:ok, String.t()} | {:error, term()}

  @doc """
  The configured service module — this card's `impl/0` equivalent. See the
  moduledoc for why the name differs from the other wave-2 cards.
  """
  @spec service() :: module()
  def service do
    :ashiato
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:service, Ashiato.Dictionary.Http)
  end

  @doc """
  Looks up one term: cache first, service on a miss. On a miss the entry is
  cached under the service's current `dict_version`; a lost insert race
  re-fetches the row the winning caller just wrote, so the entry is returned
  either way. A service error propagates without caching anything.
  """
  @spec lookup(String.t()) :: {:ok, entry()} | {:error, term()}
  def lookup(term) do
    impl = service()

    with :ok <- validate_term(term),
         {:ok, dict_version} <- current_version(impl) do
      kind = kind_for(term)

      case Repo.get_by(DictCacheEntry, kind: kind, cache_key: term, dict_version: dict_version) do
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
    impl = service()

    with :ok <- validate_terms(terms),
         {:ok, dict_version} <- current_version(impl) do
      terms = Enum.uniq(terms)
      cached = cached_payloads(terms, dict_version)
      missing = Enum.reject(terms, &Map.has_key?(cached, &1))

      fetched = if missing == [], do: {:ok, %{}}, else: impl.lookup_many(missing)

      case fetched do
        {:ok, entries} ->
          fresh =
            Map.new(entries, fn {term, entry} ->
              entry = normalise(entry)
              # Same rule as lookup/1: a failed cache write must not fail the batch.
              _ = cache_entry(kind_for(term), term, dict_version, entry)
              {term, entry}
            end)

          {:ok, Map.merge(cached, fresh)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  The service's `dict_version/0`, memoised so a cache hit makes no network call.

  The version is part of the cache key, so it has to be known before a row can be matched.
  Asking the service on every lookup would mean a cache hit still hit the network — and a
  cached word would become unavailable the moment the service went down, which is the
  opposite of the degradation §7.1 asks for. The memo expires after #{@version_ttl_ms} ms;
  when the service is unreachable the last known version is reused for as long as it takes.

  The scheduled JMdict release check (§6.9) and tests call `forget_version/0` to pick up a
  new release immediately instead of waiting for the expiry.
  """
  @spec current_version(module()) :: {:ok, String.t()} | {:error, term()}
  def current_version(impl) do
    now = System.monotonic_time(:millisecond)

    key = version_key(impl)

    case :persistent_term.get(key, nil) do
      {version, fetched_at} when now - fetched_at < @version_ttl_ms ->
        {:ok, version}

      memo ->
        case impl.dict_version() do
          {:ok, version} ->
            :persistent_term.put(key, {version, now})
            {:ok, version}

          error ->
            # Stale-but-usable beats unavailable, and the memo's timestamp is refreshed so
            # an outage costs one failed version call per TTL, not one per lookup.
            case memo do
              {version, _fetched_at} ->
                :persistent_term.put(key, {version, now})
                {:ok, version}

              nil ->
                error
            end
        end
    end
  end

  @doc """
  Drops the memoised `dict_version/0`, so the next lookup asks the service again.

  Called by the scheduled release check and by tests; nothing on the request path needs it.
  """
  @spec forget_version() :: :ok
  def forget_version do
    :persistent_term.erase(version_key(service()))
    :ok
  end

  # Keyed by implementation: a fake version set by one test must not leak into the next
  # through the VM-wide persistent_term store.
  defp version_key(impl), do: {__MODULE__, impl, :dict_version}

  # A term reaches this module from OCR and tokenizer output, so it can carry bytes that are
  # not valid UTF-8. Jason would raise while encoding the request body, breaking the
  # `{:error, term()}` contract on the ingest path.
  @spec validate_term(String.t()) :: :ok | {:error, :invalid_term}
  defp validate_term(term) when is_binary(term) do
    if String.valid?(term), do: :ok, else: {:error, :invalid_term}
  end

  defp validate_term(_term), do: {:error, :invalid_term}

  @spec validate_terms([String.t()]) :: :ok | {:error, :invalid_term}
  defp validate_terms(terms) when is_list(terms) do
    if Enum.all?(terms, &match?(:ok, validate_term(&1))), do: :ok, else: {:error, :invalid_term}
  end

  defp validate_terms(_terms), do: {:error, :invalid_term}

  # kind is half of the cache identity, so deriving it from the term (one
  # codepoint → KANJIDIC2 shape, otherwise JMdict) keeps the key deterministic.
  # A fresh entry comes back with atom or string keys depending on the service; a cached
  # one always comes back from the JSON column string-keyed. Wave 3 must see one shape, so
  # the service's entry is normalised before it is both cached and returned.
  @spec normalise(entry()) :: entry()
  defp normalise(entry) when is_map(entry) do
    entry |> Jason.encode!() |> Jason.decode!()
  end

  @spec kind_for(String.t()) :: :word | :kanji
  defp kind_for(term) do
    if Utils.cjk_codepoint?(term), do: :kanji, else: :word
  end

  @spec cached_payloads([String.t()], String.t()) :: %{String.t() => entry()}
  defp cached_payloads(terms, dict_version) do
    from(e in DictCacheEntry,
      where: e.dict_version == ^dict_version and e.cache_key in ^terms,
      select: {e.cache_key, e.payload}
    )
    |> Repo.all()
    |> Map.new()
  end

  # House pattern (Ledger.find_or_create_lexeme/3): the unique_constraint
  # declaration turns a lost insert race into {:error, changeset}, and the
  # refetch finds the row the concurrent winner just wrote. Fields are set
  # programmatically, never cast.
  @spec cache_entry(:word | :kanji, String.t(), String.t(), entry()) ::
          {:ok, DictCacheEntry.t()} | {:error, Ecto.Changeset.t()}
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
    |> Repo.insert()
    |> case do
      {:ok, row} ->
        {:ok, row}

      {:error, changeset} ->
        case Repo.get_by(DictCacheEntry,
               kind: kind,
               cache_key: cache_key,
               dict_version: dict_version
             ) do
          %DictCacheEntry{} = winner -> {:ok, winner}
          nil -> {:error, changeset}
        end
    end
  end
end
