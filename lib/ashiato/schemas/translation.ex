defmodule Ashiato.Schemas.Translation do
  @moduledoc """
  Cached provider translations — **global**, shared by all users.

  Keyed by `(provider, lang, source_hash)`, unique, and provider-scoped:
  switching provider never reads another provider's rows. `source_hash` is the
  lowercase hex SHA-256 of the source line, so no source text column exists.
  Unlike `dict_cache_entries` the rows are mutable and expire: 30 days after
  `fetched_at` a row is stale — ignored on read and replaced for the page's
  keys — and the prune worker deletes it.
  """

  use Ecto.Schema

  schema "translations" do
    field :provider, :string
    field :lang, :string
    field :source_hash, :string
    field :translated_text, :string
    field :fetched_at, :utc_datetime
  end
end
