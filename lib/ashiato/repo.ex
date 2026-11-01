defmodule Ashiato.Repo do
  use Ecto.Repo,
    adapter: Ecto.Adapters.SQLite3,
    otp_app: :ashiato
end
