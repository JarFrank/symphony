defmodule SymphonyElixir.Feature.Store do
  @moduledoc "SQLite journal with short writer transactions."
  alias Exqlite.Sqlite3

  @spec init(Path.t()) :: :ok
  def init(path) do
    File.mkdir_p!(Path.dirname(path))

    transaction(path, fn db ->
      execute(db, "CREATE TABLE IF NOT EXISTS features (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, state_json TEXT NOT NULL)")

      execute(
        db,
        "CREATE TABLE IF NOT EXISTS attempts (feature_id TEXT NOT NULL REFERENCES features(id), revision INTEGER NOT NULL, status TEXT NOT NULL, result_json TEXT, attempt_id TEXT, input_json TEXT, execution_id TEXT, execution_owner TEXT, PRIMARY KEY(feature_id, revision))"
      )

      migrate_attempts!(db)

      execute(
        db,
        "CREATE TABLE IF NOT EXISTS process_executions (execution_id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL, feature_id TEXT NOT NULL, attempt_revision INTEGER NOT NULL, unit_name TEXT NOT NULL UNIQUE, status TEXT NOT NULL, invocation_id TEXT, control_group TEXT, main_pid INTEGER)"
      )

      migrate_process_executions!(db)

      execute(
        db,
        "CREATE TABLE IF NOT EXISTS effects (feature_id TEXT NOT NULL REFERENCES features(id), operation_key TEXT NOT NULL, status TEXT NOT NULL, intent_json TEXT NOT NULL, result_json TEXT, feature_revision INTEGER NOT NULL, PRIMARY KEY(feature_id, operation_key))"
      )

      :ok
    end)
  end

  defp migrate_attempts!(db) do
    columns = execute(db, "PRAGMA table_info(attempts)") |> Enum.map(&Enum.at(&1, 1))

    for {name, definition} <- [{"attempt_id", "TEXT"}, {"input_json", "TEXT"}, {"execution_id", "TEXT"}, {"execution_owner", "TEXT"}], name not in columns do
      execute(db, "ALTER TABLE attempts ADD COLUMN #{name} #{definition}")
    end

    execute(db, "UPDATE attempts SET attempt_id = feature_id || ':' || revision WHERE attempt_id IS NULL")
    execute(db, "CREATE UNIQUE INDEX IF NOT EXISTS attempts_attempt_id_idx ON attempts(attempt_id)")
  end

  defp migrate_process_executions!(db) do
    columns = execute(db, "PRAGMA table_info(process_executions)") |> Enum.map(&Enum.at(&1, 1))

    for {name, definition} <- [{"sandbox_output", "TEXT"}, {"auth_dir", "TEXT"}], name not in columns do
      execute(db, "ALTER TABLE process_executions ADD COLUMN #{name} #{definition}")
    end
  end

  @spec transaction(Path.t(), (reference() -> term())) :: term()
  def transaction(path, fun) do
    {:ok, db} = Sqlite3.open(path)

    try do
      execute(db, "PRAGMA foreign_keys = ON")
      execute(db, "BEGIN IMMEDIATE")
      result = fun.(db)
      execute(db, "COMMIT")
      result
    after
      Sqlite3.close(db)
    end
  end

  @spec execute(reference(), String.t(), list()) :: list()
  def execute(db, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(stmt, params)
      rows(db, stmt, [])
    after
      Sqlite3.release(db, stmt)
    end
  end

  defp rows(db, stmt, acc) do
    case Sqlite3.step(db, stmt) do
      {:row, row} -> rows(db, stmt, [row | acc])
      :done -> Enum.reverse(acc)
      :busy -> raise "SQLite writer busy"
      {:error, reason} -> raise "SQLite: #{inspect(reason)}"
    end
  end

  @spec fetch(reference(), String.t()) :: map()
  def fetch(db, id) do
    [[revision, json]] = execute(db, "SELECT revision, state_json FROM features WHERE id = ?", [id])
    Map.put(Jason.decode!(json), "revision", revision)
  end

  @spec save(reference(), String.t(), non_neg_integer(), map()) :: map()
  def save(db, id, revision, state) do
    execute(db, "UPDATE features SET revision = revision + 1, state_json = ? WHERE id = ? AND revision = ?", [Jason.encode!(Map.delete(state, "revision")), id, revision])

    case execute(db, "SELECT changes()") do
      [[1]] -> Map.put(state, "revision", revision + 1)
      _ -> raise ArgumentError, "stale revision"
    end
  end
end
