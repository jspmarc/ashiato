defmodule Ashiato.Repo do
  use Ecto.Repo,
    otp_app: :ashiato,
    adapter: Ecto.Adapters.SQLite3
end
