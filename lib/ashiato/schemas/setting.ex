defmodule Ashiato.Schemas.Setting do
  @moduledoc """
  One row per user setting, `(user_id, key)` unique (erd.dbml).

  Key-value rather than a column per setting, on purpose: the schema is still
  moving and a settings UI must not mean a migration per toggle. `value` is
  JSON-encoded at the boundary of whichever module manages settings later;
  `secret` marks rows that hold API keys, which are encrypted at rest with a key
  derived from `SECRET_KEY_BASE` and never logged.
  """

  use Ecto.Schema

  schema "settings" do
    belongs_to :user, Ashiato.Schemas.User

    field :key, :string
    # text column → :string, per the AGENTS.md house rule
    field :value, :string
    field :secret, :boolean, default: false

    timestamps(type: :utc_datetime)
  end
end
