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
  end
end
