defmodule SymphonyElixir.Feature.Git do
  @moduledoc """
  Coordinator-owned local Git primitives for an implementation/review handoff.

  This module never accepts a model SHA as authority.  It reads `HEAD` from the
  developer repository, persists that value with the developer execution, then
  builds a detached reviewer worktree from the persisted value.  It deliberately
  contains no remote, push, merge, PR, or tracker operation.
  """

  alias SymphonyElixir.Feature.Store

  @type implementation :: %{
          required(:feature_id) => String.t(),
          required(:task_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:workspace) => Path.t(),
          required(:expected_branch) => String.t(),
          optional(:role) => String.t(),
          optional(:allowed_paths) => [Path.t()]
        }

  @doc """
  Captures the implementation commit from Git, rather than from Developer output.

  A clean workspace selects `HEAD`.  A dirty workspace is accepted only when
  every changed (including untracked) path is explicitly allowed; the
  coordinator stages those paths and creates a local commit using the repository
  local author identity.  All other dirty states fail closed without changing
  the workspace.
  """
  @spec capture_implementation(Path.t(), implementation()) :: {:ok, map()} | {:blocked, term()}
  def capture_implementation(runtime, context) do
    with {:ok, context} <- implementation_context(context),
         {:ok, repository} <- repository(context.workspace),
         :ok <- expected_branch(repository, context.expected_branch),
         :ok <- no_in_progress_operation(repository),
         {:ok, changed} <- changed_paths(repository),
         {:ok, sha} <- select_or_commit(repository, changed, context.allowed_paths),
         :ok <- verify_commit(repository, sha) do
      implementation = Map.merge(context, %{repository: repository, sha: sha})
      persist_implementation(runtime, implementation)
    end
  end

  @spec implementation(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:blocked, term()}
  def implementation(runtime, feature_id, attempt_id) do
    Store.read(runtime, fn db ->
      case Store.execute(db, "SELECT task_id, attempt_id, execution_id, role, repository, branch, sha FROM implementation_commits WHERE feature_id = ? AND attempt_id = ?", [feature_id, attempt_id]) do
        [[task_id, ^attempt_id, execution_id, role, repository, branch, sha]] ->
          {:ok,
           %{
             feature_id: feature_id,
             task_id: task_id,
             attempt_id: attempt_id,
             execution_id: execution_id,
             role: role,
             repository: repository,
             branch: branch,
             sha: sha
           }}

        [] ->
          {:blocked, :implementation_not_captured}
      end
    end)
  end

  @doc "Creates a detached, separate reviewer worktree from a persisted implementation SHA."
  @spec prepare_reviewer_checkout(Path.t(), map()) :: {:ok, map()} | {:blocked, term()}
  def prepare_reviewer_checkout(runtime, context) do
    with {:ok, context} <- reviewer_context(context),
         {:ok, implementation} <- implementation(runtime, context.feature_id, context.implementation_attempt_id),
         :ok <- same_task(context, implementation) do
      assignment =
        Map.merge(context, %{
          repository: implementation.repository,
          reviewed_sha: implementation.sha
        })

      ensure_reviewer_checkout(runtime, assignment)
    end
  end

  @doc "Removes the isolated reviewer worktree while retaining its durable assignment."
  @spec remove_reviewer_checkout(Path.t(), String.t(), String.t()) :: :ok | {:blocked, term()}
  def remove_reviewer_checkout(runtime, feature_id, attempt_id) do
    case reviewer_checkout(runtime, feature_id, attempt_id) do
      {:ok, assignment} -> remove_checkout(assignment)
      {:blocked, :reviewer_checkout_not_prepared} -> :ok
      {:blocked, _} = blocked -> blocked
    end
  end

  @spec reviewer_checkout(Path.t(), String.t(), String.t()) :: {:ok, map()} | {:blocked, term()}
  def reviewer_checkout(runtime, feature_id, attempt_id) do
    Store.read(runtime, fn db ->
      case Store.execute(
             db,
             "SELECT task_id, attempt_id, execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path FROM reviewer_checkouts WHERE feature_id = ? AND attempt_id = ?",
             [feature_id, attempt_id]
           ) do
        [
          [task_id, ^attempt_id, execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path]
        ] ->
          {:ok,
           %{
             feature_id: feature_id,
             task_id: task_id,
             attempt_id: attempt_id,
             execution_id: execution_id,
             role: role,
             implementation_attempt_id: implementation_attempt_id,
             reviewed_sha: reviewed_sha,
             repository: repository,
             checkout_path: checkout_path
           }}

        [] ->
          {:blocked, :reviewer_checkout_not_prepared}
      end
    end)
  end

  @doc "Validates untrusted Reviewer output against the durable reviewer assignment."
  @spec validate_reviewer_result(Path.t(), map()) :: {:ok, map()} | {:blocked, term()}
  def validate_reviewer_result(runtime, result) when is_map(result) do
    with {:ok, identity} <- reviewer_result_identity(result),
         {:ok, assignment} <- reviewer_checkout(runtime, identity.feature_id, identity.attempt_id),
         :ok <- matching_reviewer_identity(identity, assignment),
         :ok <- matching_reviewed_sha(identity.reviewed_sha, assignment.reviewed_sha),
         :ok <- checkout_is_exact(assignment.checkout_path, assignment.reviewed_sha),
         :ok <- checkout_is_clean(assignment.checkout_path) do
      {:ok, assignment}
    end
  end

  def validate_reviewer_result(_, _), do: {:blocked, :invalid_reviewer_result}

  defp persist_implementation(runtime, implementation) do
    Store.transaction(runtime, fn db ->
      rows = Store.execute(db, "SELECT task_id, execution_id, role, repository, branch, sha FROM implementation_commits WHERE attempt_id = ?", [implementation.attempt_id])

      case rows do
        [] ->
          Store.execute(db, "INSERT INTO implementation_commits (feature_id, task_id, attempt_id, execution_id, role, repository, branch, sha) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", [
            implementation.feature_id,
            implementation.task_id,
            implementation.attempt_id,
            implementation.execution_id,
            implementation.role,
            implementation.repository,
            implementation.expected_branch,
            implementation.sha
          ])

          {:ok, Map.take(implementation, [:feature_id, :task_id, :attempt_id, :execution_id, :role, :repository, :sha])}

        [[task_id, execution_id, role, repository, branch, sha]]
        when task_id == implementation.task_id and execution_id == implementation.execution_id and role == implementation.role and repository == implementation.repository and
               branch == implementation.expected_branch and sha == implementation.sha ->
          {:ok, Map.take(implementation, [:feature_id, :task_id, :attempt_id, :execution_id, :role, :repository, :sha])}

        _ ->
          {:blocked, :implementation_attempt_already_bound}
      end
    end)
  end

  defp persist_reviewer_checkout(runtime, assignment) do
    Store.transaction(runtime, fn db ->
      rows =
        Store.execute(db, "SELECT task_id, execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path FROM reviewer_checkouts WHERE attempt_id = ?", [assignment.attempt_id])

      case rows do
        [] ->
          Store.execute(
            db,
            "INSERT INTO reviewer_checkouts (feature_id, task_id, attempt_id, execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
              assignment.feature_id,
              assignment.task_id,
              assignment.attempt_id,
              assignment.execution_id,
              assignment.role,
              assignment.implementation_attempt_id,
              assignment.reviewed_sha,
              assignment.repository,
              assignment.checkout_path
            ]
          )

          {:ok, Map.take(assignment, [:feature_id, :task_id, :attempt_id, :execution_id, :role, :implementation_attempt_id, :reviewed_sha, :repository, :checkout_path])}

        [existing] ->
          existing_reviewer_assignment(existing, assignment)
      end
    end)
  end

  defp ensure_reviewer_checkout(runtime, assignment) do
    case reviewer_checkout(runtime, assignment.feature_id, assignment.attempt_id) do
      {:ok, existing} ->
        reuse_reviewer_checkout(existing, assignment)

      {:blocked, :reviewer_checkout_not_prepared} ->
        create_reviewer_checkout(runtime, assignment)
    end
  end

  defp reuse_reviewer_checkout(existing, assignment) do
    if same_reviewer_assignment?(existing_reviewer_row(existing), assignment) do
      exact_persisted_checkout(existing)
    else
      {:blocked, :reviewer_attempt_already_bound}
    end
  end

  defp exact_persisted_checkout(existing) do
    case checkout_is_exact(existing.checkout_path, existing.reviewed_sha) do
      :ok -> {:ok, existing}
      {:blocked, _} -> {:blocked, :persisted_reviewer_checkout_not_exact}
    end
  end

  defp create_reviewer_checkout(runtime, assignment) do
    with :ok <- new_checkout_path(assignment.checkout_path, assignment.repository),
         :ok <- worktree_add(assignment.repository, assignment.checkout_path, assignment.reviewed_sha),
         :ok <- checkout_is_exact(assignment.checkout_path, assignment.reviewed_sha) do
      case persist_reviewer_checkout(runtime, assignment) do
        {:ok, _} = result ->
          result

        {:blocked, _} = blocked ->
          # The directory is newly created by us and has not been exposed to a reviewer.
          _ = worktree_remove(assignment.repository, assignment.checkout_path)
          blocked
      end
    end
  end

  defp remove_checkout(assignment) do
    if File.exists?(assignment.checkout_path) do
      worktree_remove(assignment.repository, assignment.checkout_path) |> discard_output()
    else
      git(assignment.repository, ["worktree", "prune"]) |> discard_output()
    end
  end

  defp select_or_commit(repository, [], _allowed_paths), do: git(repository, ["rev-parse", "HEAD"])

  defp select_or_commit(repository, changed, allowed_paths) do
    with :ok <- allowed_changes(changed, allowed_paths),
         :ok <- local_identity(repository),
         {:ok, _} <- git(repository, ["add", "--" | changed]),
         {:ok, _} <- git(repository, ["commit", "-m", "symphony: capture implementation for review"]),
         {:ok, sha} <- git(repository, ["rev-parse", "HEAD"]),
         {:ok, []} <- changed_paths(repository) do
      {:ok, sha}
    else
      {:ok, _dirty} -> {:blocked, :workspace_not_clean_after_commit}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp allowed_changes(_changed, []), do: {:blocked, :dirty_workspace_without_allowed_paths}

  defp allowed_changes(changed, allowed_paths) do
    if Enum.all?(changed, &allowed_path?(&1, allowed_paths)), do: :ok, else: {:blocked, {:unexpected_dirty_paths, changed -- Enum.filter(changed, &allowed_path?(&1, allowed_paths))}}
  end

  defp allowed_path?(path, allowed_paths), do: Enum.any?(allowed_paths, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp repository(workspace) do
    with {:ok, top} <- git(workspace, ["rev-parse", "--show-toplevel"]),
         true <- Path.expand(top) == Path.expand(workspace) do
      {:ok, top}
    else
      false -> {:blocked, :workspace_is_not_repository_root}
      {:blocked, _} -> {:blocked, :workspace_is_not_git_repository}
    end
  end

  defp expected_branch(repository, expected) do
    with true <- is_binary(expected) and expected != "",
         {:ok, branch} <- git(repository, ["symbolic-ref", "--quiet", "--short", "HEAD"]),
         true <- branch == expected do
      :ok
    else
      false -> {:blocked, :repository_not_on_expected_feature_branch}
      {:blocked, _} -> {:blocked, :repository_not_on_expected_feature_branch}
    end
  end

  defp no_in_progress_operation(repository) do
    [
      absent_revision(repository, "MERGE_HEAD"),
      absent_revision(repository, "CHERRY_PICK_HEAD"),
      absent_git_path(repository, "rebase-merge"),
      absent_git_path(repository, "rebase-apply")
    ]
    |> Enum.find(:ok, &(&1 != :ok))
  end

  defp absent_revision(repository, revision) do
    case git(repository, ["rev-parse", "-q", "--verify", revision]) do
      {:ok, _} -> {:blocked, :git_operation_in_progress}
      {:blocked, {:git_command_failed, _, 1}} -> :ok
      {:blocked, _} -> {:blocked, :git_operation_state_unknown}
    end
  end

  defp absent_git_path(repository, name) do
    case git(repository, ["rev-parse", "--git-path", name]) do
      {:ok, path} ->
        if File.exists?(Path.expand(path, repository)), do: {:blocked, :git_operation_in_progress}, else: :ok

      {:blocked, _} ->
        {:blocked, :git_operation_state_unknown}
    end
  end

  defp changed_paths(repository), do: git(repository, ["status", "--porcelain=v1", "--untracked-files=all"]) |> parse_status()
  defp parse_status({:ok, output}), do: porcelain_paths(output)
  defp parse_status({:blocked, _} = blocked), do: blocked

  defp porcelain_paths(""), do: {:ok, []}

  defp porcelain_paths(output) do
    lines = String.split(output, "\n", trim: true)

    if Enum.all?(lines, &(byte_size(&1) >= 4 and String.at(&1, 2) == " ")) do
      {:ok, Enum.map(lines, &String.slice(&1, 3..-1//1))}
    else
      {:blocked, :ambiguous_git_status}
    end
  end

  defp local_identity(repository) do
    with {:ok, name} <- git(repository, ["config", "--local", "--get", "user.name"]),
         {:ok, email} <- git(repository, ["config", "--local", "--get", "user.email"]),
         true <- name != "" and email != "" do
      :ok
    else
      _ -> {:blocked, :git_author_identity_unavailable}
    end
  end

  defp new_checkout_path(path, repository) when is_binary(path) do
    expanded = Path.expand(path)
    if not File.exists?(expanded) and not same_or_contains?(repository, expanded), do: :ok, else: {:blocked, :reviewer_checkout_path_unsafe}
  end

  defp new_checkout_path(_, _), do: {:blocked, :reviewer_checkout_path_unsafe}

  defp same_or_contains?(parent, child), do: child == parent or String.starts_with?(child, parent <> "/")

  defp worktree_add(repository, checkout, sha) do
    case git(repository, ["worktree", "add", "--detach", "--no-checkout", checkout, sha]) do
      {:ok, _} -> git(checkout, ["checkout", "--detach", sha]) |> discard_output()
      {:blocked, _} = blocked -> blocked
    end
  end

  defp worktree_remove(repository, checkout), do: git(repository, ["worktree", "remove", "--force", checkout])
  defp checkout_is_exact(checkout, sha), do: git(checkout, ["rev-parse", "HEAD"]) |> equals(sha)

  defp checkout_is_clean(checkout) do
    case changed_paths(checkout) do
      {:ok, []} -> :ok
      {:ok, _changed} -> {:blocked, :reviewer_checkout_dirty}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp verify_commit(repository, sha), do: git(repository, ["rev-parse", "#{sha}^{commit}"]) |> equals(sha)
  defp equals({:ok, value}, value), do: :ok
  defp equals({:ok, _}, _), do: {:blocked, :git_identity_mismatch}
  defp equals({:blocked, _} = blocked, _), do: blocked
  defp discard_output({:ok, _}), do: :ok
  defp discard_output({:blocked, _} = blocked), do: blocked

  defp git(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {_output, status} -> {:blocked, {:git_command_failed, args, status}}
    end
  rescue
    _ -> {:blocked, :git_unavailable}
  end

  defp implementation_context(context) when is_map(context) do
    required = [:feature_id, :task_id, :attempt_id, :execution_id, :workspace, :expected_branch]

    if Enum.all?(required, &(is_binary(context[&1]) and context[&1] != "")) and Map.get(context, :role, "developer") == "developer" and
         (is_list(Map.get(context, :allowed_paths, [])) and Enum.all?(Map.get(context, :allowed_paths, []), &(is_binary(&1) and &1 != ""))) do
      {:ok, Map.merge(%{role: "developer", allowed_paths: []}, context)}
    else
      {:blocked, :invalid_implementation_context}
    end
  end

  defp implementation_context(_), do: {:blocked, :invalid_implementation_context}

  defp reviewer_context(context) when is_map(context) do
    required = [:feature_id, :task_id, :attempt_id, :execution_id, :implementation_attempt_id, :checkout_path]

    if Enum.all?(required, &(is_binary(context[&1]) and context[&1] != "")) and Map.get(context, :role, "reviewer") == "reviewer" do
      {:ok, Map.put_new(context, :role, "reviewer")}
    else
      {:blocked, :invalid_reviewer_context}
    end
  end

  defp reviewer_context(_), do: {:blocked, :invalid_reviewer_context}

  defp reviewer_result_identity(result) do
    required = ["feature_id", "task_id", "attempt_id", "execution_id", "role", "reviewed_sha"]

    if Enum.all?(required, &(is_binary(result[&1]) and result[&1] != "")),
      do:
        {:ok,
         %{
           feature_id: result["feature_id"],
           task_id: result["task_id"],
           attempt_id: result["attempt_id"],
           execution_id: result["execution_id"],
           role: result["role"],
           reviewed_sha: result["reviewed_sha"]
         }},
      else: {:blocked, :invalid_reviewer_result}
  end

  defp matching_reviewer_identity(identity, assignment) do
    if identity.task_id == assignment.task_id and identity.execution_id == assignment.execution_id and identity.role == assignment.role, do: :ok, else: {:blocked, :reviewer_identity_mismatch}
  end

  defp matching_reviewed_sha(sha, sha), do: :ok
  defp matching_reviewed_sha(_, _), do: {:blocked, :reviewed_sha_mismatch}
  defp same_task(context, implementation), do: if(context.task_id == implementation.task_id, do: :ok, else: {:blocked, :review_task_mismatch})

  defp same_reviewer_assignment?(
         [task_id, execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path],
         assignment
       ) do
    task_id == assignment.task_id and execution_id == assignment.execution_id and role == assignment.role and
      implementation_attempt_id == assignment.implementation_attempt_id and reviewed_sha == assignment.reviewed_sha and
      repository == assignment.repository and checkout_path == assignment.checkout_path
  end

  defp existing_reviewer_row(assignment) do
    [
      assignment.task_id,
      assignment.execution_id,
      assignment.role,
      assignment.implementation_attempt_id,
      assignment.reviewed_sha,
      assignment.repository,
      assignment.checkout_path
    ]
  end

  defp existing_reviewer_assignment(existing, assignment) do
    if same_reviewer_assignment?(existing, assignment) do
      {:ok,
       Map.take(assignment, [
         :feature_id,
         :task_id,
         :attempt_id,
         :execution_id,
         :role,
         :implementation_attempt_id,
         :reviewed_sha,
         :repository,
         :checkout_path
       ])}
    else
      {:blocked, :reviewer_attempt_already_bound}
    end
  end
end
