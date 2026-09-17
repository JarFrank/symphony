defmodule Mix.Tasks.Feature.StatusTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Mix.Tasks.Feature.Status, as: FeatureStatus
  alias SymphonyElixir.Feature.Store
  alias SymphonyElixir.FeatureRunner

  test "prints a read-only LocalRunner status projection" do
    root = Path.join(System.tmp_dir!(), "feature-status-#{System.unique_integer([:positive])}")
    runtime = Path.join(root, "state.sqlite3")
    File.mkdir_p!(root)
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "spec")

    output = capture_io(fn -> FeatureStatus.run([runtime, "feature"]) end)

    assert output =~ "Feature: feature"
    assert output =~ "Role: mastermind"
    assert output =~ "Attempt: none"
    assert output =~ "Execution: none"
    assert output =~ "Session: none"
    assert output =~ "SHA: base"
    assert FeatureRunner.get(runtime, "feature")["revision"] == 0
  end

  test "watch only reads status" do
    root = Path.join(System.tmp_dir!(), "feature-status-watch-#{System.unique_integer([:positive])}")
    runtime = Path.join(root, "state.sqlite3")
    File.mkdir_p!(root)
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "spec")

    pid = spawn(fn -> FeatureStatus.run([runtime, "feature", "--watch"]) end)
    Process.sleep(20)
    Process.exit(pid, :kill)

    assert FeatureRunner.get(runtime, "feature")["revision"] == 0
  end

  test "rejects invalid arguments and unavailable status" do
    assert_raise Mix.Error, ~r/Usage: mix feature.status/, fn -> FeatureStatus.run([]) end

    assert_raise Mix.Error, ~r/Feature status unavailable/, fn ->
      FeatureStatus.run([Path.join(System.tmp_dir!(), "missing-feature-status.sqlite3"), "missing"])
    end
  end

  test "renders persisted attempt, retry, elapsed, and structured blocker metadata" do
    root = Path.join(System.tmp_dir!(), "feature-status-details-#{System.unique_integer([:positive])}")
    runtime = Path.join(root, "state.sqlite3")
    File.mkdir_p!(root)
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "spec")
    {:execute, execution} = FeatureRunner.prepare(runtime, "feature")

    Store.transaction(runtime, fn db ->
      Store.execute(db, "UPDATE features SET state_json = ? WHERE id = ?", [
        Jason.encode!(%{
          "phase" => "Planning",
          "spec" => "spec",
          "tasks" => [],
          "current" => 0,
          "head" => "base",
          "status" => %{"started_at" => System.system_time(:millisecond), "latest_event" => "fixture", "current_operation" => "role_execution", "codex_session_id" => "session"},
          "error" => %{"kind" => "blocked"}
        }),
        "feature"
      ])

      Store.execute(db, "INSERT INTO technical_retries VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
        "feature",
        "fixture",
        "role_execution",
        "pending",
        "transient_infrastructure",
        "waiting",
        1,
        3,
        123,
        "{}"
      ])
    end)

    output = capture_io(fn -> FeatureStatus.run([runtime, "feature"]) end)
    assert output =~ "Attempt: #{execution.attempt_id}"
    assert output =~ "Session: session"
    assert output =~ "Elapsed:"
    assert output =~ "Blocker: %{\"kind\" => \"blocked\"}"
    assert output =~ "Technical retry: 1"
    assert output =~ "Next retry: 123"

    state = FeatureRunner.get(runtime, "feature") |> Map.delete("revision")

    Store.transaction(runtime, fn db ->
      updated = state |> Map.put("status", %{"started_at" => "unknown"}) |> Map.put("error", "text")
      Store.execute(db, "UPDATE features SET state_json = ? WHERE id = ?", [Jason.encode!(updated), "feature"])
    end)

    output = capture_io(fn -> FeatureStatus.run([runtime, "feature"]) end)
    assert output =~ "Elapsed: unknown"
    assert output =~ "Blocker: text"
  end
end
