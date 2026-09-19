defmodule SymphonyElixir.Feature.ValidationProcessOwnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{LocalRunner, ProcessOwner, Sandbox, Store, Validation}
  alias SymphonyElixir.FeatureRunner

  @timeout 5_000

  setup do
    root = Path.join(System.tmp_dir!(), "validation-owner-#{System.unique_integer([:positive])}")
    repository = Path.join(root, "repository")
    runtime = Path.join(root, "runtime/state.sqlite3")
    output_root = Path.join(root, "output")
    checkout_root = Path.join(root, "checkouts")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(repository)
    File.mkdir_p!(workspace)
    File.mkdir_p!(output_root)
    git!(repository, ["init", "-b", "feature/validation-owner"])
    git!(repository, ["config", "--local", "user.name", "Validation Owner"])
    git!(repository, ["config", "--local", "user.email", "validation-owner@example.test"])
    File.write!(Path.join(repository, "fixture.txt"), "base\n")
    git!(repository, ["add", "fixture.txt"])
    git!(repository, ["commit", "-m", "base"])
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "Approved validation ownership")

    on_exit(fn ->
      runtime
      |> Store.read(fn db -> Store.execute(db, "SELECT unit_name FROM process_executions") end)
      |> Enum.each(fn [unit_name] -> cleanup_unit(unit_name) end)

      File.rm_rf!(root)
    end)

    %{
      checkout_root: checkout_root,
      output_root: output_root,
      repository: repository,
      runtime: runtime,
      sha: git!(repository, ["rev-parse", "HEAD"]),
      workspace: workspace
    }
  end

  test "owned executable validation records identity and passes only after cgroup termination", context do
    assert {:ok, evidence} =
             run_command(context, %{
               executable: "/bin/sh",
               args: ["-c", "sleep 0.2; exit 0"]
             })

    assert evidence["status"] == "passed", inspect(evidence)
    assert evidence["exit_status"] == 0

    assert [["validation", operation, sha, tree, "terminated"]] =
             Store.read(context.runtime, fn db ->
               Store.execute(
                 db,
                 "SELECT execution_kind, operation_key, candidate_sha, candidate_tree, status FROM process_executions WHERE feature_id = ?",
                 ["feature"]
               )
             end)

    assert operation == "validation:logical"
    assert sha == context.sha
    assert is_binary(tree) and tree != ""
  end

  test "timeout kills a TERM-ignoring child in the validation cgroup before retry is allowed", context do
    task =
      Task.async(fn ->
        run_command(
          context,
          %{
            executable: "/bin/sh",
            args: ["-c", "(trap '' TERM; sleep 30) & echo $! > /output/child.pid; trap '' TERM; sleep 30"]
          },
          80
        )
      end)

    assert eventually(fn -> child_file(context.output_root) != nil end)
    assert context.output_root |> child_file() |> File.read!() |> String.trim() |> String.to_integer() > 1
    assert eventually(fn -> validation_cgroup_processes(context.runtime) |> length() >= 2 end)
    assert {:ok, evidence} = Task.await(task, @timeout)
    assert evidence["status"] == "blocked"
    assert evidence["failure_classification"] == "transient_infrastructure"
    assert validation_cgroup_processes(context.runtime) == []
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT status FROM process_executions WHERE feature_id = ?", ["feature"]) end) == [["terminated"]]
  end

  @tag :acceptance_reliability
  test "an unconfirmed validation execution blocks readiness and workspace release", context do
    execution_id = "validation-ambiguous-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, execution_kind, operation_key, candidate_sha, candidate_tree) VALUES (?, ?, ?, ?, ?, 'ambiguous', 'validation', ?, ?, ?)",
        [execution_id, "validation:logical", "feature", 0, "symphony-feature-#{execution_id}.service", "validation:logical", context.sha, "tree"]
      )

      Store.execute(
        db,
        "INSERT INTO workspace_ownership (workspace, feature_id, expected_branch, initial_base_sha, expected_head_sha, adopted, claimed_at_ms) VALUES (?, ?, ?, ?, ?, 0, 0)",
        [Path.expand(context.workspace), "feature", "feature/validation-owner", context.sha, context.sha]
      )
    end)

    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
    assert {:blocked, {:validation_recovery_unconfirmed, ^execution_id, _}} = Validation.recover(context.runtime, "feature")
  end

  test "active validation execution blocks both readiness and workspace release", context do
    execution_id = "validation-running"

    insert_execution(context, execution_id, "running")
    claim_workspace(context)

    readiness = FeatureRunner.complete_readiness(context.runtime, "feature", 0)
    assert readiness["technical_blocker"] == "process termination is not confirmed"
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
  end

  test "ProcessOwner.await reports invalid, unknown, terminated, and ambiguous ownership", context do
    assert {:blocked, :invalid_process_wait_timeout} = ProcessOwner.await(context.runtime, "missing", 0)
    assert {:blocked, {:unknown_execution, "missing"}} = ProcessOwner.await(context.runtime, "missing", 10)

    insert_execution(context, "validation-terminated", "terminated")
    assert {:ok, 0} = ProcessOwner.await(context.runtime, "validation-terminated", 10)

    insert_execution(context, "validation-ambiguous-await", "ambiguous")

    assert {:blocked, {:ambiguous_execution, "validation-ambiguous-await"}} =
             ProcessOwner.await(context.runtime, "validation-ambiguous-await", 10)
  end

  test "validation timeout becomes termination_unconfirmed when cgroup confirmation fails", context do
    execution = validation_execution(context, "validation-timeout-unconfirmed-#{System.unique_integer([:positive])}")

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    assert {:ok, _started} =
             ProcessOwner.start(context.runtime, execution, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, sandbox)

    execution_id = execution.execution_id
    previous_path = System.fetch_env!("PATH")
    systemctl = System.find_executable("systemctl")
    shim_dir = Path.join(System.tmp_dir!(), "validation-owner-shim-#{System.unique_integer([:positive])}")
    shim = Path.join(shim_dir, "systemctl")
    File.mkdir_p!(shim_dir)
    File.write!(shim, "#!/bin/sh\nif [ \"$2\" = stop ]; then echo stop-failed; exit 1; fi\nexec #{systemctl} \"$@\"\n")
    File.chmod!(shim, 0o755)
    System.put_env("PATH", shim_dir)

    try do
      assert {:blocked, {:termination_unconfirmed, ^execution_id, _reason}} =
               ProcessOwner.await(context.runtime, execution_id, 1)
    after
      System.put_env("PATH", previous_path)
      File.rm_rf!(shim_dir)
    end

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT status FROM process_executions WHERE execution_id = ?", [execution_id])
           end) == [["ambiguous"]]

    assert {_, 0} =
             System.cmd("systemctl", ["--user", "stop", "symphony-feature-#{execution.execution_id}.service"])
  end

  test "validation restart reconciles a terminated execution and stops a running one", context do
    terminated = validation_execution(context, "validation-already-terminated")
    insert_execution(context, terminated.execution_id, "terminated")
    assert :ok = ProcessOwner.recover_execution(context.runtime, terminated.execution_id)
    assert :ok = Validation.recover(context.runtime, "feature")

    running = validation_execution(context, "validation-restart-running")

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    assert {:ok, _started} =
             ProcessOwner.start(context.runtime, running, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, sandbox)

    assert :ok = Validation.recover(context.runtime, "feature")

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT status FROM process_executions WHERE execution_id = ?", [running.execution_id])
           end) == [["terminated"]]
  end

  test "validation restart rejects stale execution identity", context do
    execution = validation_execution(context, "validation-stale-identity")

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    assert {:ok, _started} =
             ProcessOwner.start(context.runtime, execution, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, sandbox)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET invocation_id = 'stale-invocation' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id

    recovery = Validation.recover(context.runtime, "feature")

    assert {:blocked, {:validation_recovery_unconfirmed, ^execution_id, reason}} = recovery
    assert {:process_identity_mismatch, ^execution_id, _} = reason

    assert {_, 0} =
             System.cmd("systemctl", ["--user", "stop", "symphony-feature-#{execution.execution_id}.service"])
  end

  test "validation start failure is persisted as a blocked outcome", context do
    assert {:ok, evidence} =
             run_command(context, %{executable: "/definitely/missing/validation", args: []})

    assert evidence["status"] in ["blocked", "failed"]
    assert evidence["failure_classification"] in ["integrity_failure", nil]
    assert [[process_status]] = Store.read(context.runtime, fn db -> Store.execute(db, "SELECT status FROM process_executions WHERE feature_id = ?", ["feature"]) end)
    assert process_status in ["terminated", "ambiguous"]
  end

  test "validation non-zero exit is persisted with its observed status", context do
    assert {:ok, evidence} = run_command(context, %{executable: "/bin/sh", args: ["-c", "sleep 0.2; exit 7"]})

    assert evidence["status"] == "failed"
    assert evidence["exit_status"] == 7
    assert evidence["failure_classification"] == nil
  end

  test "validation without an output root is durably blocked before process start", context do
    target = %{key: "missing-sandbox", purpose: "review", repository: context.repository, sha: context.sha}

    assert {:ok, evidence} =
             Validation.run(
               context.runtime,
               "feature",
               target,
               %{executable: "/bin/true", args: []},
               Path.join(context.checkout_root, "missing-sandbox"),
               100,
               %{operation_key: "validation:missing-sandbox", revision: 0}
             )

    assert evidence["status"] == "blocked"
    assert evidence["diagnostic"] == ":validation_sandbox_required"
  end

  test "validation execution requires durable operation identity", context do
    target = %{key: "missing-operation", purpose: "review", repository: context.repository, sha: context.sha}

    assert {:ok, %{"status" => "blocked", "diagnostic" => ":validation_execution_identity_required"}} =
             Validation.run(context.runtime, "feature", target, %{executable: "/bin/true", args: []}, Path.join(context.checkout_root, "missing-operation"), 100, %{output_root: context.output_root})
  end

  test "validation rejects a malformed executable command as a durable blocker", context do
    assert {:ok, %{"status" => "blocked", "diagnostic" => ":invalid_validation_command"}} =
             run_command(context, %{not_an_executable: true})
  end

  test "validation persists a liveness blocker when the started unit cannot be inspected", context do
    previous_path = System.fetch_env!("PATH")
    systemctl = System.find_executable("systemctl")
    shim_dir = Path.join(System.tmp_dir!(), "validation-owner-liveness-shim-#{System.unique_integer([:positive])}")
    shim = Path.join(shim_dir, "systemctl")
    counter = Path.join(shim_dir, "show-count")
    File.mkdir_p!(shim_dir)

    File.write!(
      shim,
      "#!/bin/sh\nif [ \"$2\" = show ]; then count=$(cat #{counter} 2>/dev/null || echo 0); count=$((count + 1)); echo $count > #{counter}; if [ $count -gt 2 ]; then echo inspection-offline; exit 1; fi; fi\nexec #{systemctl} \"$@\"\n"
    )

    File.chmod!(shim, 0o755)
    System.put_env("PATH", "#{shim_dir}:#{previous_path}")

    on_exit(fn ->
      context.runtime
      |> Store.read(fn db -> Store.execute(db, "SELECT execution_id FROM process_executions") end)
      |> Enum.each(fn [execution_id] -> System.cmd("systemctl", ["--user", "stop", "symphony-feature-#{execution_id}.service"]) end)
    end)

    try do
      assert {:ok, evidence} =
               run_command(context, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, 100)

      assert evidence["status"] == "blocked"
      assert evidence["diagnostic"] =~ "liveness_unknown"
    after
      System.put_env("PATH", previous_path)
      File.rm_rf!(shim_dir)
    end

    assert [[execution_id]] =
             Store.read(context.runtime, fn db ->
               Store.execute(db, "SELECT execution_id FROM process_executions WHERE feature_id = ?", ["feature"])
             end)

    assert {_, 0} = System.cmd("systemctl", ["--user", "stop", "symphony-feature-#{execution_id}.service"])
  end

  test "launch failure leaves an intended validation execution recoverable", context do
    execution = validation_execution(context, "validation-launch-failure-#{System.unique_integer([:positive])}")
    assert {:ok, _intent} = ProcessOwner.intent(context.runtime, execution)

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    execution_id = execution.execution_id

    assert {:blocked, {:unidentified_started_execution, ^execution_id, {:unit_not_running, _}}} =
             ProcessOwner.launch(
               context.runtime,
               execution.execution_id,
               %{executable: "/definitely/missing/validation", args: []},
               sandbox
             )

    assert {:blocked, {:ambiguous_execution, ^execution_id}} = ProcessOwner.recover(context.runtime)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'terminated' WHERE execution_id = ?", [execution_id])
    end)

    assert ProcessOwner.current(context.runtime) == []
  end

  test "ProcessOwner liveness checks fail closed for an unknown handle", context do
    assert {:blocked, :invalid_io_handle} =
             ProcessOwner.exit_status(%{path: context.runtime, execution_id: "missing-handle"})

    assert :ok = ProcessOwner.recover(context.runtime)
    assert ProcessOwner.current(context.runtime) == []
  end

  test "a duplicate launch reconciles an extant intended unit", context do
    execution = validation_execution(context, "validation-duplicate-launch-#{System.unique_integer([:positive])}")

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    assert {:ok, _started} =
             ProcessOwner.start(context.runtime, execution, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, sandbox)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'intended' WHERE execution_id = ?", [execution.execution_id])
    end)

    assert {:ok, reconciled} =
             ProcessOwner.launch(context.runtime, execution.execution_id, %{executable: "/bin/true", args: []}, sandbox)

    assert reconciled.execution_id == execution.execution_id
    assert reconciled.status == "running"

    assert :ok = ProcessOwner.cancel(context.runtime, execution.execution_id)
  end

  test "await blocks when an active validation unit cannot be inspected", context do
    execution = validation_execution(context, "validation-await-inspection-#{System.unique_integer([:positive])}")

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    assert {:ok, _started} =
             ProcessOwner.start(context.runtime, execution, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, sandbox)

    shim_dir =
      Path.join(System.tmp_dir!(), "validation-owner-inspect-shim-#{System.unique_integer([:positive])}")

    shim = Path.join(shim_dir, "systemctl")
    previous_path = System.fetch_env!("PATH")
    File.mkdir_p!(shim_dir)
    File.write!(shim, "#!/bin/sh\necho inspection-offline\nexit 1\n")
    File.chmod!(shim, 0o755)
    System.put_env("PATH", shim_dir)
    execution_id = execution.execution_id

    try do
      assert {:blocked, {:liveness_unknown, ^execution_id, "inspection-offline\n"}} =
               ProcessOwner.await(context.runtime, execution_id, 10)
    after
      System.put_env("PATH", previous_path)
      File.rm_rf!(shim_dir)
    end

    assert {_, 0} =
             System.cmd("systemctl", ["--user", "stop", "symphony-feature-#{execution.execution_id}.service"])
  end

  test "await rejects a stale validation invocation identity", context do
    execution = validation_execution(context, "validation-await-stale-#{System.unique_integer([:positive])}")

    {:ok, sandbox} =
      Sandbox.profile(role: :test, workspace: context.workspace, output: context.output_root, runtime: context.runtime)

    assert {:ok, _started} =
             ProcessOwner.start(context.runtime, execution, %{executable: "/bin/sh", args: ["-c", "sleep 30"]}, sandbox)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET invocation_id = 'stale-await' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id

    assert {:blocked, {:process_identity_mismatch, ^execution_id, _}} =
             ProcessOwner.await(context.runtime, execution_id, 10)

    assert {_, 0} =
             System.cmd("systemctl", ["--user", "stop", "symphony-feature-#{execution.execution_id}.service"])
  end

  test "recovery confirms an intended validation after its unit disappeared", context do
    execution = validation_execution(context, "validation-intent-recovery-#{System.unique_integer([:positive])}")
    assert {:ok, _intent} = ProcessOwner.intent(context.runtime, execution)
    assert :ok = Validation.recover(context.runtime, "feature")
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT status FROM process_executions WHERE execution_id = ?", [execution.execution_id]) end) == [["terminated"]]
  end

  defp run_command(context, command, timeout_ms \\ 2_000) do
    Validation.run(
      context.runtime,
      "feature",
      %{key: "validation-#{System.unique_integer([:positive])}", purpose: "review", repository: context.repository, sha: context.sha},
      command,
      Path.join(context.checkout_root, "checkout-#{System.unique_integer([:positive])}"),
      timeout_ms,
      %{operation_key: "validation:logical", output_root: context.output_root, revision: 0}
    )
  end

  defp validation_execution(context, execution_id) do
    %{
      attempt_id: "validation:logical",
      execution_id: execution_id,
      feature_id: "feature",
      revision: 0,
      execution_kind: "validation",
      operation_key: "validation:logical",
      candidate_sha: context.sha,
      candidate_tree: "tree"
    }
  end

  defp insert_execution(context, execution_id, status) do
    execution = validation_execution(context, execution_id)

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, execution_kind, operation_key, candidate_sha, candidate_tree) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          execution.execution_id,
          execution.attempt_id,
          execution.feature_id,
          execution.revision,
          "symphony-feature-#{execution.execution_id}.service",
          status,
          execution.execution_kind,
          execution.operation_key,
          execution.candidate_sha,
          execution.candidate_tree
        ]
      )
    end)
  end

  defp claim_workspace(context) do
    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "INSERT INTO workspace_ownership (workspace, feature_id, expected_branch, initial_base_sha, expected_head_sha, adopted, claimed_at_ms) VALUES (?, ?, ?, ?, ?, 0, 0)", [
        Path.expand(context.workspace),
        "feature",
        "feature/validation-owner",
        context.sha,
        context.sha
      ])
    end)
  end

  defp eventually(fun, timeout_ms \\ @timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(20)
        eventually_until(fun, deadline)
      end
    end
  end

  defp child_file(output_root) do
    case Path.wildcard(Path.join([output_root, "validation", "*", "child.pid"])) do
      [path] -> path
      _ -> nil
    end
  end

  defp cleanup_unit(unit_name) do
    System.cmd("systemctl", ["--user", "stop", unit_name], stderr_to_stdout: true)
    System.cmd("systemctl", ["--user", "reset-failed", unit_name], stderr_to_stdout: true)
  end

  defp validation_cgroup_processes(runtime) do
    Store.read(runtime, fn db ->
      with [[group]] when is_binary(group) and group != "" <-
             Store.execute(db, "SELECT control_group FROM process_executions WHERE feature_id = ?", ["feature"]),
           {:ok, contents} <- File.read(Path.join(["/sys/fs/cgroup", group, "cgroup.procs"])) do
        String.split(contents, "\n", trim: true)
      else
        _ -> []
      end
    end)
  end

  defp git!(path, args) do
    case System.cmd("git", args, cd: path, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, _} -> flunk("git #{Enum.join(args, " ")} failed: #{output}")
    end
  end
end
