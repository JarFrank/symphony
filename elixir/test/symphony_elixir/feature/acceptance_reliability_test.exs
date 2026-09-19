Code.require_file("../../support/feature_reliability.ex", __DIR__)

defmodule SymphonyElixir.Feature.AcceptanceReliabilityTest do
  @moduledoc """
  Fresh-v1 acceptance contracts. RED assertions describe required behavior;
  command barriers change scheduling only, never production return values.

  `mix test --only acceptance_reliability` selects this contract, including
  the real systemd tests in acceptance_process_test.exs and these existing
  GREEN tests (their assertions are reused, not duplicated):

  LocalRunnerTest:
  * "full local flow captures exact SHAs, requires fresh rework review, and reaches ReadyForHuman"
  * "final readiness rejects unconfirmed validation and active process executions"
  * "foreign live HEAD blocks readiness and retains the workspace until controlled HEAD is restored"
  * "a second journal is denied before baseline adoption can mutate Git"
  * "an incompatible runtime fails before workspace ownership or Git mutation"
  * "validation reuses only its own crash-window checkout"
  * "LocalRunner waits for due_at and resumes a partial Developer retry without another run call"
  * "Reviewer technical recovery keeps one reviewer attempt and one immutable reviewed SHA"

  ProcessOwnerTest:
  * "an ambiguous prior liveness record blocks another writer"

  ValidationProcessOwnerTest:
  * "an unconfirmed validation execution blocks readiness and workspace release"

  GitTest:
  * "capture intent reconciles its exact committed tree after a crash without a duplicate commit"

  FeatureRunnerTest:
  * "an exhausted task repair budget does not consume another task's first repair"

  Crash tests use the actual coordinator in a separate VM. A command barrier
  stops it immediately before/after the external effect, then SIGKILL leaves
  exactly the journal and filesystem that production wrote.
  """
  use ExUnit.Case, async: false
  @moduletag :acceptance_reliability
  @moduletag timeout: 30_000

  alias SymphonyElixir.Feature.{Git, LocalRunner, ProcessOwner, Sandbox, Store}
  alias SymphonyElixir.FeatureReliabilitySupport, as: Fixture
  alias SymphonyElixir.FeatureRunner, as: Runner

  setup do
    Fixture.fixture()
  end

  test "fresh clean work reaches ReadyForHuman and releases its workspace", c do
    assert {:ok, ready} = LocalRunner.run(c.runtime, "feature", c.config)
    assert ready["phase"] == "ReadyForHuman"
    assert ready["final_sha"] == Fixture.git(c.workspace, ["rev-parse", "HEAD"])
    assert ready["initial_base_sha"] != "base"
    assert ready["findings"] == []
    assert Enum.all?(ready["tasks"], &(&1["status"] == "accepted"))
    assert Fixture.rows(c, "SELECT feature_id FROM workspace_ownership") == []
  end

  test "FinalReview repair of an earlier task returns through validation and both reviews", c do
    seen = start_supervised!({Agent, fn -> false end})

    executor = fn assignment ->
      if assignment.phase == "FinalReview" and not Agent.get_and_update(seen, &{&1, true}) do
        Fixture.envelope(assignment, %{"status" => "changes_requested", "task_id" => "first", "findings" => ["Repair earlier task"]})
      else
        c.config.executor.(assignment)
      end
    end

    assert {:ok, ready} = LocalRunner.run(c.runtime, "feature", %{c.config | executor: executor})
    assert ready["phase"] == "ReadyForHuman"
    assert [%{"status" => "resolved", "source_role" => "FinalReview", "affected_task_id" => "first", "resolved_by_sha" => sha}] = ready["findings"]
    assert sha == ready["final_sha"]
    assert ready["final_repair_count"] == 1
    assert ready["final_validation"]["status"] == "passed"
  end

  test "developer controlled Git configuration cannot execute a host hook during capture", c do
    assert {:ok, _} = LocalRunner.step(c.runtime, "feature", c.config)
    {:execute, execution} = Runner.prepare(c.runtime, "feature")
    output = Path.join(c.root, "hook-output")
    File.mkdir_p!(output)
    marker = Path.join(c.root, "outside-allowed-roots")
    # The only payload effect is a marker in our temporary fixture, outside
    # both sandbox mounts. No host credentials or external repositories.
    File.write!(Path.join(output, "hook"), "#!/bin/sh\nprintf escaped > '#{marker}'\n")
    {:ok, sandbox} = Sandbox.profile(role: :developer, workspace: c.workspace, output: output, runtime: c.runtime)

    command = %{
      executable: "/bin/sh",
      args: [
        "-ec",
        "mkdir .fixture-hooks; cp /output/hook .fixture-hooks/pre-commit; chmod +x .fixture-hooks/pre-commit; git config --local core.hooksPath .fixture-hooks; printf candidate > source.txt; touch /output/prepared; while [ ! -e /output/proceed ]; do sleep 0.01; done"
      ]
    }

    assert {:ok, _} = ProcessOwner.start(c.runtime, execution, command, sandbox)
    Fixture.eventually(fn -> File.exists?(Path.join(output, "prepared")) end)
    File.write!(Path.join(output, "proceed"), "continue")
    assert {:ok, 0} = ProcessOwner.await(c.runtime, execution.execution_id, 2_000)
    refute File.exists?(marker)

    result =
      Git.capture_implementation(c.runtime, %{
        feature_id: "feature",
        task_id: "first",
        attempt_id: execution.attempt_id,
        execution_id: execution.execution_id,
        workspace: c.workspace,
        expected_branch: c.config.expected_branch
      })

    refute File.exists?(marker), "coordinator executed sandbox-controlled hook; capture returned #{inspect(result)}"
  end

  test "an uncommitted durable capture resumes at its unchanged baseline after a crash", c do
    assert {:ok, _} = LocalRunner.step(c.runtime, "feature", c.config)
    baseline = Fixture.git(c.workspace, ["rev-parse", "HEAD"])
    port = Fixture.start_coordinator(c, :before_commit, "LocalRunner.step(runtime, \"feature\", config)")
    assert %{"command" => "git"} = Fixture.await_boundary(c)
    Fixture.kill_coordinator(c, port)
    Fixture.stop_wrappers(c)
    assert Fixture.git(c.workspace, ["rev-parse", "HEAD"]) == baseline
    assert [["intent"]] = Fixture.rows(c, "SELECT status FROM effects WHERE operation_key LIKE 'capture:%'")
    [[attempt]] = Fixture.rows(c, "SELECT attempt_id FROM attempts WHERE status = 'running'")

    assert :ok = Store.init(c.runtime)
    assert {:ok, state} = LocalRunner.step(c.runtime, "feature", c.config)
    assert state["phase"] == "Reviewing", inspect(state["error"])
    assert state["implementation_attempt_id"] == attempt
    assert Fixture.git(c.workspace, ["rev-parse", "HEAD^1"]) == baseline
    assert {:ok, %{"phase" => "ReadyForHuman"}} = LocalRunner.run(c.runtime, "feature", c.config)
  end

  test "a coordinator-created reviewer checkout is recoverable before assignment confirmation", c do
    assert {:ok, _} = LocalRunner.step(c.runtime, "feature", c.config)
    assert {:ok, %{"phase" => "Reviewing"} = reviewing} = LocalRunner.step(c.runtime, "feature", c.config)
    port = Fixture.start_coordinator(c, :after_checkout, "LocalRunner.step(runtime, \"feature\", config)")
    assert %{"command" => "git", "args" => ["-C", checkout | _]} = Fixture.await_boundary(c)
    Fixture.kill_coordinator(c, port)
    Fixture.stop_wrappers(c)
    assert Fixture.git(checkout, ["rev-parse", "HEAD"]) == reviewing["head"]
    assert Fixture.git(checkout, ["status", "--porcelain"]) == ""

    assert :ok = Store.init(c.runtime)
    assert {:ok, continued} = LocalRunner.step(c.runtime, "feature", c.config)
    assert hd(continued["tasks"])["review"]["sha"] == reviewing["head"]
    assert {:ok, %{"phase" => "ReadyForHuman"}} = LocalRunner.run(c.runtime, "feature", c.config)
  end

  test "a restart before validation due_at neither executes nor records another validation", c do
    calls = start_supervised!({Agent, fn -> 0 end})

    config =
      retry_config(c, fn _ ->
        Agent.update(calls, &(&1 + 1))
        {:blocked, :missing_tool}
      end)

    schedule_validation(c, config)
    before = Fixture.rows(c, "SELECT validation_key, evidence_json FROM validation_evidence ORDER BY validation_key")
    retry = Fixture.rows(c, "SELECT attempts, due_at_ms FROM technical_retries")
    assert :ok = Store.init(c.runtime)
    result = LocalRunner.step(c.runtime, "feature", config)

    assert Agent.get(calls, & &1) == 1, "validation ran before its durable due_at"
    assert Fixture.rows(c, "SELECT validation_key, evidence_json FROM validation_evidence ORDER BY validation_key") == before
    assert Fixture.rows(c, "SELECT attempts, due_at_ms FROM technical_retries") == retry
    assert {:blocked, {:technical_retry_pending, :validation}} = result
  end

  test "due validation retries check the recovered environment instead of replaying a premature failure", c do
    config = retry_config(c, fn _ -> {:blocked, :missing_tool} end)
    schedule_validation(c, config)
    assert :ok = Store.init(c.runtime)
    _ = LocalRunner.step(c.runtime, "feature", config)
    calls = start_supervised!({Agent, fn -> 0 end})

    due = %{
      config
      | now_ms: fn -> 1_100 end,
        validator: fn _ ->
          Agent.update(calls, &(&1 + 1))
          :ok
        end
    }

    assert {:ok, state} = LocalRunner.step(c.runtime, "feature", due)
    assert Agent.get(calls, & &1) == 1, "due retry reused a result from before due_at"
    assert state["phase"] == "Reviewing"
    assert Fixture.rows(c, "SELECT status FROM technical_retries") == [["completed"]]
  end

  test "workspace release integrity failure is visible instead of a successful ReadyForHuman result", c do
    port = Fixture.start_coordinator(c, :before_release, "Fixture.emit_result(root, LocalRunner.run(runtime, \"feature\", config))")
    Fixture.await_boundary(c)
    assert Runner.get(c.runtime, "feature")["phase"] == "ReadyForHuman"
    File.write!(Path.join(c.workspace, "foreign.txt"), "foreign commit\n")
    Fixture.git(c.workspace, ["add", "."])
    Fixture.git(c.workspace, ["commit", "-m", "foreign HEAD during release"])
    Fixture.proceed(c)
    Fixture.await_exit(port)
    result = Fixture.result(c)
    assert Fixture.rows(c, "SELECT feature_id FROM workspace_ownership") == [["feature"]]
    state = Runner.get(c.runtime, "feature")

    assert result["outcome"] != "ok" or state["phase"] != "ReadyForHuman" or state["technical_blocker"] != nil,
           "release failed but the runner returned #{result["outcome"]}/#{state["phase"]} without a blocker"
  end

  defp retry_config(c, validator), do: Map.merge(c.config, %{validator: validator, now_ms: fn -> 100 end, technical_retry_backoff_ms: 1_000, technical_retry_attempts: 1})

  defp schedule_validation(c, config) do
    assert {:ok, _} = LocalRunner.step(c.runtime, "feature", config)
    assert {:blocked, {:technical_retry_scheduled, _}} = LocalRunner.step(c.runtime, "feature", config)
    assert Fixture.rows(c, "SELECT attempts, due_at_ms FROM technical_retries") == [[1, 1_100]]
  end
end
