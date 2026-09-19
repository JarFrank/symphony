defmodule SymphonyElixir.Feature.Store do
  @moduledoc "SQLite journal with short writer transactions."
  alias Exqlite.Sqlite3

  @runtime_version 1
  @schema_version 1

  @doc "Initializes an empty journal or applies technical migrations to this runtime version."
  @spec init(Path.t()) :: :ok | {:error, :incompatible_runtime_version}
  def init(path) do
    File.mkdir_p!(Path.dirname(path))

    {:ok, db} = Sqlite3.open(path)

    try do
      execute(db, "PRAGMA foreign_keys = ON")

      case runtime_status(db) do
        :empty ->
          initialize_current_runtime!(db)
          :ok

        :current ->
          migrate_current_runtime!(db)
          :ok

        :incompatible ->
          {:error, :incompatible_runtime_version}
      end
    rescue
      _ -> {:error, :incompatible_runtime_version}
    after
      Sqlite3.close(db)
    end
  end

  @doc "Checks journal compatibility without initializing or changing it."
  @spec ensure_compatible(Path.t()) :: :ok | {:error, :incompatible_runtime_version}
  def ensure_compatible(path) do
    if File.exists?(path) do
      case Sqlite3.open(path) do
        {:ok, db} ->
          try do
            if runtime_status(db) == :current, do: :ok, else: {:error, :incompatible_runtime_version}
          rescue
            _ -> {:error, :incompatible_runtime_version}
          after
            Sqlite3.close(db)
          end

        _ ->
          {:error, :incompatible_runtime_version}
      end
    else
      {:error, :incompatible_runtime_version}
    end
  end

  @spec runtime_version() :: pos_integer()
  def runtime_version, do: @runtime_version

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  defp initialize_current_runtime!(db) do
    execute(db, "BEGIN IMMEDIATE")

    try do
      execute(
        db,
        "CREATE TABLE runtime_metadata (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), runtime_version INTEGER NOT NULL, schema_version INTEGER NOT NULL)"
      )

      execute(db, "INSERT INTO runtime_metadata (singleton, runtime_version, schema_version) VALUES (1, ?, ?)", [@runtime_version, @schema_version])
      create_or_migrate_current_schema!(db)
      execute(db, "COMMIT")
    rescue
      error ->
        execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end

  defp migrate_current_runtime!(db) do
    execute(db, "BEGIN IMMEDIATE")

    try do
      create_or_migrate_current_schema!(db)
      execute(db, "COMMIT")
    rescue
      error ->
        execute(db, "ROLLBACK")
        reraise error, __STACKTRACE__
    end
  end

  # These are technical migrations within the explicitly supported v1 journal.
  # A journal without the v1 metadata row is deliberately not a migration input.
  defp create_or_migrate_current_schema!(db) do
    execute(db, "CREATE TABLE IF NOT EXISTS features (id TEXT PRIMARY KEY, revision INTEGER NOT NULL, state_json TEXT NOT NULL)")

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS attempts (feature_id TEXT NOT NULL REFERENCES features(id), revision INTEGER NOT NULL, status TEXT NOT NULL, result_json TEXT, attempt_id TEXT, input_json TEXT, execution_id TEXT, execution_owner TEXT, PRIMARY KEY(feature_id, revision))"
    )

    migrate_attempts!(db)

    # `attempts` is the current pointer for a logical role attempt.  Keep a
    # separate append-only execution journal so a technical replacement does
    # not erase the concrete execution it superseded.
    execute(
      db,
      "CREATE TABLE IF NOT EXISTS role_executions (execution_id TEXT PRIMARY KEY, feature_id TEXT NOT NULL REFERENCES features(id), attempt_revision INTEGER NOT NULL, attempt_id TEXT NOT NULL, role TEXT NOT NULL, status TEXT NOT NULL, session_id TEXT)"
    )

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS process_executions (execution_id TEXT PRIMARY KEY, attempt_id TEXT NOT NULL, feature_id TEXT NOT NULL, attempt_revision INTEGER NOT NULL, unit_name TEXT NOT NULL UNIQUE, status TEXT NOT NULL, invocation_id TEXT, control_group TEXT, main_pid INTEGER, execution_kind TEXT NOT NULL DEFAULT 'role', operation_key TEXT, candidate_sha TEXT, candidate_tree TEXT)"
    )

    migrate_process_executions!(db)

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS implementation_commits (feature_id TEXT NOT NULL REFERENCES features(id), task_id TEXT NOT NULL, attempt_id TEXT NOT NULL UNIQUE, execution_id TEXT NOT NULL, role TEXT NOT NULL, repository TEXT NOT NULL, branch TEXT NOT NULL, sha TEXT NOT NULL, PRIMARY KEY(feature_id, task_id, attempt_id))"
    )

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS reviewer_checkouts (feature_id TEXT NOT NULL REFERENCES features(id), task_id TEXT NOT NULL, attempt_id TEXT NOT NULL UNIQUE, execution_id TEXT NOT NULL, role TEXT NOT NULL, implementation_attempt_id TEXT NOT NULL, reviewed_sha TEXT NOT NULL, repository TEXT NOT NULL, checkout_path TEXT NOT NULL, PRIMARY KEY(feature_id, task_id, attempt_id), FOREIGN KEY(implementation_attempt_id) REFERENCES implementation_commits(attempt_id))"
    )

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS local_role_outputs (feature_id TEXT NOT NULL REFERENCES features(id), revision INTEGER NOT NULL, attempt_id TEXT NOT NULL, execution_id TEXT NOT NULL, role TEXT NOT NULL, task_id TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(feature_id, revision, execution_id), FOREIGN KEY(attempt_id) REFERENCES attempts(attempt_id))"
    )

    migrate_local_role_outputs!(db)

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS technical_retries (feature_id TEXT NOT NULL REFERENCES features(id), operation_key TEXT NOT NULL, operation TEXT NOT NULL, status TEXT NOT NULL, classification TEXT NOT NULL, diagnostic TEXT NOT NULL, attempts INTEGER NOT NULL, max_attempts INTEGER NOT NULL, due_at_ms INTEGER NOT NULL, target_json TEXT NOT NULL, PRIMARY KEY(feature_id, operation_key))"
    )

    # Dirty developer work is resumable only when this exact failed execution
    # wrote a fingerprinted, branch/head-bound provenance record.
    execute(
      db,
      "CREATE TABLE IF NOT EXISTS resumable_workspace_changes (feature_id TEXT NOT NULL REFERENCES features(id), task_id TEXT NOT NULL, attempt_id TEXT NOT NULL PRIMARY KEY, failed_execution_id TEXT NOT NULL, workspace TEXT NOT NULL, expected_branch TEXT NOT NULL, expected_head_sha TEXT NOT NULL, fingerprint TEXT NOT NULL)"
    )

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS validation_evidence (feature_id TEXT NOT NULL REFERENCES features(id), validation_key TEXT NOT NULL, purpose TEXT NOT NULL, sha TEXT NOT NULL, tree TEXT NOT NULL, status TEXT NOT NULL, evidence_json TEXT NOT NULL, PRIMARY KEY(feature_id, validation_key))"
    )

    execute(
      db,
      "CREATE TABLE IF NOT EXISTS effects (feature_id TEXT NOT NULL REFERENCES features(id), operation_key TEXT NOT NULL, status TEXT NOT NULL, intent_json TEXT NOT NULL, result_json TEXT, feature_revision INTEGER NOT NULL, PRIMARY KEY(feature_id, operation_key))"
    )

    # A workspace is a durable resource, not merely a cwd supplied to a
    # process.  Keeping the claim in the journal makes a coordinator restart
    # safe and prevents two features in one runtime from becoming writers.
    execute(
      db,
      "CREATE TABLE IF NOT EXISTS workspace_ownership (workspace TEXT PRIMARY KEY, feature_id TEXT NOT NULL UNIQUE REFERENCES features(id), expected_branch TEXT NOT NULL, initial_base_sha TEXT NOT NULL, expected_head_sha TEXT NOT NULL, adopted INTEGER NOT NULL DEFAULT 0, claimed_at_ms INTEGER NOT NULL)"
    )

    :ok
  end

  defp runtime_status(db) do
    tables = execute(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")

    cond do
      tables == [] ->
        :empty

      not Enum.any?(tables, &(Enum.at(&1, 0) == "runtime_metadata")) ->
        :incompatible

      true ->
        case execute(db, "SELECT runtime_version, schema_version FROM runtime_metadata WHERE singleton = 1") do
          [[@runtime_version, @schema_version]] -> :current
          _ -> :incompatible
        end
    end
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

    for {name, definition} <- [
          {"sandbox_output", "TEXT"},
          {"auth_dir", "TEXT"},
          {"execution_kind", "TEXT NOT NULL DEFAULT 'role'"},
          {"operation_key", "TEXT"},
          {"candidate_sha", "TEXT"},
          {"candidate_tree", "TEXT"},
          {"exit_status", "INTEGER NOT NULL DEFAULT 0"}
        ],
        name not in columns do
      execute(db, "ALTER TABLE process_executions ADD COLUMN #{name} #{definition}")
    end
  end

  # Task 2 originally keyed a role output by feature revision.  A replacement
  # execution must retain that evidence rather than overwrite it, so upgrade
  # the key to include execution_id.  This is intentionally a copy migration:
  # SQLite cannot alter a primary key in place.
  defp migrate_local_role_outputs!(db) do
    columns = execute(db, "PRAGMA table_info(local_role_outputs)")

    if columns != [] and Enum.count(columns, &(Enum.at(&1, 5) > 0)) == 2 do
      execute(db, "ALTER TABLE local_role_outputs RENAME TO local_role_outputs_legacy")

      execute(
        db,
        "CREATE TABLE local_role_outputs (feature_id TEXT NOT NULL REFERENCES features(id), revision INTEGER NOT NULL, attempt_id TEXT NOT NULL, execution_id TEXT NOT NULL, role TEXT NOT NULL, task_id TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(feature_id, revision, execution_id), FOREIGN KEY(attempt_id) REFERENCES attempts(attempt_id))"
      )

      execute(db, "INSERT INTO local_role_outputs SELECT feature_id, revision, attempt_id, execution_id, role, task_id, result_json FROM local_role_outputs_legacy")
      execute(db, "DROP TABLE local_role_outputs_legacy")
    end
  end

  @spec transaction(Path.t(), (reference() -> term())) :: term()
  def transaction(path, fun) do
    ensure_current!(path)
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

  @doc false
  @spec read(Path.t(), (reference() -> term())) :: term()
  def read(path, fun) do
    ensure_current!(path)
    {:ok, db} = Sqlite3.open(path)

    try do
      execute(db, "PRAGMA foreign_keys = ON")
      fun.(db)
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

  @doc false
  @spec sync_workspace_claim(reference(), String.t(), map()) :: :ok
  def sync_workspace_claim(db, id, %{"expected_head_sha" => sha}) when is_binary(sha) and sha != "" do
    execute(db, "UPDATE workspace_ownership SET expected_head_sha = ? WHERE feature_id = ?", [sha, id])
    :ok
  end

  def sync_workspace_claim(_db, _id, _state), do: :ok

  defp ensure_current!(path) do
    case ensure_compatible(path) do
      :ok -> :ok
      {:error, :incompatible_runtime_version} -> raise ArgumentError, "incompatible runtime version"
    end
  end
end
