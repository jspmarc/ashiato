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
  must not silently rewrite what it claims you studied (P9). Note that building
  the cache key needs the service's `dict_version/0`, a cheap metadata call; the
  "no network on a cache hit" guarantee is about dictionary lookups, which is
  what `Ashiato.Dictionary.Fake.calls/0` counts.

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

    with {:ok, dict_version} <- impl.dict_version() do
      kind = kind_for(term)

      case Repo.get_by(DictCacheEntry, kind: kind, cache_key: term, dict_version: dict_version) do
        %DictCacheEntry{payload: payload} ->
          {:ok, payload}

        nil ->
          case impl.lookup(term) do
            {:ok, entry} ->
              with {:ok, _row} <- cache_entry(kind, term, dict_version, entry), do: {:ok, entry}

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

    with {:ok, dict_version} <- impl.dict_version() do
      terms = Enum.uniq(terms)
      cached = cached_payloads(terms, dict_version)
      missing = Enum.reject(terms, &Map.has_key?(cached, &1))

      fetched = if missing == [], do: {:ok, %{}}, else: impl.lookup_many(missing)

      case fetched do
        {:ok, entries} ->
          entries
          |> Enum.reduce_while({:ok, %{}}, fn {term, entry}, {:ok, acc} ->
            case cache_entry(kind_for(term), term, dict_version, entry) do
              {:ok, _row} -> {:cont, {:ok, Map.put(acc, term, entry)}}
              {:error, changeset} -> {:halt, {:error, changeset}}
            end
          end)
          |> merge_with(cached)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # kind is half of the cache identity, so deriving it from the term (one
  # codepoint → KANJIDIC2 shape, otherwise JMdict) keeps the key deterministic.
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

  @spec merge_with({:ok, %{String.t() => entry()}} | {:error, term()}, %{String.t() => entry()}) ::
          {:ok, %{String.t() => entry()}} | {:error, term()}
  defp merge_with({:ok, fresh}, cached), do: {:ok, Map.merge(cached, fresh)}
  defp merge_with({:error, reason}, _cached), do: {:error, reason}
end
