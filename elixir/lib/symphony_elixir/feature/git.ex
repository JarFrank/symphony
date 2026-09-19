defmodule SymphonyElixir.Feature.Git do
  @moduledoc """
  Coordinator-owned local Git primitives for an implementation/review handoff.

  This module never accepts a model SHA as authority.  It reads `HEAD` from the
  developer repository, persists that value with the developer execution, then
  builds a detached reviewer worktree from the persisted value.  It deliberately
  contains no remote, push, merge, PR, or tracker operation.
  """

  alias SymphonyElixir.Feature.{Effects, GitCommand, GitIntegrity, Store}

  @type implementation :: %{
          required(:feature_id) => String.t(),
          required(:task_id) => String.t(),
          required(:attempt_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:workspace) => Path.t(),
          required(:expected_branch) => String.t(),
          optional(:expected_head_sha) => String.t(),
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
         {:ok, sha} <- capture_or_reconcile(runtime, repository, context),
         :ok <- verify_commit(repository, sha) do
      implementation = Map.merge(context, %{repository: repository, sha: sha})

      with {:ok, persisted} <- persist_implementation(runtime, implementation),
           :ok <- complete_capture_intent(runtime, context, sha) do
        {:ok, persisted}
      end
    end
  end

  @doc "Returns a stable fingerprint for dirty developer changes at one exact branch head."
  @spec resumable_workspace_state(Path.t(), String.t()) :: {:ok, map()} | {:blocked, term()}
  def resumable_workspace_state(workspace, expected_branch) do
    with {:ok, facts} <- workspace_state(workspace, expected_branch),
         {:ok, fingerprint} <- dirty_fingerprint(facts.repository, facts.dirty_paths) do
      {:ok, Map.put(facts, :fingerprint, fingerprint)}
    end
  end

  @doc "Reads the immutable baseline facts needed to claim a developer workspace."
  @spec workspace_state(Path.t(), String.t()) :: {:ok, map()} | {:blocked, term()}
  def workspace_state(workspace, expected_branch) when is_binary(workspace) and is_binary(expected_branch) do
    with {:ok, repository} <- repository(workspace),
         :ok <- expected_branch(repository, expected_branch),
         {:ok, sha} <- git(repository, ["rev-parse", "HEAD"]),
         {:ok, changed} <- changed_paths(repository),
         :ok <- protected_git_paths(repository) do
      {:ok, %{workspace: Path.expand(workspace), repository: repository, branch: expected_branch, sha: sha, dirty_paths: changed}}
    end
  end

  def workspace_state(_, _), do: {:blocked, :invalid_workspace_state}

  @doc "Explicitly commits a user-approved dirty baseline before feature work begins."
  @spec adopt_dirty_baseline(Path.t(), String.t()) :: {:ok, String.t()} | {:blocked, term()}
  def adopt_dirty_baseline(workspace, expected_branch) do
    with {:ok, facts} <- workspace_state(workspace, expected_branch),
         true <- facts.dirty_paths != [],
         :ok <- no_in_progress_operation(facts.repository),
         :ok <- local_identity(facts.repository),
         {:ok, _} <- git(facts.repository, ["add", "-A"]),
         {:ok, _} <- git(facts.repository, ["commit", "-m", "symphony: adopt explicit baseline"]),
         {:ok, sha} <- git(facts.repository, ["rev-parse", "HEAD"]),
         {:ok, []} <- changed_paths(facts.repository) do
      {:ok, sha}
    else
      false -> {:blocked, :workspace_not_dirty_for_adoption}
      {:ok, _} -> {:blocked, :workspace_not_clean_after_adoption}
      {:blocked, _} = blocked -> blocked
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

  @doc "Returns the immutable commit and tree identities used by a validator."
  @spec candidate_identity(Path.t(), String.t()) :: {:ok, %{sha: String.t(), tree: String.t()}} | {:blocked, term()}
  def candidate_identity(repository, sha) when is_binary(repository) and is_binary(sha) and sha != "" do
    with {:ok, commit} <- git(repository, ["rev-parse", "#{sha}^{commit}"]),
         {:ok, tree} <- git(repository, ["rev-parse", "#{commit}^{tree}"]) do
      {:ok, %{sha: commit, tree: tree}}
    end
  end

  def candidate_identity(_, _), do: {:blocked, :invalid_candidate_identity}

  @doc "Creates an ephemeral detached worktree for one validation candidate."
  @spec prepare_validation_checkout(Path.t(), String.t(), Path.t()) :: {:ok, Path.t()} | {:blocked, term()}
  def prepare_validation_checkout(repository, sha, checkout_path) do
    with :ok <- new_checkout_path(checkout_path, repository),
         :ok <- worktree_add(repository, checkout_path, sha),
         :ok <- checkout_is_exact(checkout_path, sha),
         :ok <- checkout_is_clean(checkout_path) do
      {:ok, checkout_path}
    end
  end

  @doc "Reconciles a reviewer or validation checkout after its caller verifies the durable intent."
  @spec reconcile_owned_checkout(Path.t(), String.t(), String.t(), Path.t()) ::
          :missing | {:ok, Path.t()} | {:blocked, term()}
  def reconcile_owned_checkout(repository, sha, tree, checkout_path) do
    if File.lstat(checkout_path) != {:error, :enoent} do
      with :ok <- checkout_provenance(repository, checkout_path),
           :ok <- checkout_is_exact(checkout_path, sha),
           {:ok, identity} <- candidate_identity(checkout_path, sha),
           true <- identity.tree == tree,
           :ok <- finish_partial_checkout(checkout_path, sha),
           :ok <- checkout_is_clean(checkout_path) do
        {:ok, checkout_path}
      else
        false -> {:blocked, :validation_checkout_tree_mismatch}
        {:blocked, _} -> {:blocked, :validation_checkout_unsafe}
      end
    else
      # Prune only Git's stale metadata; it never removes a filesystem path.
      _ = git(repository, ["worktree", "prune"])
      :missing
    end
  end

  # Callers establish the matching durable intent before entering this shared
  # lifecycle. An absent index and an otherwise empty registered worktree are
  # the precise footprint of worktree add --no-checkout. Never reset an index
  # or overwrite any existing source to make a failed integrity check pass.
  defp finish_partial_checkout(checkout, sha) do
    with {:ok, index} <- git(checkout, ["rev-parse", "--path-format=absolute", "--git-path", "index"]) do
      case File.lstat(index) do
        {:error, :enoent} ->
          checkout_empty_directory(checkout, sha)

        {:ok, %{type: :regular}} ->
          :ok

        _ ->
          {:blocked, :checkout_index_unconfirmed}
      end
    end
  end

  defp checkout_empty_directory(checkout, sha) do
    case File.ls(checkout) do
      {:ok, [".git"]} -> git(checkout, ["checkout", "--detach", sha]) |> discard_output()
      _ -> {:blocked, :partial_checkout_dirty}
    end
  end

  defp checkout_provenance(repository, checkout) do
    with {:ok, actual} <- realpath(checkout),
         true <- actual == Path.expand(checkout),
         {:ok, common} <- git(repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, ^common} <- git(checkout, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {:ok, "HEAD"} <- git(checkout, ["rev-parse", "--abbrev-ref", "HEAD"]),
         {:ok, listing} <- git(repository, ["worktree", "list", "--porcelain", "-z"]),
         true <- ("worktree " <> actual) in String.split(listing, <<0>>) do
      :ok
    else
      _ -> {:blocked, :checkout_provenance_mismatch}
    end
  end

  @doc "Ensures a new validation path is absent before durable ownership is claimed."
  @spec validation_checkout_path_available(Path.t(), Path.t()) :: :ok | {:blocked, term()}
  def validation_checkout_path_available(repository, checkout_path), do: new_checkout_path(checkout_path, repository)

  @doc "Removes an ephemeral validation checkout."
  @spec remove_validation_checkout(Path.t(), Path.t()) :: :ok | {:blocked, term()}
  def remove_validation_checkout(repository, checkout_path), do: worktree_remove(repository, checkout_path) |> discard_output()

  @doc "Verifies that a validator left its checkout at the exact immutable tree."
  @spec validation_checkout_integrity(Path.t(), map()) :: :ok | {:blocked, term()}
  def validation_checkout_integrity(checkout_path, %{sha: sha, tree: tree}) do
    with :ok <- checkout_is_exact(checkout_path, sha),
         {:ok, actual} <- candidate_identity(checkout_path, sha),
         true <- actual.tree == tree,
         :ok <- checkout_is_clean(checkout_path) do
      :ok
    else
      false -> {:blocked, :validator_changed_tree}
      {:blocked, :reviewer_checkout_dirty} -> {:blocked, :validator_modified_sources}
      {:blocked, _} = blocked -> blocked
    end
  end

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
          existing_reviewer_assignment(db, existing, assignment)
      end
    end)
  end

  defp ensure_reviewer_checkout(runtime, assignment) do
    case reviewer_checkout(runtime, assignment.feature_id, assignment.attempt_id) do
      {:ok, existing} ->
        reuse_reviewer_checkout(runtime, existing, assignment)

      {:blocked, :reviewer_checkout_not_prepared} ->
        create_reviewer_checkout(runtime, assignment)
    end
  end

  defp reuse_reviewer_checkout(runtime, existing, assignment) do
    if same_reviewer_identity?(existing_reviewer_row(existing), assignment) do
      case exact_persisted_checkout(existing) do
        {:ok, _} -> rebind_reviewer_execution(runtime, existing, assignment)
        {:blocked, _} = blocked -> blocked
      end
    else
      {:blocked, :reviewer_attempt_already_bound}
    end
  end

  defp exact_persisted_checkout(existing) do
    with :ok <- checkout_provenance(existing.repository, existing.checkout_path),
         :ok <- checkout_is_exact(existing.checkout_path, existing.reviewed_sha),
         :ok <- checkout_is_clean(existing.checkout_path) do
      {:ok, existing}
    else
      {:blocked, _} -> {:blocked, :persisted_reviewer_checkout_not_exact}
    end
  end

  # A reviewer attempt names the immutable review decision (task + reviewed
  # commit), while execution_id names its current process.  Replacing a dead
  # process is therefore allowed only after every immutable binding matches.
  defp rebind_reviewer_execution(runtime, existing, assignment) do
    Store.transaction(runtime, fn db ->
      Store.execute(
        db,
        "UPDATE reviewer_checkouts SET execution_id = ? WHERE feature_id = ? AND attempt_id = ? AND task_id = ? AND role = ? AND implementation_attempt_id = ? AND reviewed_sha = ? AND repository = ? AND checkout_path = ?",
        [
          assignment.execution_id,
          existing.feature_id,
          existing.attempt_id,
          existing.task_id,
          existing.role,
          existing.implementation_attempt_id,
          existing.reviewed_sha,
          existing.repository,
          existing.checkout_path
        ]
      )

      case Store.execute(db, "SELECT changes()") do
        [[1]] -> {:ok, Map.put(assignment, :checkout_path, existing.checkout_path)}
        _ -> {:blocked, :reviewer_attempt_already_bound}
      end
    end)
  end

  defp create_reviewer_checkout(runtime, assignment) do
    key = "reviewer_checkout:#{assignment.attempt_id}"

    with {:ok, identity} <- reviewer_candidate(assignment),
         intent = reviewer_checkout_intent(assignment, identity.tree),
         :ok <- ensure_reviewer_intent(runtime, assignment, key, intent),
         :ok <- reconcile_reviewer_directory(assignment, identity.tree),
         {:ok, persisted} <- persist_reviewer_checkout(runtime, assignment),
         :ok <- Effects.complete(runtime, assignment.feature_id, key, intent) do
      {:ok, persisted}
    end
  end

  defp reviewer_candidate(assignment) do
    case candidate_identity(assignment.repository, assignment.reviewed_sha) do
      {:blocked, {:git_command_failed, _preflight, status}} ->
        {:blocked, {:git_command_failed, worktree_add_args(assignment.checkout_path, assignment.reviewed_sha), status}}

      result ->
        result
    end
  end

  defp reviewer_checkout_intent(assignment, tree) do
    assignment
    |> Map.take([:feature_id, :task_id, :attempt_id, :implementation_attempt_id, :reviewed_sha, :repository, :checkout_path])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Map.merge(%{"operation" => "reviewer_checkout", "tree" => tree})
  end

  defp ensure_reviewer_intent(runtime, assignment, key, intent) do
    case Effects.fetch(runtime, assignment.feature_id, key) do
      :missing ->
        with :ok <- new_checkout_path(assignment.checkout_path, assignment.repository) do
          Effects.intent(runtime, assignment.feature_id, key, intent)
        end

      {_status, ^intent, _result} ->
        :ok

      _ ->
        {:blocked, :reviewer_checkout_ownership_mismatch}
    end
  end

  defp reconcile_reviewer_directory(%{repository: repository, reviewed_sha: sha, checkout_path: checkout}, tree) do
    case reconcile_owned_checkout(repository, sha, tree, checkout) do
      :missing ->
        with :ok <- new_checkout_path(checkout, repository),
             :ok <- worktree_add(repository, checkout, sha),
             :ok <- checkout_provenance(repository, checkout) do
          validation_checkout_integrity(checkout, %{sha: sha, tree: tree})
        end

      {:ok, _} ->
        :ok

      {:blocked, _} = blocked ->
        blocked
    end
  end

  defp remove_checkout(assignment) do
    if File.exists?(assignment.checkout_path) do
      worktree_remove(assignment.repository, assignment.checkout_path) |> discard_output()
    else
      git(assignment.repository, ["worktree", "prune"]) |> discard_output()
    end
  end

  # The intent is written before the irreversible commit.  On a coordinator
  # restart we only accept HEAD when its parent, tree and commit subject bind it
  # to that exact intent; an arbitrary newer commit is never adopted.
  defp capture_or_reconcile(runtime, repository, context) do
    case capture_intent(runtime, context) do
      :missing -> capture_new_implementation(runtime, repository, context)
      effect -> reconcile_capture_intent(repository, context, effect)
    end
  end

  defp capture_new_implementation(runtime, repository, context) do
    with :ok <- expected_head(repository, context[:expected_head_sha]),
         :ok <- no_in_progress_operation(repository),
         {:ok, changed} <- changed_paths(repository),
         :ok <- safe_changed_paths(repository, changed),
         :ok <- protected_git_paths(repository) do
      select_or_commit_with_intent(runtime, repository, changed, context)
    end
  end

  defp select_or_commit_with_intent(_runtime, repository, [], _context), do: git(repository, ["rev-parse", "HEAD"])

  defp select_or_commit_with_intent(runtime, repository, changed, context) do
    with :ok <- permitted_changes(changed, context),
         :ok <- local_identity(repository),
         # All repository changes have already been enumerated and approved.
         # Stage from the repository root so Git can record deletions/renames,
         # whose source path no longer exists on disk.
         {:ok, _} <- git(repository, ["add", "-A"]),
         {:ok, parent} <- git(repository, ["rev-parse", "HEAD"]),
         {:ok, tree} <- git(repository, ["write-tree"]),
         :ok <- persist_capture_intent(runtime, context, parent, tree),
         {:ok, _} <- git(repository, ["commit", "-m", capture_commit_message(context)]),
         {:ok, sha} <- git(repository, ["rev-parse", "HEAD"]),
         {:ok, []} <- changed_paths(repository),
         {:ok, ^sha} <- reconcile_capture_intent(repository, context, capture_intent!(runtime, context)) do
      {:ok, sha}
    else
      {:ok, _dirty} -> {:blocked, :workspace_not_clean_after_commit}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp capture_intent(runtime, context), do: Effects.fetch(runtime, context.feature_id, capture_effect_key(context))
  defp capture_intent!(runtime, context), do: capture_intent(runtime, context)

  defp persist_capture_intent(runtime, context, parent, tree) do
    Effects.intent(runtime, context.feature_id, capture_effect_key(context), %{
      "attempt_id" => context.attempt_id,
      "branch" => context.expected_branch,
      "execution_id" => context.execution_id,
      "expected_parent" => parent,
      "feature_id" => context.feature_id,
      "operation" => "capture_implementation",
      "repository" => Path.expand(context.workspace),
      "task_id" => context.task_id,
      "tree" => tree
    })
  end

  defp reconcile_capture_intent(repository, context, {status, intent, result}) do
    with :ok <- matching_capture_intent(intent, context),
         {:ok, head} <- git(repository, ["rev-parse", "HEAD"]) do
      cond do
        status == :intent and head == intent["expected_parent"] -> resume_capture(repository, context, intent)
        status == :completed and result != %{"sha" => head} -> {:blocked, :unexpected_head}
        true -> confirm_capture(repository, context, intent, head)
      end
    end
  end

  defp resume_capture(repository, context, intent) do
    with :ok <- no_in_progress_operation(repository),
         {:ok, changed} <- changed_paths(repository),
         :ok <- safe_changed_paths(repository, changed),
         :ok <- permitted_changes(changed, context),
         :ok <- protected_git_paths(repository),
         :ok <- local_identity(repository),
         # Never restage a changed workspace into the previously approved intent.
         {:ok, ""} <- git(repository, ["diff", "--no-ext-diff", "--no-textconv", "--name-only"]),
         {:ok, ""} <- git(repository, ["ls-files", "--others", "--exclude-standard"]),
         {:ok, tree} <- git(repository, ["write-tree"]),
         true <- tree == intent["tree"],
         {:ok, _} <- git(repository, ["commit", "-m", capture_commit_message(context)]),
         {:ok, head} <- git(repository, ["rev-parse", "HEAD"]) do
      confirm_capture(repository, context, intent, head)
    else
      false -> {:blocked, :capture_intent_tree_mismatch}
      {:ok, _} -> {:blocked, :capture_intent_workspace_changed}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp confirm_capture(repository, context, intent, head) do
    with {:ok, parents} <- git(repository, ["show", "--no-patch", "--format=%P", head]),
         true <- parents == intent["expected_parent"],
         {:ok, identity} <- candidate_identity(repository, head),
         true <- identity.tree == intent["tree"],
         {:ok, message} <- git(repository, ["log", "-1", "--format=%s", head]),
         true <- message == capture_commit_message(context),
         :ok <- checkout_is_clean(repository) do
      {:ok, head}
    else
      false -> {:blocked, :unexpected_head}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp matching_capture_intent(intent, context) do
    expected = %{
      "attempt_id" => context.attempt_id,
      "branch" => context.expected_branch,
      "execution_id" => context.execution_id,
      "feature_id" => context.feature_id,
      "operation" => "capture_implementation",
      "repository" => Path.expand(context.workspace),
      "task_id" => context.task_id
    }

    if Map.take(intent, Map.keys(expected)) == expected, do: :ok, else: {:blocked, :capture_intent_identity_mismatch}
  end

  defp complete_capture_intent(runtime, context, sha) do
    case capture_intent(runtime, context) do
      :missing ->
        :ok

      {_status, _intent, _result} ->
        Effects.complete(runtime, context.feature_id, capture_effect_key(context), %{"sha" => sha})
    end
  end

  defp capture_effect_key(context), do: "capture:#{context.attempt_id}"
  defp capture_commit_message(context), do: "symphony: capture implementation #{context.attempt_id}"

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

  defp dirty_fingerprint(repository, paths) do
    with {:ok, diff} <- git(repository, ["diff", "--binary", "--no-ext-diff", "HEAD"]),
         {:ok, untracked} <- git(repository, ["ls-files", "--others", "--exclude-standard", "-z"]),
         {:ok, objects} <- untracked_object_ids(repository, untracked) do
      untracked = Enum.map(objects, fn {path, object_id} -> %{"path" => path, "object_id" => object_id} end)
      payload = Jason.encode!(%{"diff" => diff, "paths" => Enum.sort(paths), "untracked" => untracked})
      {:ok, :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)}
    end
  end

  defp untracked_object_ids(repository, output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case git(repository, ["hash-object", "--", path]) do
        {:ok, object_id} -> {:cont, {:ok, [{path, object_id} | acc]}}
        {:blocked, _} = blocked -> {:halt, blocked}
      end
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.sort(objects)}
      blocked -> blocked
    end
  end

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
    if File.lstat(expanded) == {:error, :enoent} and not same_or_contains?(repository, expanded), do: :ok, else: {:blocked, :reviewer_checkout_path_unsafe}
  end

  defp new_checkout_path(_, _), do: {:blocked, :reviewer_checkout_path_unsafe}

  defp same_or_contains?(parent, child), do: child == parent or String.starts_with?(child, parent <> "/")

  defp worktree_add_args(checkout, sha), do: ["worktree", "add", "--detach", "--no-checkout", checkout, sha]

  defp worktree_add(repository, checkout, sha) do
    case git(repository, worktree_add_args(checkout, sha)) do
      {:ok, _} -> git(checkout, ["checkout", "--detach", sha]) |> discard_output()
      {:blocked, _} = blocked -> blocked
    end
  end

  defp worktree_remove(repository, checkout), do: git(repository, ["worktree", "remove", "--force", checkout])
  defp checkout_is_exact(checkout, sha), do: git(checkout, ["rev-parse", "HEAD"]) |> equals(sha)

  defp checkout_is_clean(checkout) do
    with {:ok, []} <- changed_paths(checkout),
         {:ok, sha} <- git(checkout, ["rev-parse", "HEAD"]) do
      tracked_checkout_is_clean(checkout, sha)
    else
      {:ok, _changed} ->
        {:blocked, :reviewer_checkout_dirty}

      {:blocked, _} = blocked ->
        blocked
    end
  end

  defp tracked_checkout_is_clean(checkout, sha) do
    case GitIntegrity.verify(checkout, sha) do
      :ok -> :ok
      {:blocked, _} -> {:blocked, :reviewer_checkout_dirty}
    end
  end

  defp verify_commit(repository, sha), do: git(repository, ["rev-parse", "#{sha}^{commit}"]) |> equals(sha)
  defp expected_head(_repository, nil), do: :ok
  defp expected_head(repository, sha) when is_binary(sha) and sha != "", do: git(repository, ["rev-parse", "HEAD"]) |> equals(sha) |> head_mismatch()
  defp expected_head(_, _), do: {:blocked, :invalid_expected_head}
  defp head_mismatch(:ok), do: :ok
  defp head_mismatch({:blocked, :git_identity_mismatch}), do: {:blocked, :unexpected_head}
  defp head_mismatch(other), do: other
  defp equals({:ok, value}, value), do: :ok
  defp equals({:ok, _}, _), do: {:blocked, :git_identity_mismatch}
  defp equals({:blocked, _} = blocked, _), do: blocked
  defp discard_output({:ok, _}), do: :ok
  defp discard_output({:blocked, _} = blocked), do: blocked

  defp git(directory, args), do: GitCommand.run(directory, args)

  defp implementation_context(context) when is_map(context) do
    required = [:feature_id, :task_id, :attempt_id, :execution_id, :workspace, :expected_branch]

    if Enum.all?(required, &(is_binary(context[&1]) and context[&1] != "")) and Map.get(context, :role, "developer") == "developer" and
         valid_path_list?(context, :allowed_paths) and valid_path_list?(context, :protected_paths) and
         valid_expected_head?(context[:expected_head_sha]) do
      {:ok,
       context
       |> Map.put_new(:role, "developer")
       |> Map.update(:protected_paths, default_protected_paths(), &((default_protected_paths() ++ &1) |> Enum.uniq()))}
    else
      {:blocked, :invalid_implementation_context}
    end
  end

  defp implementation_context(_), do: {:blocked, :invalid_implementation_context}

  defp valid_expected_head?(nil), do: true
  defp valid_expected_head?(sha), do: is_binary(sha) and sha != ""

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

  defp same_reviewer_identity?(
         [task_id, execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path],
         assignment
       ) do
    task_id == assignment.task_id and is_binary(execution_id) and role == assignment.role and
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

  defp existing_reviewer_assignment(db, existing, assignment) do
    if same_reviewer_identity?(existing, assignment) do
      # This branch is reached only while creating a brand new checkout.  A
      # concurrent creator may have persisted the same immutable review; its
      # runtime binding can safely be moved to this fresh execution.
      [task_id, _execution_id, role, implementation_attempt_id, reviewed_sha, repository, checkout_path] = existing

      Store.execute(
        db,
        "UPDATE reviewer_checkouts SET execution_id = ? WHERE attempt_id = ? AND task_id = ? AND role = ? AND implementation_attempt_id = ? AND reviewed_sha = ? AND repository = ? AND checkout_path = ?",
        [
          assignment.execution_id,
          assignment.attempt_id,
          task_id,
          role,
          implementation_attempt_id,
          reviewed_sha,
          repository,
          checkout_path
        ]
      )

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
