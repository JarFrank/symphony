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
          optional(:allowed_paths) => [Path.t()],
          optional(:protected_paths) => [Path.t()]
        }

  @doc """
  Captures the implementation commit from Git, rather than from Developer output.

  A clean workspace selects `HEAD`. By default, a dirty workspace may contain
  changes anywhere below the repository root except protected paths. Supplying
  `allowed_paths` opts into the legacy narrow allowlist in addition to the
  protected-path policy. The coordinator stages the complete approved set and
  creates a local commit using the repository local author identity.
  """
  @spec capture_implementation(Path.t(), implementation()) :: {:ok, map()} | {:blocked, term()}
  def capture_implementation(runtime, context) do
    with {:ok, context} <- implementation_context(context),
         {:ok, repository} <- repository(context.workspace),
         :ok <- expected_branch(repository, context.expected_branch),
         :ok <- no_in_progress_operation(repository),
         {:ok, changed} <- changed_paths(repository),
         :ok <- safe_changed_paths(repository, changed),
         :ok <- protected_git_paths(repository),
         {:ok, sha} <- select_or_commit(repository, changed, context),
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

  defp select_or_commit(repository, [], _context), do: git(repository, ["rev-parse", "HEAD"])

  defp select_or_commit(repository, changed, context) do
    with :ok <- permitted_changes(changed, context),
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

  # `allowed_paths` is deliberately distinguished from an omitted key: omitted
  # means repository-wide scope; an explicit empty list means permit no changes.
  defp permitted_changes(changed, context) do
    protected = Enum.filter(changed, &protected_path?(&1, context.protected_paths))

    cond do
      protected != [] ->
        {:blocked, {:protected_paths, protected}}

      Map.has_key?(context, :allowed_paths) ->
        unexpected = Enum.reject(changed, &allowed_path?(&1, context.allowed_paths))
        if unexpected == [], do: :ok, else: {:blocked, {:unexpected_dirty_paths, unexpected}}

      true ->
        :ok
    end
  end

  defp allowed_path?(path, allowed_paths), do: Enum.any?(allowed_paths, &(path == &1 or String.starts_with?(path, &1 <> "/")))

  defp protected_path?(path, protected_paths), do: Enum.any?(protected_paths, &glob_match?(path, &1))

  defp glob_match?(path, pattern) do
    base = String.replace_suffix(pattern, "/**", "")

    path == base or
      Regex.match?(glob_regex(pattern), path)
  end

  defp glob_regex(pattern) do
    {prefix, rest} =
      if String.starts_with?(pattern, "**/"),
        do: {"(?:.*/)?", String.replace_prefix(pattern, "**/", "")},
        else: {"", pattern}

    escaped =
      rest
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    Regex.compile!("^" <> prefix <> escaped <> "$")
  end

  defp safe_changed_paths(repository, changed) do
    unsafe = Enum.reject(changed, &safe_changed_path?(repository, &1))
    if unsafe == [], do: :ok, else: {:blocked, {:unsafe_changed_paths, unsafe}}
  end

  defp safe_changed_path?(repository, path) do
    expanded = Path.expand(path, repository)

    Path.type(path) == :relative and path != "." and path != ".." and
      not String.starts_with?(path, "../") and same_or_contains?(repository, expanded) and
      no_symlink_escape?(repository, expanded)
  end

  defp no_symlink_escape?(repository, path) do
    with {:ok, root} <- realpath(repository),
         {:ok, resolved} <- realpath_if_present(path) do
      same_or_contains?(root, resolved)
    else
      # A missing deleted path is safe after its lexical containment check; a
      # broken symlink or an inaccessible existing path is not.
      :missing -> true
      _ -> false
    end
  end

  defp realpath_if_present(path) do
    case File.lstat(path) do
      {:ok, _} -> realpath(path)
      {:error, :enoent} -> :missing
      error -> error
    end
  end

  defp realpath(path) do
    case System.cmd("realpath", ["-e", path], stderr_to_stdout: true) do
      {resolved, 0} -> {:ok, String.trim_trailing(resolved)}
      {_output, _status} -> {:error, :realpath_failed}
    end
  rescue
    _ -> {:error, :realpath_unavailable}
  end

  # Git intentionally ignores its administrative directory in porcelain
  # output. Reject non-Git artifacts there so an attempted `.git/**` write is
  # never silently overlooked. Normal Git metadata is needed for capture.
  defp protected_git_paths(repository) do
    with {:ok, git_dir} <- git(repository, ["rev-parse", "--absolute-git-dir"]),
         {:ok, entries} <- File.ls(git_dir) do
      blocked =
        entries
        |> Enum.reject(&git_managed_entry?/1)
        |> Enum.map(&Path.join(".git", &1))
        |> Kernel.++(unexpected_git_hooks(git_dir))

      if blocked == [], do: :ok, else: {:blocked, {:protected_paths, blocked}}
    else
      _ -> {:blocked, :git_directory_unavailable}
    end
  end

  defp git_managed_entry?(entry), do: entry in ~w(COMMIT_EDITMSG HEAD ORIG_HEAD FETCH_HEAD config description hooks index info logs objects refs rr-cache shallow worktrees packed-refs)

  defp unexpected_git_hooks(git_dir) do
    case File.ls(Path.join(git_dir, "hooks")) do
      {:ok, hooks} ->
        hooks
        |> Enum.reject(&String.ends_with?(&1, ".sample"))
        |> Enum.map(&Path.join([".git", "hooks", &1]))

      {:error, :enoent} ->
        []

      {:error, _} ->
        [".git/hooks"]
    end
  end

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

  defp changed_paths(repository), do: git(repository, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) |> parse_status()
  defp parse_status({:ok, output}), do: porcelain_paths(output)
  defp parse_status({:blocked, _} = blocked), do: blocked

  defp porcelain_paths(""), do: {:ok, []}

  defp porcelain_paths(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> parse_porcelain_records([])
  end

  defp parse_porcelain_records([], paths), do: {:ok, Enum.reverse(paths)}

  defp parse_porcelain_records([<<status::binary-size(2), ?\s, path::binary>> | rest], paths) do
    if renamed_or_copied?(status) do
      case rest do
        [source | remaining] -> parse_porcelain_records(remaining, [source, path | paths])
        [] -> {:blocked, :ambiguous_git_status}
      end
    else
      parse_porcelain_records(rest, [path | paths])
    end
  end

  defp parse_porcelain_records(_, _), do: {:blocked, :ambiguous_git_status}

  defp renamed_or_copied?(status), do: :binary.at(status, 0) in [?R, ?C] or :binary.at(status, 1) in [?R, ?C]

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
         valid_path_list?(context, :allowed_paths) and valid_path_list?(context, :protected_paths) do
      {:ok,
       context
       |> Map.put_new(:role, "developer")
       |> Map.update(:protected_paths, default_protected_paths(), &((default_protected_paths() ++ &1) |> Enum.uniq()))}
    else
      {:blocked, :invalid_implementation_context}
    end
  end

  defp implementation_context(_), do: {:blocked, :invalid_implementation_context}

  defp valid_path_list?(context, key) do
    not Map.has_key?(context, key) or
      (is_list(context[key]) and Enum.all?(context[key], &(is_binary(&1) and &1 != "" and relative_path_pattern?(&1))))
  end

  defp relative_path_pattern?(path), do: Path.type(path) != :absolute and path not in [".", ".."] and not String.starts_with?(path, "../")

  @doc false
  @spec default_protected_paths() :: [Path.t()]
  def default_protected_paths do
    [
      ".git/**",
      ".env",
      ".env.*",
      "**/.env",
      "**/.env.*",
      "*.pem",
      "**/*.pem",
      "*.key",
      "**/*.key",
      "id_rsa",
      "**/id_rsa",
      ".netrc",
      "**/.netrc",
      "credentials*",
      "**/credentials*",
      "secrets*",
      "**/secrets*"
    ]
  end

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
