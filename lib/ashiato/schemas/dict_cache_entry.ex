defmodule Ashiato.DictCacheEntries do
  @moduledoc """
  Cached dictionary lookups — **global**, shared by all users (§6.3).

  Keyed by `(kind, cache_key, dict_version)`, unique: JMdict is immutable
  between releases, so an entry is either current or superseded wholesale when
  `dict_version` flips. That is also why there is no TTL: entries never go stale
  within a version.

  Migration deviation from the ERD (migration is authoritative): `payload` was
  created as a `:map` column (JSON as the adapter's serialisation), not a raw
  `text`, so the schema type is `:map`.
  """

  use Ecto.Schema

  schema "dict_cache_entries" do
    field :kind, Ecto.Enum, values: [:word, :kanji]
    field :cache_key, :string
    field :dict_version, :string
    field :payload, :map
    field :fetched_at, :utc_datetime
  end
end
