defmodule Ashiato.Schemas.User do
  @moduledoc """
  The users table.

  No auth yet (§6.2): a single default user is created by `priv/repo/seeds.exs`
  on first boot, and the context layer populates `user_id` everywhere. The
  columns exist so adding auth later needs no migration — only context changes.
  """

  use Ecto.Schema

  schema "users" do
    timestamps(type: :utc_datetime)
  end
end
