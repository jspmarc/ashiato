defmodule Ashiato.SchemaTest do
  @moduledoc """
  The schemas and the database must agree.

  Ecto does not check a schema against its table at compile time, so a field
  naming a column the migration never created compiles cleanly and then fails on
  the first query with `no such column`. That cost a debugging round when `bbox`
  outlived the migration that removed it, so it gets a test.

  The column list is read with `SELECT * ... LIMIT 0` rather than
  `PRAGMA table_info` or `information_schema`, which keeps the test
  dialect-agnostic and therefore still meaningful if this project moves to
  Postgres.
  """

  use Ashiato.DataCase

  @schemas [
    Ashiato.Schemas.User,
    Ashiato.Schemas.Lexeme,
    Ashiato.Schemas.Setting,
    Ashiato.Schemas.DictCacheEntry,
    Ashiato.Schemas.Source,
    Ashiato.Schemas.Document,
    Ashiato.Schemas.Page,
    Ashiato.Schemas.Word,
    Ashiato.Schemas.Encounter,
    Ashiato.Schemas.ReviewEvent,
    Ashiato.Schemas.WordState
  ]

  defp table_columns(table) do
    # Compare as strings: a stray column may have no atom in this VM.
    %{columns: columns} = Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM #{table} LIMIT 0", [])
    Enum.sort(columns)
  end

  defp schema_columns(module) do
    virtual = module.__schema__(:virtual_fields)

    module.__schema__(:fields)
    |> Kernel.--(virtual)
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  test "every schema field exists as a column in its table, and vice versa" do
    for module <- @schemas do
      table = module.__schema__(:source)
      in_schema = schema_columns(module)
      in_table = table_columns(table)

      assert in_schema == in_table, """
      #{inspect(module)} and table "#{table}" disagree.
        only in the schema: #{inspect(in_schema -- in_table)}
        only in the table:  #{inspect(in_table -- in_schema)}
      """
    end
  end

  test "every table named by a schema actually exists" do
    for module <- @schemas do
      table = module.__schema__(:source)
      assert table_columns(table) != [], "table #{inspect(table)} exists but has no columns"
    end
  end
end
