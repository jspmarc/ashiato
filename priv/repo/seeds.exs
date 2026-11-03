# Bootstrap seeds: safe to re-run.
#
# Idempotent by existence checks, not upserts, because the default source has
# `name IS NULL` and `sources_user_id_name_chapter_index` is a partial index
# exempting NULL names — the database cannot stop a second default source, so we
# check first. Running twice leaves exactly one user and one default source.

import Ecto.Query

alias Ashiato.Repo
alias Ashiato.Schemas.Source
alias Ashiato.Schemas.User

# §6.2: no auth — a single default user is created on first boot, and the
# context layer populates user_id.
user =
  case Repo.one(Users) do
    nil -> Repo.insert!(%Users{})
    user -> user
  end

# The default source: name NULL, chapter "" (matching the database default),
# kind :other. This is the unsorted / real-world bucket, displayed as 現実世界,
# and it exists so every page — which requires a source_id — is never
# unsourced. One per user, by construction.
default_source =
  from(s in Sources,
    where: s.user_id == ^user.id and is_nil(s.name),
    limit: 1,
    select: s
  )
  |> Repo.one()

default_source =
  default_source ||
    Repo.insert!(%Sources{user_id: user.id, name: nil, chapter: "", kind: :other})

IO.puts("Seeds: user ##{user.id} with default source ##{default_source.id} (現実世界) in place.")
