defmodule SymphonyElixir.Feature.ValidationProcessOwnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{LocalRunner, Store, Validation}
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
    git!(repository, ["init", "-b", "feature/validation-owner"])
    git!(repository, ["config", "--local", "user.name", "Validation Owner"])
    git!(repository, ["config", "--local", "user.email", "validation-owner@example.test"])
    File.write!(Path.join(repository, "fixture.txt"), "base\n")
    git!(repository, ["add", "fixture.txt"])
    git!(repository, ["commit", "-m", "base"])
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "Approved validation ownership")

    on_exit(fn -> File.rm_rf!(root) end)

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

  test "an unconfirmed validation execution blocks readiness and workspace release", context do
    execution_id = "validation-ambiguous"

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

    assert {:error, :workspace_process_unconfirmed} = LocalRunner.release_workspace(context.runtime, "feature")
    assert {:blocked, {:validation_recovery_unconfirmed, ^execution_id, _}} = Validation.recover(context.runtime, "feature")
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
