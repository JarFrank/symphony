defmodule SymphonyElixir.Feature.StoreTest do
  use ExUnit.Case, async: true

  alias Exqlite.Sqlite3
  alias SymphonyElixir.Feature.Store

  setup do
    dir = Path.join(System.tmp_dir!(), "feature-store-#{System.unique_integer([:positive])}")
    db = Path.join(dir, "state.sqlite3")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: db}
  end

  test "an empty database initializes the current runtime and schema version", %{db: db} do
    assert :ok = Store.init(db)
    assert :ok = Store.ensure_compatible(db)

    assert Store.read(db, fn conn ->
             Store.execute(conn, "SELECT runtime_version, schema_version FROM runtime_metadata")
           end) == [[Store.runtime_version(), Store.schema_version()]]
  end

  test "a current-version database reopens normally", %{db: db} do
    assert :ok = Store.init(db)
    assert :ok = Store.init(db)
    assert :ok = Store.ensure_compatible(db)
  end

  test "an unversioned experimental journal fails closed and remains unchanged", %{db: db} do
    raw_execute(db, "CREATE TABLE features (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, state_json TEXT NOT NULL)")
    raw_execute(db, "INSERT INTO features VALUES ('legacy', 19, '{}')")
    before = File.read!(db)

    assert {:error, :incompatible_runtime_version} = Store.init(db)
    assert {:error, :incompatible_runtime_version} = Store.ensure_compatible(db)
    assert File.read!(db) == before
  end

  defp raw_execute(path, sql) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, [])
      :done = Sqlite3.step(db, statement)
    after
      Sqlite3.release(db, statement)
      Sqlite3.close(db)
    end
  end
end
