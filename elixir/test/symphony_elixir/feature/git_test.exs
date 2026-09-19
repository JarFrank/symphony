defmodule SymphonyElixir.Feature.GitTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{Effects, Git, Sandbox, Store}
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

  test "workspace facts and explicit dirty-baseline adoption are coordinator owned", context do
    sha = git!(context.workspace, ["rev-parse", "HEAD"])
    assert {:ok, facts} = Git.workspace_state(context.workspace, "poc/feature-runner")
    assert facts.sha == sha
    assert facts.dirty_paths == []

    File.write!(Path.join(context.workspace, "baseline.txt"), "adopt me\n")
    assert {:ok, adopted_sha} = Git.adopt_dirty_baseline(context.workspace, "poc/feature-runner")
    refute adopted_sha == sha
    assert {:ok, %{dirty_paths: []}} = Git.workspace_state(context.workspace, "poc/feature-runner")
  end

  test "capture refuses an unexpected coordinator HEAD", context do
    expected = git!(context.workspace, ["rev-parse", "HEAD"])
    git!(context.workspace, ["commit", "--allow-empty", "-m", "external commit"])

    assert {:blocked, :unexpected_head} =
             Git.capture_implementation(context.runtime, developer_context(context, expected_head_sha: expected))
  end

  @tag :acceptance_reliability
  test "capture intent reconciles its exact committed tree after a crash without a duplicate commit", context do
    capture = developer_context(context)
    File.write!(Path.join(capture.workspace, "implementation.txt"), "crash-window candidate\n")
    parent = git!(capture.workspace, ["rev-parse", "HEAD"])
    git!(capture.workspace, ["add", "-A"])
    tree = git!(capture.workspace, ["write-tree"])

    intent = %{
      "attempt_id" => capture.attempt_id,
      "branch" => capture.expected_branch,
      "execution_id" => capture.execution_id,
      "expected_parent" => parent,
      "feature_id" => capture.feature_id,
      "operation" => "capture_implementation",
      "repository" => Path.expand(capture.workspace),
      "task_id" => capture.task_id,
      "tree" => tree
    }

    assert :ok = Effects.intent(context.runtime, capture.feature_id, "capture:#{capture.attempt_id}", intent)
    git!(capture.workspace, ["commit", "-m", "symphony: capture implementation #{capture.attempt_id}"])
    committed = git!(capture.workspace, ["rev-parse", "HEAD"])

    assert {:ok, implementation} = Git.capture_implementation(context.runtime, capture)
    assert implementation.sha == committed
    assert git!(capture.workspace, ["rev-list", "--count", "HEAD"]) == "2"
    assert {:completed, ^intent, %{"sha" => ^committed}} = Effects.fetch(context.runtime, "feature", "capture:developer-attempt")
  end

  test "capture intent fails closed when HEAD is not its exact commit", context do
    capture = developer_context(context)
    parent = git!(capture.workspace, ["rev-parse", "HEAD"])
    tree = git!(capture.workspace, ["rev-parse", "HEAD^{tree}"])

    assert :ok =
             Effects.intent(context.runtime, "feature", "capture:developer-attempt", %{
               "attempt_id" => capture.attempt_id,
               "branch" => capture.expected_branch,
               "execution_id" => capture.execution_id,
               "expected_parent" => parent,
               "feature_id" => "feature",
               "operation" => "capture_implementation",
               "repository" => Path.expand(capture.workspace),
               "task_id" => capture.task_id,
               "tree" => tree
             })

    git!(capture.workspace, ["commit", "--allow-empty", "-m", "foreign commit"])
    assert {:blocked, :unexpected_head} = Git.capture_implementation(context.runtime, capture)
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

    assert {:blocked, :reviewer_identity_mismatch} =
             Git.validate_reviewer_result(context.runtime, %{correct | "task_id" => "task-2"})

    assert {:blocked, :invalid_reviewer_result} = Git.validate_reviewer_result(context.runtime, %{})
    assert {:blocked, :invalid_reviewer_result} = Git.validate_reviewer_result(context.runtime, :invalid)

    File.write!(Path.join(checkout, "implementation.txt"), "uncommitted reviewer mutation\n")
    assert {:blocked, :reviewer_checkout_dirty} = Git.validate_reviewer_result(context.runtime, correct)
    git!(checkout, ["reset", "--hard", "HEAD"])

    File.write!(Path.join(checkout, "implementation.txt"), "reviewer tampering\n")
    git!(checkout, ["commit", "-am", "tamper with reviewer checkout"])

    assert {:blocked, :git_identity_mismatch} =
             Git.validate_reviewer_result(context.runtime, correct)
  end

  test "missing durable records and mismatched task assignments fail closed", context do
    assert {:blocked, :implementation_not_captured} =
             Git.implementation(context.runtime, "feature", "missing-attempt")

    assert {:blocked, :reviewer_checkout_not_prepared} =
             Git.reviewer_checkout(context.runtime, "feature", "missing-attempt")

    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))

    assert {:blocked, :review_task_mismatch} =
             Git.prepare_reviewer_checkout(
               context.runtime,
               reviewer_context(Path.join(context.root, "wrong-task"))
               |> Map.put(:task_id, "task-2")
             )
  end

  test "durable implementation binding is idempotent and rejects another execution", context do
    developer = developer_context(context)
    assert {:ok, first} = Git.capture_implementation(context.runtime, developer)
    assert {:ok, ^first} = Git.capture_implementation(context.runtime, developer)

    assert {:blocked, :implementation_attempt_already_bound} =
             Git.capture_implementation(
               context.runtime,
               Map.put(developer, :execution_id, "different-execution")
             )

    Store.init(context.runtime)
    assert {:ok, persisted} = Git.implementation(context.runtime, "feature", "developer-attempt")
    assert persisted.sha == first.sha
  end

  test "reviewer binding is idempotent and conflicting retry removes its new worktree", context do
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer")
    assignment = reviewer_context(checkout)

    assert {:ok, first} = Git.prepare_reviewer_checkout(context.runtime, assignment)
    assert {:ok, ^first} = Git.reviewer_checkout(context.runtime, "feature", "reviewer-attempt")
    assert {:ok, ^first} = Git.prepare_reviewer_checkout(context.runtime, assignment)

    conflicting_checkout = Path.join(context.root, "conflicting-reviewer")

    assert {:blocked, :reviewer_attempt_already_bound} =
             Git.prepare_reviewer_checkout(
               context.runtime,
               %{assignment | checkout_path: conflicting_checkout}
             )

    refute File.exists?(conflicting_checkout)
    assert git!(checkout, ["rev-parse", "HEAD"]) == first.reviewed_sha
  end

  test "reviewer replacement rebinds only the runtime execution for the same reviewed SHA", context do
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer-replacement")
    first_assignment = reviewer_context(checkout)

    assert {:ok, first} = Git.prepare_reviewer_checkout(context.runtime, first_assignment)
    replacement_assignment = %{first_assignment | execution_id: "reviewer-execution-replacement"}

    assert {:ok, replacement} = Git.prepare_reviewer_checkout(context.runtime, replacement_assignment)
    assert replacement.attempt_id == first.attempt_id
    assert replacement.reviewed_sha == first.reviewed_sha
    assert replacement.execution_id == "reviewer-execution-replacement"
    assert {:ok, persisted} = Git.reviewer_checkout(context.runtime, "feature", "reviewer-attempt")
    assert persisted.execution_id == replacement.execution_id
    assert git!(checkout, ["rev-parse", "HEAD"]) == first.reviewed_sha
  end

  test "reviewer replacement rejects a different immutable reviewed SHA for the same attempt", context do
    assert {:ok, implementation} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer-sha-fence")
    assignment = reviewer_context(checkout)
    assert {:ok, _} = Git.prepare_reviewer_checkout(context.runtime, assignment)

    File.write!(Path.join(context.workspace, "implementation.txt"), "new candidate\n")
    git!(context.workspace, ["commit", "-am", "new candidate"])
    new_sha = git!(context.workspace, ["rev-parse", "HEAD"])

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE implementation_commits SET sha = ? WHERE attempt_id = ?", [new_sha, implementation.attempt_id])
    end)

    assert {:blocked, :reviewer_attempt_already_bound} =
             Git.prepare_reviewer_checkout(context.runtime, %{assignment | execution_id: "reviewer-execution-replacement"})
  end

  test "persisted reviewer checkout must remain at its assigned SHA and cleanup is idempotent", context do
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer")
    assignment = reviewer_context(checkout)
    assert {:ok, _} = Git.prepare_reviewer_checkout(context.runtime, assignment)
    File.write!(Path.join(checkout, "implementation.txt"), "tampered\n")
    git!(checkout, ["commit", "-am", "tamper"])

    assert {:blocked, :persisted_reviewer_checkout_not_exact} =
             Git.prepare_reviewer_checkout(context.runtime, assignment)

    assert :ok = Git.remove_reviewer_checkout(context.runtime, "feature", "reviewer-attempt")
    refute File.exists?(checkout)
    assert :ok = Git.remove_reviewer_checkout(context.runtime, "feature", "reviewer-attempt")
    assert :ok = Git.remove_reviewer_checkout(context.runtime, "feature", "missing-attempt")
  end

  test "reviewer cleanup reports a missing repository instead of hiding the failure", context do
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer")
    assert {:ok, _} = Git.prepare_reviewer_checkout(context.runtime, reviewer_context(checkout))

    File.rename!(context.workspace, Path.join(context.root, "removed-developer"))

    assert {:blocked, {:git_command_failed, ["worktree", "remove", "--force", ^checkout], _}} =
             Git.remove_reviewer_checkout(context.runtime, "feature", "reviewer-attempt")
  end

  test "whole-repository is the default while explicit allowlists remain strict", context do
    File.write!(Path.join(context.workspace, "untracked.txt"), "untracked\n")

    assert {:blocked, {:unexpected_dirty_paths, ["untracked.txt"]}} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: ["implementation.txt"]))

    assert File.exists?(Path.join(context.workspace, "untracked.txt"))

    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))

    assert {:blocked, :repository_not_on_expected_feature_branch} =
             Git.capture_implementation(context.runtime, developer_context(context, expected_branch: "main"))
  end

  test "default capture commits changes across the complete repository into its authoritative SHA", context do
    File.mkdir_p!(Path.join(context.workspace, "api/AttendanceApi/Core"))
    File.mkdir_p!(Path.join(context.workspace, "web/assets"))
    File.write!(Path.join(context.workspace, "implementation.txt"), "tracked implementation\n")
    File.write!(Path.join(context.workspace, "api/AttendanceApi/Core/ConfigureOutbox.cs"), "configured\n")
    File.write!(Path.join(context.workspace, "web/assets/payment.js"), "export default true\n")

    assert {:ok, implementation} = Git.capture_implementation(context.runtime, developer_context(context))
    assert implementation.sha == git!(context.workspace, ["rev-parse", "HEAD"])

    assert git!(context.workspace, ["show", "--format=", "--name-only", implementation.sha])
           |> String.split("\n", trim: true)
           |> Enum.sort() == [
             "api/AttendanceApi/Core/ConfigureOutbox.cs",
             "implementation.txt",
             "web/assets/payment.js"
           ]
  end

  test "an explicit empty allowed_paths list permits no dirty implementation changes", context do
    File.write!(Path.join(context.workspace, "implementation.txt"), "changed\n")

    assert {:blocked, {:unexpected_dirty_paths, ["implementation.txt"]}} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: []))

    assert File.read!(Path.join(context.workspace, "implementation.txt")) == "changed\n"
  end

  test "a legacy directory allowlist accepts descendants and captures them", context do
    File.mkdir_p!(Path.join(context.workspace, "api/core"))
    File.write!(Path.join(context.workspace, "api/core/implementation.ex"), "implemented\n")

    assert {:ok, implementation} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: ["api"]))

    assert git!(context.workspace, ["show", "--format=", "--name-only", implementation.sha]) =~
             "api/core/implementation.ex"
  end

  test "caller protected paths are additive to the default secret protection", context do
    File.mkdir_p!(Path.join(context.workspace, "config"))
    File.write!(Path.join(context.workspace, "config/credentials.json"), "secret\n")

    assert {:blocked, {:protected_paths, ["config/credentials.json"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, protected_paths: ["generated/**"])
             )
  end

  test "protected Git hooks are reported instead of being run during capture", context do
    hook = Path.join(context.workspace, ".git/hooks/pre-commit")
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    File.write!(Path.join(context.workspace, "implementation.txt"), "changed\n")

    assert {:blocked, {:protected_paths, [".git/hooks/pre-commit"]}} =
             Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "a symlinked workspace is not accepted as the repository root", context do
    linked_workspace = Path.join(context.root, "linked-developer")
    File.ln_s!(context.workspace, linked_workspace)

    assert {:blocked, :workspace_is_not_repository_root} =
             Git.capture_implementation(context.runtime, developer_context(context, workspace: linked_workspace))
  end

  test "a tracked rename is captured as one approved repository diff", context do
    File.mkdir_p!(Path.join(context.workspace, "api"))
    git!(context.workspace, ["mv", "implementation.txt", "api/implementation.txt"])

    assert {:ok, implementation} = Git.capture_implementation(context.runtime, developer_context(context))
    assert git!(context.workspace, ["show", "--format=", "--name-status", implementation.sha]) =~ "R100\timplementation.txt\tapi/implementation.txt"
  end

  test "a broken symlink is rejected instead of being treated as an in-repository file", context do
    File.ln_s!(Path.join(context.root, "missing-outside-target"), Path.join(context.workspace, "broken-link"))

    assert {:blocked, {:unsafe_changed_paths, ["broken-link"]}} =
             Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "caller glob protections apply to a single path component", context do
    File.mkdir_p!(Path.join(context.workspace, "config"))
    File.write!(Path.join(context.workspace, "config/a.yml"), "protected\n")
    File.write!(Path.join(context.workspace, "config/long.yml"), "not reached\n")

    assert {:blocked, {:protected_paths, ["config/a.yml"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, protected_paths: ["config/?.yml"])
             )
  end

  test "caller glob protections match nested directories", context do
    File.mkdir_p!(Path.join(context.workspace, "assets/generated"))
    File.write!(Path.join(context.workspace, "assets/generated/secret.txt"), "protected\n")

    assert {:blocked, {:protected_paths, ["assets/generated/secret.txt"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, protected_paths: ["assets/**/secret.txt"])
             )
  end

  test "a recursive protected path also protects its path root", context do
    File.write!(Path.join(context.workspace, "generated"), "protected root\n")

    assert {:blocked, {:protected_paths, ["generated"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, protected_paths: ["generated/**"])
             )
  end

  test "blocked-path errors retain every matching protected path", context do
    File.mkdir_p!(Path.join(context.workspace, "deploy"))
    File.write!(Path.join(context.workspace, "deploy/one.yml"), "one\n")
    File.write!(Path.join(context.workspace, "deploy/two.yml"), "two\n")

    assert {:blocked, {:protected_paths, ["deploy/one.yml", "deploy/two.yml"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, protected_paths: ["deploy/**"])
             )
  end

  test "nested default private-key protections remain active with caller policy", context do
    File.mkdir_p!(Path.join(context.workspace, "keys"))
    File.write!(Path.join(context.workspace, "keys/service.pem"), "private key\n")

    assert {:blocked, {:protected_paths, ["keys/service.pem"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, protected_paths: ["generated/**"])
             )
  end

  test "a repository without a hooks directory still captures approved work", context do
    File.rm_rf!(Path.join(context.workspace, ".git/hooks"))
    File.write!(Path.join(context.workspace, "implementation.txt"), "changed\n")

    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "an unreadable Git hooks shape is itself reported as protected", context do
    hooks = Path.join(context.workspace, ".git/hooks")
    File.rm_rf!(hooks)
    File.write!(hooks, "not a directory\n")
    File.write!(Path.join(context.workspace, "implementation.txt"), "changed\n")

    assert {:blocked, {:protected_paths, [".git/hooks"]}} =
             Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "allowlist traversal and absolute patterns are invalid configuration", context do
    assert {:blocked, :invalid_implementation_context} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: ["../outside"]))

    assert {:blocked, :invalid_implementation_context} =
             Git.capture_implementation(context.runtime, developer_context(context, allowed_paths: [context.root]))
  end

  test "protected paths override an allowlist and name every blocked path", context do
    File.mkdir_p!(Path.join(context.workspace, ".github/workflows"))
    File.write!(Path.join(context.workspace, ".github/workflows/release.yml"), "name: release\n")

    assert {:blocked, {:protected_paths, [".github/workflows/release.yml"]}} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context,
                 allowed_paths: [".github"],
                 protected_paths: [".github/workflows/**"]
               )
             )
  end

  test "default secret and Git administrative protections fail closed", context do
    File.write!(Path.join(context.workspace, ".env.production"), "TOKEN=secret\n")

    assert {:blocked, {:protected_paths, [".env.production"]}} =
             Git.capture_implementation(context.runtime, developer_context(context))

    File.rm!(Path.join(context.workspace, ".env.production"))
    File.write!(Path.join(context.workspace, ".git/unsafe-hook"), "blocked\n")

    assert {:blocked, {:protected_paths, [".git/unsafe-hook"]}} =
             Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "traversal, outside workspaces, and symlink escapes are rejected", context do
    assert {:blocked, :invalid_implementation_context} =
             Git.capture_implementation(context.runtime, developer_context(context, protected_paths: ["../outside/**"]))

    outside = Path.join(context.root, "outside")
    File.write!(outside, "outside\n")
    File.ln_s!(outside, Path.join(context.workspace, "escape"))

    assert {:blocked, {:unsafe_changed_paths, ["escape"]}} =
             Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "nested, non-repository, detached, and in-progress workspaces fail closed", context do
    nested = Path.join(context.workspace, "nested")
    File.mkdir_p!(nested)

    assert {:blocked, :workspace_is_not_repository_root} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, workspace: nested)
             )

    not_repository = Path.join(context.root, "not-repository")
    File.mkdir_p!(not_repository)

    assert {:blocked, :workspace_is_not_git_repository} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, workspace: not_repository)
             )

    git!(context.workspace, ["checkout", "--detach"])

    assert {:blocked, :repository_not_on_expected_feature_branch} =
             Git.capture_implementation(context.runtime, developer_context(context))

    git!(context.workspace, ["checkout", "poc/feature-runner"])
    git_path = git!(context.workspace, ["rev-parse", "--git-path", "rebase-merge"])
    File.mkdir_p!(Path.expand(git_path, context.workspace))

    assert {:blocked, :git_operation_in_progress} =
             Git.capture_implementation(context.runtime, developer_context(context))
  end

  test "invalid capture and reviewer contexts plus unsafe checkout paths fail closed", context do
    assert {:blocked, :invalid_implementation_context} =
             Git.capture_implementation(context.runtime, :invalid)

    assert {:blocked, :invalid_implementation_context} =
             Git.capture_implementation(
               context.runtime,
               developer_context(context, role: "reviewer")
             )

    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))

    assert {:blocked, :invalid_reviewer_context} =
             Git.prepare_reviewer_checkout(context.runtime, :invalid)

    assert {:blocked, :invalid_reviewer_context} =
             Git.prepare_reviewer_checkout(
               context.runtime,
               reviewer_context(Path.join(context.root, "wrong-role"))
               |> Map.put(:role, "developer")
             )

    assert {:blocked, :reviewer_checkout_path_unsafe} =
             Git.prepare_reviewer_checkout(
               context.runtime,
               reviewer_context(Path.join(context.workspace, "reviewer"))
             )

    existing = Path.join(context.root, "existing")
    File.mkdir_p!(existing)

    assert {:blocked, :reviewer_checkout_path_unsafe} =
             Git.prepare_reviewer_checkout(context.runtime, reviewer_context(existing))
  end

  test "merge state and missing exact-SHA checkout fail closed", context do
    git_dir = git!(context.workspace, ["rev-parse", "--git-dir"])
    File.write!(Path.expand(Path.join(git_dir, "MERGE_HEAD"), context.workspace), git!(context.workspace, ["rev-parse", "HEAD"]))

    assert {:blocked, :git_operation_in_progress} =
             Git.capture_implementation(context.runtime, developer_context(context))

    File.rm!(Path.expand(Path.join(git_dir, "MERGE_HEAD"), context.workspace))
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))
    checkout = Path.join(context.root, "reviewer")
    assert {:ok, assignment} = Git.prepare_reviewer_checkout(context.runtime, reviewer_context(checkout))
    File.rm_rf!(checkout)

    result = %{
      "feature_id" => "feature",
      "task_id" => "task-1",
      "attempt_id" => "reviewer-attempt",
      "execution_id" => "reviewer-execution",
      "role" => "reviewer",
      "reviewed_sha" => assignment.reviewed_sha
    }

    assert {:blocked, {:git_command_failed, ["rev-parse", "HEAD"], _}} =
             Git.validate_reviewer_result(context.runtime, result)
  end

  test "a corrupt persisted implementation SHA cannot create a reviewer checkout", context do
    assert {:ok, _} = Git.capture_implementation(context.runtime, developer_context(context))

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "UPDATE implementation_commits SET sha = 'not-a-commit' WHERE attempt_id = 'developer-attempt'"
      )
    end)

    checkout = Path.join(context.root, "corrupt-reviewer")

    assert {:blocked, {:git_command_failed, ["worktree", "add" | _], _}} =
             Git.prepare_reviewer_checkout(context.runtime, reviewer_context(checkout))

    refute File.exists?(checkout)
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
