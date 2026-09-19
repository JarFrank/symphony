Code.require_file("../../support/feature_reliability.ex", __DIR__)

defmodule SymphonyElixir.Feature.ReliabilitySubsystemsTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{Effects, Git, GitCommand, LocalRunner, ProcessOwner, Sandbox, Store, WorkspaceLock}
  alias SymphonyElixir.FeatureReliabilitySupport, as: Fixture
  alias SymphonyElixir.FeatureRunner, as: Runner

  setup do
    Fixture.fixture()
  end

  for key <- ["core.fsmonitor", "core.hooksPath", "filter.evil.clean", "credential.helper", "include.path", "extensions.worktreeConfig", "core.sshCommand"] do
    @tag config_key: key
    test "host Git rejects executable or indirect configuration #{key}", c do
      marker = Path.join(c.root, "escaped")
      command = if c.config_key == "extensions.worktreeConfig", do: "true", else: "sh -c 'touch #{marker}'"
      Fixture.git(c.workspace, ["config", "--local", c.config_key, command])
      assert {:blocked, {:unsafe_git_config, [_]}} = GitCommand.run(c.workspace, ["status", "--porcelain"])
      refute File.exists?(marker)
    end
  end

  test "capture ignores injected Git environment and global configuration", c do
    hook_root = Path.join(c.root, "hooks")
    File.mkdir_p!(hook_root)
    marker = Path.join(c.root, "escaped")
    File.write!(Path.join(hook_root, "pre-commit"), "#!/bin/sh\ntouch #{marker}\n")
    File.chmod!(Path.join(hook_root, "pre-commit"), 0o700)
    config = Path.join(c.root, "malicious-config")
    File.write!(config, "[core]\n hooksPath = #{hook_root}\n")
    index = Path.join(c.root, "foreign-index")

    injected = %{
      "GIT_CONFIG_GLOBAL" => config,
      "GIT_CONFIG_COUNT" => "1",
      "GIT_CONFIG_KEY_0" => "core.hooksPath",
      "GIT_CONFIG_VALUE_0" => hook_root,
      "GIT_INDEX_FILE" => index,
      "GIT_CONFIG_PARAMETERS" => "'core.hooksPath=#{hook_root}'"
    }

    previous = Map.new(injected, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(injected)

    try do
      File.write!(Path.join(c.workspace, "source.txt"), "candidate\n")
      assert {:ok, _} = Git.capture_implementation(c.runtime, capture(c))
      refute File.exists?(marker)
      refute File.exists?(index)
    after
      Enum.each(previous, fn {key, value} -> if value, do: System.put_env(key, value), else: System.delete_env(key) end)
    end
  end

  test "a changed index cannot replace a pending capture tree", c do
    intent = capture_intent(c)
    File.write!(Path.join(c.workspace, "source.txt"), "foreign staged changes\n")
    Fixture.git(c.workspace, ["add", "-A"])

    assert {:blocked, :capture_intent_tree_mismatch} = Git.capture_implementation(c.runtime, capture(c))
    assert Fixture.git(c.workspace, ["rev-parse", "HEAD"]) == intent["expected_parent"]
    assert {:intent, ^intent, nil} = Effects.fetch(c.runtime, "feature", "capture:developer")
  end

  test "an unstaged change cannot be silently included in resumed capture", c do
    intent = capture_intent(c)
    File.write!(Path.join(c.workspace, "source.txt"), "foreign unstaged changes\n")
    assert {:blocked, :capture_intent_workspace_changed} = Git.capture_implementation(c.runtime, capture(c))
    assert Fixture.git(c.workspace, ["rev-parse", "HEAD"]) == intent["expected_parent"]
  end

  test "an unrelated repository at an intended reviewer path is never adopted or removed", c do
    {assignment, intent} = reviewer_intent(c)
    Fixture.git(c.root, ["clone", "--no-local", c.workspace, assignment.checkout_path])
    Fixture.git(assignment.checkout_path, ["checkout", "--detach", intent["reviewed_sha"]])

    assert {:blocked, :validation_checkout_unsafe} = Git.prepare_reviewer_checkout(c.runtime, assignment)
    assert File.dir?(assignment.checkout_path)
    assert Fixture.git(assignment.checkout_path, ["rev-parse", "HEAD"]) == intent["reviewed_sha"]
    assert {:intent, ^intent, nil} = Effects.fetch(c.runtime, "feature", "reviewer_checkout:reviewer")
  end

  test "an intended reviewer checkout not yet created is safely completed", c do
    {assignment, intent} = reviewer_intent(c)
    assert {:ok, checkout} = Git.prepare_reviewer_checkout(c.runtime, assignment)
    assert checkout.reviewed_sha == intent["reviewed_sha"]
    assert {:completed, ^intent, ^intent} = Effects.fetch(c.runtime, "feature", "reviewer_checkout:reviewer")
    assert :ok = Git.remove_reviewer_checkout(c.runtime, "feature", "reviewer")
  end

  test "a missing launching unit retains ownership until its late unit is stopped", c do
    {:execute, execution} = Runner.prepare(c.runtime, "feature")
    {:ok, record} = ProcessOwner.intent(c.runtime, execution)
    Store.transaction(c.runtime, fn db -> Store.execute(db, "UPDATE process_executions SET status = 'launching' WHERE execution_id = ?", [execution.execution_id]) end)
    assert {:blocked, {:launch_unconfirmed, _}} = ProcessOwner.recover(c.runtime)
    assert [["launching"]] = Fixture.rows(c, "SELECT status FROM process_executions")
    assert {_, 0} = Fixture.command("systemd-run", ["--user", "--unit", record.unit_name, "--service-type=exec", "/bin/sleep", "infinity"])
    assert :ok = ProcessOwner.recover(c.runtime)
    assert [["terminated"]] = Fixture.rows(c, "SELECT status FROM process_executions")
  end

  test "an observed failing exit status survives a second await and journal reopen", c do
    {:execute, execution} = Runner.prepare(c.runtime, "feature")
    output = Path.join(c.root, "output")
    File.mkdir_p!(output)
    {:ok, sandbox} = Sandbox.profile(role: :test, workspace: c.workspace, output: output, runtime: c.runtime)
    command = %{executable: "/bin/sh", args: ["-c", "while [ ! -e /output/proceed ]; do sleep 0.01; done; exit 7"]}
    assert {:ok, _} = ProcessOwner.start(c.runtime, execution, command, sandbox)
    File.write!(Path.join(output, "proceed"), "continue")
    assert {:ok, 7} = ProcessOwner.await(c.runtime, execution.execution_id, 2_000)
    assert :ok = Store.init(c.runtime)
    assert {:ok, 7} = ProcessOwner.await(c.runtime, execution.execution_id, 2_000)
  end

  test "release pending remains visible and can recover without retracting ReadyForHuman", c do
    assert {:ok, ready} = LocalRunner.run(c.runtime, "feature", c.config)
    # Reopen only the resource-release portion, preserving real readiness evidence.
    Store.transaction(c.runtime, fn db ->
      state = Store.fetch(db, "feature") |> Map.delete("release_status") |> Map.delete("revision")
      Store.execute(db, "UPDATE features SET state_json = ? WHERE id = 'feature'", [Jason.encode!(state)])
      Store.execute(db, "INSERT INTO workspace_ownership VALUES (?, 'feature', ?, ?, ?, 0, 0)", [c.workspace, c.config.expected_branch, ready["initial_base_sha"], ready["final_sha"]])
    end)

    assert :ok = WorkspaceLock.acquire(c.workspace, c.runtime, "feature")
    File.write!(Path.join(c.workspace, "source.txt"), "foreign\n")
    Fixture.git(c.workspace, ["commit", "-am", "foreign commit"])
    assert {:ok, pending} = LocalRunner.step(c.runtime, "feature", c.config)
    assert pending["phase"] == "ReadyForHuman"
    assert pending["release_status"] == "pending"
    assert pending["technical_blocker"]["operation"] == "workspace_release"
    assert {:ok, status} = LocalRunner.status(c.runtime, "feature")
    assert status.operation == "workspace_release_pending"
    Fixture.git(c.workspace, ["reset", "--hard", ready["final_sha"]])
    assert :ok = Store.init(c.runtime)
    assert {:ok, released} = LocalRunner.step(c.runtime, "feature", c.config)
    assert released["phase"] == "ReadyForHuman"
    assert released["release_status"] == "completed"
    assert released["technical_blocker"] == nil
    assert Fixture.rows(c, "SELECT feature_id FROM workspace_ownership") == []
  end

  defp capture(c), do: %{feature_id: "feature", task_id: "first", attempt_id: "developer", execution_id: "developer-execution", workspace: c.workspace, expected_branch: c.config.expected_branch}

  defp capture_intent(c) do
    File.write!(Path.join(c.workspace, "source.txt"), "intended candidate\n")
    Fixture.git(c.workspace, ["add", "-A"])

    intent = %{
      "operation" => "capture_implementation",
      "attempt_id" => "developer",
      "execution_id" => "developer-execution",
      "feature_id" => "feature",
      "task_id" => "first",
      "repository" => c.workspace,
      "branch" => c.config.expected_branch,
      "expected_parent" => Fixture.git(c.workspace, ["rev-parse", "HEAD"]),
      "tree" => Fixture.git(c.workspace, ["write-tree"])
    }

    assert :ok = Effects.intent(c.runtime, "feature", "capture:developer", intent)
    intent
  end

  defp reviewer_intent(c) do
    assert {:ok, implementation} = Git.capture_implementation(c.runtime, capture(c))

    assignment = %{
      feature_id: "feature",
      task_id: "first",
      attempt_id: "reviewer",
      execution_id: "reviewer-execution",
      implementation_attempt_id: "developer",
      checkout_path: Path.join(c.root, "reviewer")
    }

    intent = %{
      "operation" => "reviewer_checkout",
      "attempt_id" => "reviewer",
      "feature_id" => "feature",
      "task_id" => "first",
      "implementation_attempt_id" => "developer",
      "repository" => c.workspace,
      "checkout_path" => assignment.checkout_path,
      "reviewed_sha" => implementation.sha,
      "tree" => Fixture.git(c.workspace, ["rev-parse", "HEAD^{tree}"])
    }

    assert :ok = Effects.intent(c.runtime, "feature", "reviewer_checkout:reviewer", intent)
    {assignment, intent}
  end
end
