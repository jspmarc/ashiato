defmodule Ashiato.ConfigTest do
  use ExUnit.Case, async: true

  test "test-env Oban engine matches the compiled repo adapter" do
    engine = Application.fetch_env!(:ashiato, Oban)[:engine]

    assert {engine, Ashiato.Repo.__adapter__()} in [
             {Oban.Engines.Lite, Ecto.Adapters.SQLite3},
             {Oban.Engines.Basic, Ecto.Adapters.Postgres}
           ]
  end

  test "prod config names Oban.Engines.Basic" do
    prod = Config.Reader.read!("config/prod.exs", env: :prod)
    oban = prod |> Keyword.fetch!(:ashiato) |> Keyword.fetch!(Oban)

    assert oban[:engine] == Oban.Engines.Basic
  end
end
