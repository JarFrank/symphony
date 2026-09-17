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
end
