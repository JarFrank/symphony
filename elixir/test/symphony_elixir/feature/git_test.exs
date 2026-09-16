defmodule SymphonyElixir.Feature.GitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{Git, Sandbox, Store}
  alias SymphonyElixir.FeatureRunner

  setup do
    root = Path.join(System.tmp_dir!(), "feature-git-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "developer")
    runtime = Path.join(root, "runtime/state.sqlite3")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(runtime))
    git!(workspace, ["init", "-b", "poc/feature-runner"])
    git!(workspace, ["config", "--local", "user.name", "Feature Runner"])
    git!(workspace, ["config", "--local", "user.email", "feature-runner@example.test"])
    File.write!(Path.join(workspace, "implementation.txt"), "base\n")
    git!(workspace, ["add", "implementation.txt"])
    git!(workspace, ["commit", "-m", "base"])
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "specification")
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, runtime: runtime, workspace: workspace}
  end

  test "coordinator captures Git HEAD, ignores a developer-provided fake SHA, and persists it", context do
    File.write!(Path.join(context.workspace, "implementation.txt"), "implemented\n")

    assert {:ok, implementation} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: ["implementation.txt"], sha: "developer-fake"))

    actual = git!(context.workspace, ["rev-parse", "HEAD"])
    assert implementation.sha == actual
    refute implementation.sha == "developer-fake"
    assert {:ok, persisted} = Git.implementation(context.runtime, "feature", "developer-attempt")
    assert persisted.sha == actual
    assert persisted.execution_id == "developer-execution"
  end

  test "reviewer gets a detached checkout of the persisted SHA despite later developer changes", context do
    File.write!(Path.join(context.workspace, "implementation.txt"), "v1\n")

    assert {:ok, implementation} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: ["implementation.txt"]))

    checkout = Path.join(context.root, "reviewer")

    assert {:ok, assignment} =
             Git.prepare_reviewer_checkout(context.runtime, reviewer_context(checkout))

    assert assignment.reviewed_sha == implementation.sha
    assert git!(checkout, ["rev-parse", "HEAD"]) == implementation.sha
    assert git!(checkout, ["symbolic-ref", "--quiet", "--short", "HEAD"], 1) == ""

    File.write!(Path.join(context.workspace, "implementation.txt"), "v2\n")
    git!(context.workspace, ["commit", "-am", "newer developer head"])
    refute git!(context.workspace, ["rev-parse", "HEAD"]) == assignment.reviewed_sha
    assert git!(checkout, ["rev-parse", "HEAD"]) == assignment.reviewed_sha
    assert File.read!(Path.join(checkout, "implementation.txt")) == "v1\n"
  end

  test "reviewer result requires the durable identity and exact SHA", context do
    assert {:ok, implementation} =
             Git.capture_implementation(context.runtime, developer_context(context))

    checkout = Path.join(context.root, "reviewer")

    assert {:ok, assignment} =
             Git.prepare_reviewer_checkout(context.runtime, reviewer_context(checkout))

    correct = %{
      "feature_id" => "feature",
      "task_id" => "task-1",
      "attempt_id" => "reviewer-attempt",
      "execution_id" => "reviewer-execution",
      "role" => "reviewer",
      "reviewed_sha" => assignment.reviewed_sha
    }

    assert {:ok, ^assignment} = Git.validate_reviewer_result(context.runtime, correct)

    assert {:blocked, :reviewed_sha_mismatch} =
             Git.validate_reviewer_result(context.runtime, %{correct | "reviewed_sha" => implementation.sha <> "bad"})

    assert {:blocked, :reviewer_identity_mismatch} =
             Git.validate_reviewer_result(context.runtime, %{correct | "execution_id" => "other"})
  end

  test "dirty and ambiguous developer states fail closed without discarding changes", context do
    File.write!(Path.join(context.workspace, "untracked.txt"), "untracked\n")

    assert {:blocked, :dirty_workspace_without_allowed_paths} =
             Git.capture_implementation(context.runtime, developer_context(context))

    assert File.exists?(Path.join(context.workspace, "untracked.txt"))

    assert {:blocked, {:unexpected_dirty_paths, ["untracked.txt"]}} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: ["implementation.txt"]))

    assert File.exists?(Path.join(context.workspace, "untracked.txt"))

    assert {:blocked, :repository_not_on_expected_feature_branch} =
             Git.capture_implementation(context.runtime, developer_context(context, expected_branch: "main"))
  end

  test "a missing local commit identity blocks capture and no remote is mutated", context do
    remote = Path.join(context.root, "remote.git")
    git!(context.root, ["init", "--bare", remote])
    git!(context.workspace, ["remote", "add", "origin", remote])
    File.write!(Path.join(context.workspace, "implementation.txt"), "changed\n")
    git!(context.workspace, ["config", "--local", "--unset-all", "user.name"])
    git!(context.workspace, ["config", "--local", "--unset-all", "user.email"])

    assert {:blocked, :git_author_identity_unavailable} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, allowed_paths: ["implementation.txt"])
             )

    assert File.read!(Path.join(context.workspace, "implementation.txt")) == "changed\n"
    assert git!(remote, ["show-ref"], 1) == ""
  end

  test "reviewer sandbox cannot modify the separate developer workspace", context do
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer")
    assert {:ok, _} = Git.prepare_reviewer_checkout(context.runtime, reviewer_context(checkout))
    output = Path.join(context.root, "reviewer-output")
    File.mkdir_p!(output)

    assert {:ok, profile} =
             Sandbox.profile(
               role: :reviewer,
               workspace: checkout,
               output: output,
               runtime: context.runtime,
               developer_workspace: context.workspace
             )

    {:ok, command} =
      Sandbox.wrap(profile, context.runtime, %{
        executable: System.find_executable("python3"),
        args: [
          "-c",
          "import pathlib,sys; pathlib.Path(sys.argv[1]).joinpath('implementation.txt').write_text('bad')",
          context.workspace
        ]
      })

    {_output, status} = System.cmd(command.executable, command.args, stderr_to_stdout: true)
    assert status != 0
    assert File.read!(Path.join(context.workspace, "implementation.txt")) == "base\n"
  end

  defp developer_context(context, overrides \\ []) do
    Map.merge(
      %{
        feature_id: "feature",
        task_id: "task-1",
        attempt_id: "developer-attempt",
        execution_id: "developer-execution",
        workspace: context.workspace,
        expected_branch: "poc/feature-runner"
      },
      Map.new(overrides)
    )
  end

  defp reviewer_context(checkout) do
    %{
      feature_id: "feature",
      task_id: "task-1",
      attempt_id: "reviewer-attempt",
      execution_id: "reviewer-execution",
      implementation_attempt_id: "developer-attempt",
      checkout_path: checkout
    }
  end

  defp git!(directory, args, expected_status \\ 0) do
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    assert status == expected_status, output
    String.trim(output)
  end
end
