excluded = if System.get_env("ASHIATO_TEST_ADAPTER") == "postgres", do: [], else: [:postgres]

ExUnit.start(exclude: excluded)
Ecto.Adapters.SQL.Sandbox.mode(Ashiato.Repo, :manual)
