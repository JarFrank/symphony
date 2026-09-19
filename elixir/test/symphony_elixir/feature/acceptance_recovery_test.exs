Code.require_file("../../support/feature_reliability.ex", __DIR__)

defmodule SymphonyElixir.Feature.AcceptanceRecoveryTest do
  @moduledoc """
  Recovery contracts from /tmp/feature-runner-final-audit/audit_repros_test.exs:
  skip-worktree hidden content, partial reviewer and validation worktrees,
  transient systemctl inspection, and release after host lock removal.

  The two partial-worktree tests exercise different production entrypoints and
  durable intents. Command barriers leave real coordinator-written state,
  rather than synthesizing checkout ownership. The process inspection test
  requires real user systemd/bwrap; only one observation is fault-injected.
  """
  use ExUnit.Case, async: false
  @moduletag :acceptance_reliability
  @moduletag timeout: 30_000

  alias SymphonyElixir.Feature.{LocalRunner, ProcessOwner, Sandbox, Store, Validation, WorkspaceLock}
  alias SymphonyElixir.FeatureReliabilitySupport, as: Fixture
  alias SymphonyElixir.FeatureRunner, as: Runner

  setup do
    Fixture.fixture()
  end

  test "ReadyForHuman cannot accept changed tracked content hidden by skip-worktree", c do
    test_process = self()

    executor = fn assignment ->
      if assignment.role == "developer" do
        Fixture.git(c.workspace, ["update-index", "--skip-worktree", "source.txt"])
        hidden = "hidden live content from #{assignment.task_id}\n"
        File.write!(Path.join(c.workspace, "source.txt"), hidden)
        # Prove precisely the audit's local counterexample, not a generic
        # Git attack: status is empty while the tracked bytes differ.
        assert Fixture.git(c.workspace, ["status", "--porcelain=v1", "--untracked-files=all"]) == ""
        assert Fixture.git(c.workspace, ["show", "HEAD:source.txt"]) == "baseline"
        assert File.read!(Path.join(c.workspace, "source.txt")) == hidden
        send(test_process, :hidden_content_written)
        Fixture.envelope(assignment, %{"status" => "completed"})
      else
        c.config.executor.(assignment)
      end
    end

    result = LocalRunner.run(c.runtime, "feature", %{c.config | executor: executor})
    assert_received :hidden_content_written

    refute Runner.get(c.runtime, "feature")["phase"] == "ReadyForHuman",
           "readiness accepted live content absent from the captured/reviewed tree; result=#{inspect(elem(result, 0))}"

    assert Fixture.rows(c, "SELECT feature_id FROM workspace_ownership") == [["feature"]]
    assert :ok = WorkspaceLock.owned?(c.workspace, c.runtime, "feature")
  end

  test "reviewer recovery completes its owned worktree interrupted before checkout", c do
    assert {:ok, _} = LocalRunner.step(c.runtime, "feature", c.config)
    assert {:ok, %{"phase" => "Reviewing"} = reviewing} = LocalRunner.step(c.runtime, "feature", c.config)

    port = Fixture.start_coordinator(c, :after_worktree_add, "LocalRunner.step(runtime, \"feature\", config)")
    checkout = interrupted_checkout(c, port, reviewing["head"])
    assert [["intent"]] = Fixture.rows(c, "SELECT status FROM effects WHERE operation_key LIKE 'reviewer_checkout:%'")
    assert Fixture.rows(c, "SELECT attempt_id FROM reviewer_checkouts") == []

    assert :ok = Store.init(c.runtime)
    result = LocalRunner.step(c.runtime, "feature", c.config)
    assert {:ok, continued} = result
    assert hd(continued["tasks"])["review"]["sha"] == reviewing["head"]
    assert [[sha, ^checkout]] = Fixture.rows(c, "SELECT reviewed_sha, checkout_path FROM reviewer_checkouts")
    assert sha == reviewing["head"]
    assert {:ok, %{"phase" => "ReadyForHuman"}} = LocalRunner.run(c.runtime, "feature", c.config)
  end

  test "validation recovery completes its owned worktree interrupted before checkout", c do
    sha = Fixture.git(c.workspace, ["rev-parse", "HEAD"])
    checkout = Path.join(c.root, "partial-validation")
    target = %{key: "partial", purpose: "review", repository: c.workspace, sha: sha}
    options = %{operation_key: "validation:partial", output_root: c.config.output_root, revision: 0}

    body = """
    Validation.run(runtime, "feature", #{inspect(target)}, fn _ -> :ok end,
      #{inspect(checkout)}, 1_000, #{inspect(options)})
    """

    port = Fixture.start_coordinator(c, :after_worktree_add, body)
    assert interrupted_checkout(c, port, sha) == checkout
    assert [["intent"]] = Fixture.rows(c, "SELECT status FROM effects WHERE operation_key = 'validation_checkout:validation:partial'")
    assert :missing = Validation.evidence(c.runtime, "feature", target.key)
    assert :ok = Store.init(c.runtime)
    test_process = self()

    validator = fn context ->
      assert context.sha == sha
      assert Fixture.git(context.workspace, ["rev-parse", "HEAD"]) == sha
      assert Fixture.git(context.workspace, ["status", "--porcelain"]) == ""
      assert File.read!(Path.join(context.workspace, "source.txt")) == "baseline\n"
      send(test_process, :validated_recovered_checkout)
      :ok
    end

    assert {:ok, evidence} = Validation.run(c.runtime, "feature", target, validator, checkout, 1_000, options)
    assert_received :validated_recovered_checkout
    assert evidence["status"] == "passed"
    assert evidence["sha"] == sha
    assert {:ok, ^evidence} = Validation.evidence(c.runtime, "feature", target.key)
    refute File.exists?(checkout)
  end

  test "one failed process observation does not prevent later recovery of the same verified execution", c do
    {:execute, execution} = Runner.prepare(c.runtime, "feature")
    output = Path.join(c.root, "process-output")
    File.mkdir_p!(output)
    {:ok, sandbox} = Sandbox.profile(role: :test, workspace: c.workspace, output: output, runtime: c.runtime)
    assert {:ok, started} = ProcessOwner.start(c.runtime, execution, %{executable: "/bin/sleep", args: ["infinity"]}, sandbox)
    assert started.invocation_id != ""
    assert started.control_group != ""
    assert started.main_pid > 0

    shim_dir = Path.join(c.root, "inspection-shim")
    File.mkdir_p!(shim_dir)
    shim = Path.join(shim_dir, "systemctl")
    marker = Path.join(c.root, "inspection-failed-once")
    real_systemctl = System.find_executable("systemctl")

    File.write!(shim, """
    #!/bin/sh
    if [ "$1" = '--user' ] && [ "$2" = 'show' ] && [ "$3" = '#{started.unit_name}' ] && [ ! -e '#{marker}' ]; then
      printf observed > '#{marker}'
      echo transient-systemctl-error >&2
      exit 1
    fi
    exec '#{real_systemctl}' "$@"
    """)

    File.chmod!(shim, 0o700)
    old_path = System.fetch_env!("PATH")
    # Also restore after an ExUnit timeout kills the test process, bypassing
    # its try/after. This callback runs before the fixture's unit cleanup.
    on_exit(fn -> System.put_env("PATH", old_path) end)

    first =
      try do
        System.put_env("PATH", shim_dir <> ":" <> old_path)
        ProcessOwner.recover_execution(c.runtime, execution.execution_id)
      after
        System.put_env("PATH", old_path)
      end

    assert File.read!(marker) == "observed"
    # Unknown liveness must still fail closed during the outage.
    assert {:blocked, {:liveness_unknown, _, _}} = first
    refute Fixture.rows(c, "SELECT status FROM process_executions") == [["terminated"]]

    assert {invocation, 0} = Fixture.command("systemctl", ["--user", "show", started.unit_name, "-p", "InvocationID", "--value"])
    assert String.trim(invocation) == started.invocation_id
    assert {group, 0} = Fixture.command("systemctl", ["--user", "show", started.unit_name, "-p", "ControlGroup", "--value"])
    assert String.trim(group) == started.control_group

    assert :ok = ProcessOwner.recover_execution(c.runtime, execution.execution_id)
    assert Fixture.rows(c, "SELECT execution_id, status FROM process_executions") == [[execution.execution_id, "terminated"]]
    assert :ok = ProcessOwner.recover_execution(c.runtime, execution.execution_id)
    assert ProcessOwner.current(c.runtime) == []
  end

  test "release resumes idempotently after host lock removal without rerunning completed work", c do
    port = Fixture.start_coordinator(c, :before_release, "LocalRunner.run(runtime, \"feature\", config)")
    Fixture.await_boundary(c)
    Fixture.kill_coordinator(c, port)
    Fixture.stop_wrappers(c)
    ready = Runner.get(c.runtime, "feature")
    assert ready["phase"] == "ReadyForHuman"
    assert ready["release_status"] != "completed"
    assert Fixture.rows(c, "SELECT feature_id, expected_head_sha FROM workspace_ownership") == [["feature", ready["final_sha"]]]
    assert :ok = WorkspaceLock.owned?(c.workspace, c.runtime, "feature")

    # Audit's exact interruption: release_claim has removed the host lock,
    # but has not deleted the SQLite claim. Use the actual ready state/claim
    # left by the killed coordinator; no synthetic green evidence is inserted.
    assert :ok = WorkspaceLock.release(c.workspace, c.runtime, "feature")
    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.owned?(c.workspace, c.runtime, "feature")
    before = completed_work(c)

    config = %{
      c.config
      | executor: fn _ -> flunk("release recovery must not restart a model/review") end,
        validator: fn _ -> flunk("release recovery must not repeat validation") end
    }

    assert :ok = Store.init(c.runtime)
    first = LocalRunner.run(c.runtime, "feature", config)
    second = LocalRunner.run(c.runtime, "feature", config)
    assert completed_work(c) == before
    assert Runner.get(c.runtime, "feature")["final_sha"] == ready["final_sha"]

    assert match?({:ok, %{"phase" => "ReadyForHuman", "release_status" => "completed", "technical_blocker" => nil}}, first),
           "release recovery returned #{inspect(first)}; durable blocker=#{inspect(Runner.get(c.runtime, "feature")["technical_blocker"])}"

    assert {:ok, %{"phase" => "ReadyForHuman", "release_status" => "completed", "technical_blocker" => nil}} = second
    assert Fixture.rows(c, "SELECT feature_id FROM workspace_ownership") == []
    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.owned?(c.workspace, c.runtime, "feature")
  end

  defp interrupted_checkout(c, port, sha) do
    assert %{"command" => "git", "args" => ["-C", repository | _] = args} = Fixture.await_boundary(c)
    assert ["worktree", "add", "--detach", "--no-checkout", checkout, ^sha] = Enum.take(args, -6)
    assert repository == c.workspace
    Fixture.kill_coordinator(c, port)
    Fixture.stop_wrappers(c)
    assert Fixture.git(checkout, ["rev-parse", "HEAD"]) == sha
    assert Fixture.git(checkout, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) == Path.join(c.workspace, ".git")
    refute File.exists?(Path.join(checkout, "source.txt"))
    assert Fixture.git(checkout, ["status", "--porcelain"]) != ""
    checkout
  end

  defp completed_work(c) do
    # A release-specific journal/effect may legitimately change on recovery;
    # completed role, capture, review and validation records must not.
    for table <- ["attempts", "role_executions", "process_executions", "implementation_commits", "reviewer_checkouts", "validation_evidence"] do
      {table, Fixture.rows(c, "SELECT * FROM #{table} ORDER BY rowid")}
    end
  end
end
