defmodule Ashiato.Repo do
  use Ecto.Repo,
    otp_app: :ashiato,
    adapter: Application.compile_env!(:ashiato, :ecto_adapter)
end
