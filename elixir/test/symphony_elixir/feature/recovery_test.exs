defmodule SymphonyElixir.Feature.RecoveryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Feature.{Failure, Store, TechnicalRetry}
  alias SymphonyElixir.FeatureRunner

  test "failure taxonomy separates implementation, environment, infrastructure, and integrity" do
    assert Failure.classify(:validation, :validator_changed_tree) == :integrity_failure
    assert Failure.classify(:capture, {:process_identity_mismatch, "old", :unit_name}) == :integrity_failure
    assert Failure.classify(:validation, {:ambiguous_execution, "old"}) == :integrity_failure
    assert Failure.classify(:validation, {:liveness_unknown, "old", :offline}) == :integrity_failure
    assert Failure.classify(:validation, {:cgroup_not_empty, "old"}) == :integrity_failure
    assert Failure.classify(:executor, :timeout) == :transient_infrastructure
    assert Failure.classify(:executor, {:systemd_run_failed, "offline"}) == :transient_infrastructure
    assert Failure.classify(:executor, {:transport, :offline}) == :transient_infrastructure
    assert Failure.classify(:validation, :missing_tool) == :validation_environment_blocked
    assert Failure.classify(:validation, :invalid_validation_target) == :validation_environment_blocked
    assert Failure.classify(:capture, :git_author_identity_unavailable) == :validation_environment_blocked
    assert Failure.classify(:validation, :compiler_failed) == :implementation_failure
    assert Failure.classify(:capture, :workspace_dirty) == :integrity_failure
    assert Failure.classify(:executor, :unknown) == :transient_infrastructure
    assert Failure.retryable?(:validation_environment_blocked)
    assert Failure.retryable?(:transient_infrastructure)
    refute Failure.retryable?(:integrity_failure)
  end

  test "technical retry journal persists backoff, exhaustion, and completion" do
    runtime = Path.join(System.tmp_dir!(), "technical-retry-#{System.unique_integer([:positive])}.sqlite3")
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "spec")
    on_exit(fn -> File.rm(runtime) end)

    assert :retry = TechnicalRetry.schedule(runtime, "feature", "capture", "capture", :validation_environment_blocked, "identity", %{}, 1, 10, 100)
    assert TechnicalRetry.attempts(runtime, "feature", "capture") == 1
    refute TechnicalRetry.ready?(runtime, "feature", "capture", 109)
    assert TechnicalRetry.ready?(runtime, "feature", "capture", 110)

    assert :exhausted =
             TechnicalRetry.schedule(
               runtime,
               "feature",
               "capture",
               "capture",
               :validation_environment_blocked,
               "identity",
               %{},
               1,
               10,
               110
             )

    refute TechnicalRetry.ready?(runtime, "feature", "capture", 1_000)

    assert :retry = TechnicalRetry.schedule(runtime, "feature", "validation", "validation", :transient_infrastructure, "timeout", %{sha: "abc"}, 2, 0, 100)
    assert :ok = TechnicalRetry.complete(runtime, "feature", "validation")
    assert TechnicalRetry.ready?(runtime, "feature", "validation", 100)

    assert TechnicalRetry.ready?(runtime, "feature", "new-operation")

    assert :retry =
             TechnicalRetry.schedule(
               runtime,
               "feature",
               "default-clock",
               "capture",
               :transient_infrastructure,
               "temporary outage",
               %{},
               1,
               0
             )
  end

  test "store migrates current v1 role-output technical schema without discarding recovery evidence" do
    runtime = Path.join(System.tmp_dir!(), "current-role-output-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(runtime) end)
    assert :ok = Store.init(runtime)

    Store.transaction(runtime, fn db ->
      Store.execute(db, "DROP TABLE local_role_outputs")

      Store.execute(db, "INSERT INTO features VALUES (?, ?, ?)", ["feature", 3, "{}"])
      Store.execute(db, "INSERT INTO attempts VALUES (?, ?, ?, ?, ?, ?, ?, ?)", ["feature", 3, "recorded", nil, "attempt-3", "{}", "execution-3", nil])

      Store.execute(
        db,
        "CREATE TABLE local_role_outputs (feature_id TEXT NOT NULL, revision INTEGER NOT NULL, attempt_id TEXT NOT NULL, execution_id TEXT NOT NULL, role TEXT NOT NULL, task_id TEXT NOT NULL, result_json TEXT NOT NULL, PRIMARY KEY(feature_id, revision))"
      )

      Store.execute(
        db,
        "INSERT INTO local_role_outputs VALUES (?, ?, ?, ?, ?, ?, ?)",
        ["feature", 3, "attempt-3", "execution-3", "developer", "task-1", "{\"status\":\"completed\"}"]
      )
    end)

    assert :ok = Store.init(runtime)

    assert Store.read(runtime, fn db ->
             Store.execute(db, "SELECT attempt_id, execution_id, role, task_id, result_json FROM local_role_outputs")
           end) == [["attempt-3", "execution-3", "developer", "task-1", "{\"status\":\"completed\"}"]]

    assert Store.read(runtime, fn db ->
             Store.execute(db, "SELECT COUNT(*) FROM pragma_table_info('local_role_outputs') WHERE pk > 0")
           end) == [[3]]
  end

  test "store upgrades current v1 attempts with durable execution identity columns" do
    runtime = Path.join(System.tmp_dir!(), "current-attempt-#{System.unique_integer([:positive])}.sqlite3")
    on_exit(fn -> File.rm(runtime) end)
    assert :ok = Store.init(runtime)

    Store.transaction(runtime, fn db ->
      Store.execute(db, "DROP TABLE local_role_outputs")
      Store.execute(db, "DROP TABLE attempts")

      Store.execute(
        db,
        "CREATE TABLE attempts (feature_id TEXT NOT NULL, revision INTEGER NOT NULL, status TEXT NOT NULL, result_json TEXT, PRIMARY KEY(feature_id, revision))"
      )
    end)

    assert :ok = Store.init(runtime)

    assert Store.read(runtime, fn db ->
             Store.execute(db, "SELECT name FROM pragma_table_info('attempts') WHERE name IN ('attempt_id', 'input_json', 'execution_id', 'execution_owner') ORDER BY name")
           end) == [["attempt_id"], ["execution_id"], ["execution_owner"], ["input_json"]]
  end
end
