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

  test "prod config schedules the prune worker daily at 03:00 UTC" do
    prod = Config.Reader.read!("config/prod.exs", env: :prod)
    oban = prod |> Keyword.fetch!(:ashiato) |> Keyword.fetch!(Oban)

    assert [{Oban.Plugins.Cron, cron_opts}] = Keyword.fetch!(oban, :plugins)

    assert {"0 3 * * *", Ashiato.TranslatorService.PruneWorker} in Keyword.fetch!(
             cron_opts,
             :crontab
           )
  end

  test "test-env Oban config has no Cron plugin" do
    oban = Application.fetch_env!(:ashiato, Oban)

    refute Enum.any?(Keyword.get(oban, :plugins, []), &match?({Oban.Plugins.Cron, _}, &1))
  end
end
