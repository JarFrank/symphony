defmodule SymphonyElixir.FeatureRunner do
  @moduledoc """
  Standalone Stage 2 Task 1 fake runner. It journals `prepare -> execute ->
  record -> apply`; only the three journal phases hold SQLite write locks.
  """
  alias SymphonyElixir.Feature.{Git, GitIntegrity, ProcessOwner, Readiness, State, Store, WorkspaceLock}

  @spec create(Path.t(), String.t(), String.t()) :: map()
  def create(path, id, spec) do
    Store.transaction(path, fn db ->
      Store.execute(db, "INSERT OR IGNORE INTO features VALUES (?, 0, ?)", [id, Jason.encode!(State.new(spec))])
      state = Store.fetch(db, id)
      if state["spec"] != spec, do: raise(ArgumentError, "feature specification changed")
      state
    end)
  end

  @spec get(Path.t(), String.t()) :: map()
  def get(path, id), do: Store.transaction(path, &Store.fetch(&1, id))

  @spec step(Path.t(), String.t(), (String.t(), map() -> map())) :: map()
  def step(path, id, executor) do
    case capture(path, id, executor) do
      {:captured, revision} -> advance(path, id, revision)
      {:idle, state} -> state
      {:running, _execution} -> get(path, id)
    end
  end

  @spec capture(Path.t(), String.t(), (String.t(), map() -> map())) :: tuple()
  def capture(path, id, executor) do
    case prepare(path, id) do
      {:execute, execution} ->
        try do
          result = executor.(execution.state_role, execution.input)
          record(path, id, execution, result)
        rescue
          error ->
            release(path, id, execution)
            reraise error, __STACKTRACE__
        end

      other ->
        other
    end
  end

  @spec prepare(Path.t(), String.t()) :: tuple()
  def prepare(path, id), do: prepare(path, id, false)

  @doc false
  @spec prepare_recovery(Path.t(), String.t()) :: tuple()
  def prepare_recovery(path, id), do: prepare(path, id, true)

  defp prepare(path, id, replacement?) do
    # A fresh execution may become the writer only after the prior process for
    # *this attempt* has been stopped and its cgroup observed empty.  Do not
    # let an unrelated feature's ambiguous journal record silently influence
    # this attempt's identity; its own replacement will fail closed.
    previous_execution_id =
      Store.read(path, fn db ->
        case Store.execute(db, "SELECT execution_id FROM attempts WHERE feature_id = ? AND revision = (SELECT revision FROM features WHERE id = ?)", [id, id]) do
          [[execution_id]] when is_binary(execution_id) -> execution_id
          _ -> nil
        end
      end)

    case if(previous_execution_id, do: ProcessOwner.recover_execution(path, previous_execution_id), else: :ok) do
      :ok ->
        Store.transaction(path, fn db ->
          state = Store.fetch(db, id)

          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          case State.role(state) do
            nil -> {:idle, state}
            role -> prepare_attempt(db, id, state, role, replacement?)
          end
        end)

      {:blocked, reason} ->
        {:blocked, {:previous_execution_unconfirmed, reason}}
    end
  end

  @spec record(Path.t(), String.t(), map(), term()) :: {:captured, non_neg_integer()}
  def record(path, id, execution, result) do
    Store.transaction(path, fn db ->
      [[status, execution_id, _owner]] = Store.execute(db, "SELECT status, execution_id, execution_owner FROM attempts WHERE feature_id = ? AND revision = ?", [id, execution.revision])

      # ProcessOwner has already fenced and reconciled a replacement before it
      # can be prepared.  The execution id is the durable fencing token; an
      # in-memory owner token must not make a completed, journaled output
      # unrecoverable after a coordinator VM restart.
      if status != "running" or execution_id != execution.execution_id do
        raise ArgumentError, "stale execution"
      end

      Store.execute(db, "UPDATE attempts SET status = 'recorded', result_json = ? WHERE feature_id = ? AND revision = ? AND execution_id = ? AND execution_owner = ?", [
        encode_result(execution.input, result),
        id,
        execution.revision,
        execution.execution_id,
        execution.owner_token
      ])

      Store.execute(db, "UPDATE role_executions SET status = 'recorded' WHERE execution_id = ?", [execution.execution_id])

      {:captured, execution.revision}
    end)
  end

  @spec advance(Path.t(), String.t(), non_neg_integer()) :: map()
  def advance(path, id, revision) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      [["recorded", json]] = Store.execute(db, "SELECT status, result_json FROM attempts WHERE feature_id = ? AND revision = ?", [id, revision])
      next = State.transition(state, Jason.decode!(json))
      saved = Store.save(db, id, revision, next)
      Store.sync_workspace_claim(db, id, saved)
      Store.execute(db, "UPDATE attempts SET status = 'applied' WHERE feature_id = ? AND revision = ?", [id, revision])
      Store.execute(db, "UPDATE role_executions SET status = 'applied' WHERE execution_id = (SELECT execution_id FROM attempts WHERE feature_id = ? AND revision = ?)", [id, revision])
      saved
    end)
  end

  @spec answer(Path.t(), String.t(), non_neg_integer(), String.t()) :: map()
  def answer(path, id, revision, answer) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      if state["phase"] != "WaitingForHuman", do: raise(ArgumentError, "not waiting for human")
      Store.save(db, id, revision, State.answer(state, answer))
    end)
  end

  @doc "Applies coordinator-owned executable-validation evidence to the current candidate."
  @spec apply_validation(Path.t(), String.t(), non_neg_integer(), map()) :: map()
  def apply_validation(path, id, revision, evidence) when is_map(evidence) do
    apply_validation(path, id, revision, evidence, %{})
  end

  @spec apply_validation(Path.t(), String.t(), non_neg_integer(), map(), map()) :: map()
  def apply_validation(path, id, revision, evidence, repair_budget) when is_map(evidence) and is_map(repair_budget) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)

      if active_writer?(db, id), do: raise(ArgumentError, "validation cannot apply while a writer is active")
      if evidence["status"] == "passed" and not processes_confirmed?(db, id), do: raise(ArgumentError, "validation cannot pass before process termination is confirmed")

      result =
        case evidence["status"] do
          "passed" -> %{"status" => "validation_passed", "validation" => evidence}
          "failed" -> %{"status" => "validation_failed", "validation" => evidence, "repair_budget" => repair_budget}
          "blocked" -> %{"status" => "validation_blocked", "validation" => evidence}
          _ -> %{"status" => "invalid"}
        end

      Store.save(db, id, revision, State.transition(state, result))
    end)
  end

  @doc """
  The sole authoritative transition to `ReadyForHuman`.

  The legacy arity intentionally fails closed: a caller without live workspace
  context cannot establish final readiness from a state-shaped map.
  """
  @spec complete_readiness(Path.t(), String.t(), non_neg_integer()) :: map()
  def complete_readiness(path, id, revision) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)

      if processes_confirmed?(db, id),
        do: Store.save(db, id, revision, readiness_blocker(state, :readiness_context_required)),
        else:
          Store.save(
            db,
            id,
            revision,
            State.put_status(state, %{
              "technical_blocker" => "process termination is not confirmed",
              "latest_event" => "readiness blocked by unconfirmed process execution"
            })
            |> Map.put("technical_blocker", "process termination is not confirmed")
          )
    end)
  end

  @spec complete_readiness(Path.t(), String.t(), non_neg_integer(), map()) :: map()
  def complete_readiness(path, id, revision, context) when is_map(context) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      candidate = clear_retryable_readiness_blocker(state)

      case readiness_evidence(db, path, id, candidate, context) do
        :ok ->
          ready =
            candidate
            |> Map.put("phase", "ReadyForHuman")
            |> Map.put("release_status", "pending")
            |> State.put_status(%{"current_operation" => "workspace_release_pending"})

          Store.save(db, id, revision, ready)

        {:blocked, reason} ->
          Store.save(db, id, revision, readiness_blocker(candidate, reason))
      end
    end)
  end

  def complete_readiness(path, id, revision, _context), do: readiness_blocked(path, id, revision, :invalid_readiness_context)

  @doc false
  @spec readiness_verified?(Path.t(), String.t(), map()) :: :ok | {:blocked, term()}
  def readiness_verified?(path, id, context) when is_map(context) do
    verify_ready_workspace(path, id, context, :owned)
  end

  def readiness_verified?(_, _, _), do: {:blocked, :invalid_readiness_context}

  @doc "Verifies durable readiness for cleanup, allowing a host fence already released."
  @spec release_verified?(Path.t(), String.t(), map()) :: :ok | {:blocked, term()}
  def release_verified?(path, id, context) do
    verify_ready_workspace(path, id, context, :release)
  end

  defp verify_ready_workspace(path, id, context, lock_mode) do
    Store.read(path, fn db ->
      state = Store.fetch(db, id) |> clear_release_blocker()

      if state["phase"] == "ReadyForHuman",
        do: readiness_evidence(db, path, id, Map.put(state, "phase", "ReadinessCheck"), context, lock_mode),
        else: {:blocked, :not_ready_for_human}
    end)
  end

  @doc """
  Reopens a terminal role failure using the exact durable state that was given
  to the failed role.  Historical attempts and role outputs are never changed.

  The operation deliberately has no "already retried" success case: after the
  first transaction changes the feature away from `Failed`, a repeated (or
  concurrent) caller is rejected.
  """
  @spec retry(Path.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def retry(path, id) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)

      with "Failed" <- state["phase"],
           {:ok, input} <- failed_attempt_input(db, id, state),
           {:ok, restored} <- restore_failed_input(input, state) do
        {:ok, Store.save(db, id, state["revision"], restored)}
      else
        _ -> {:error, :retry_not_recoverable}
      end
    end)
  end

  @doc "Durably reopens a selected task without rewriting prior attempts, reviews, or findings."
  @spec recover_task(Path.t(), String.t(), non_neg_integer(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def recover_task(path, id, revision, task_id, diagnostic) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)

      with ^revision <- state["revision"],
           {:ok, restored} <- State.reopen_for_repair(state, task_id, diagnostic) do
        {:ok, Store.save(db, id, revision, restored)}
      else
        _ -> {:error, :recovery_not_applicable}
      end
    end)
  end

  defp prepare_attempt(db, id, state, role, replacement?) do
    revision = state["revision"]
    owner = owner_token()
    rows = Store.execute(db, "SELECT status, execution_owner FROM attempts WHERE feature_id = ? AND revision = ?", [id, revision])

    case rows do
      [] -> create_execution(db, id, revision, state, role, owner)
      [["recorded", _]] -> {:captured, revision}
      [["running", ^owner]] when not replacement? -> {:running, %{revision: revision}}
      [["running", _]] -> create_execution(db, id, revision, state, role, owner)
    end
  end

  # A failure at feature revision N must have been applied by the attempt at
  # N - 1.  Reconstructing its transition protects against malformed or
  # manually edited journals and also prevents retrying an unrelated attempt.
  defp failed_attempt_input(db, id, %{"revision" => revision} = failed) when revision > 0 do
    case Store.execute(
           db,
           "SELECT status, input_json, result_json FROM attempts WHERE feature_id = ? AND revision = ?",
           [id, revision - 1]
         ) do
      [["applied", input_json, result_json]] ->
        with {:ok, input} <- decode_map(input_json),
             {:ok, result} <- decode_map(result_json),
             true <- input["revision"] == revision - 1,
             role when is_binary(role) <- State.role(input),
             transitioned <- State.transition(input, result),
             true <- comparable_state(transitioned) == comparable_state(failed) do
          {:ok, input}
        else
          _ -> {:error, :invalid_failed_attempt}
        end

      _ ->
        {:error, :missing_failed_attempt}
    end
  rescue
    _ -> {:error, :invalid_failed_attempt}
  end

  defp failed_attempt_input(_db, _id, _failed), do: {:error, :missing_failed_attempt}

  # Status is an observational projection with wall-clock event timestamps;
  # it cannot be part of the immutable lifecycle replay comparison.
  defp comparable_state(state), do: state |> Map.delete("revision") |> Map.delete("status")

  defp restore_failed_input(input, failed) do
    restored = Map.delete(input, "revision")

    # The original state must be an active role state, preserve the approved
    # specification, and have the same durable plan/task history as the failed
    # state.  This intentionally excludes retrying a failed planning result.
    if is_binary(State.role(restored)) and restored["phase"] != "Planning" and
         restored["spec"] == failed["spec"] and restored["tasks"] == failed["tasks"] do
      {:ok, restored}
    else
      {:error, :invalid_restore_state}
    end
  rescue
    _ -> {:error, :invalid_restore_state}
  end

  defp decode_map(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_map(_), do: {:error, :invalid_json}

  defp create_execution(db, id, revision, state, role, owner) do
    attempt_id =
      case Store.execute(db, "SELECT attempt_id FROM attempts WHERE feature_id = ? AND revision = ?", [id, revision]) do
        [[existing]] when is_binary(existing) and existing != "" -> existing
        [] -> token()
      end

    execution = %{
      attempt_id: attempt_id,
      execution_id: token(),
      feature_id: id,
      owner_token: owner,
      revision: revision,
      input: state,
      state_role: role
    }

    Store.execute(db, "UPDATE role_executions SET status = 'replaced' WHERE feature_id = ? AND attempt_revision = ? AND status = 'running'", [id, revision])

    Store.execute(
      db,
      "INSERT INTO attempts (feature_id, revision, status, result_json, attempt_id, input_json, execution_id, execution_owner) VALUES (?, ?, 'running', NULL, ?, ?, ?, ?) ON CONFLICT(feature_id, revision) DO UPDATE SET status = excluded.status, result_json = NULL, execution_id = excluded.execution_id, execution_owner = excluded.execution_owner",
      [id, revision, execution.attempt_id, Jason.encode!(state), execution.execution_id, owner]
    )

    Store.execute(
      db,
      "INSERT INTO role_executions (execution_id, feature_id, attempt_revision, attempt_id, role, status, session_id) VALUES (?, ?, ?, ?, ?, 'running', NULL)",
      [execution.execution_id, id, revision, execution.attempt_id, role]
    )

    {:execute, execution}
  end

  defp release(path, id, execution) do
    Store.transaction(path, fn db ->
      Store.execute(db, "UPDATE attempts SET execution_owner = NULL WHERE feature_id = ? AND revision = ? AND execution_id = ? AND execution_owner = ? AND status = 'running'", [
        id,
        execution.revision,
        execution.execution_id,
        execution.owner_token
      ])
    end)
  end

  defp owner_token do
    key = {__MODULE__, :owner_token}

    case :persistent_term.get(key, nil) do
      nil ->
        value = token()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp token, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  defp active_writer?(db, id), do: Store.execute(db, "SELECT 1 FROM attempts WHERE feature_id = ? AND status = 'running' LIMIT 1", [id]) != []
  defp processes_confirmed?(db, id), do: Store.execute(db, "SELECT 1 FROM process_executions WHERE feature_id = ? AND status != 'terminated' LIMIT 1", [id]) == []

  defp readiness_blocked(path, id, revision, reason) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      Store.save(db, id, revision, readiness_blocker(state, reason))
    end)
  end

  defp readiness_blocker(state, reason) do
    blocker = %{"operation" => "final_readiness", "reason" => inspect(reason)}

    state
    |> State.put_status(%{
      "technical_blocker" => blocker,
      "latest_event" => "readiness blocked by durable evidence or workspace integrity"
    })
    |> Map.put("technical_blocker", blocker)
  end

  # A release blocker reports cleanup, not a revoked readiness decision. Retry
  # the full evidence/live gate without letting that prior failure block itself.
  defp clear_release_blocker(%{"phase" => "ReadyForHuman", "technical_blocker" => %{"operation" => "workspace_release"}} = state),
    do: Map.put(state, "technical_blocker", nil)

  defp clear_release_blocker(state), do: state

  defp clear_retryable_readiness_blocker(%{"technical_blocker" => %{"operation" => "final_readiness"}} = state),
    do: state |> Map.put("technical_blocker", nil) |> State.put_status(%{"technical_blocker" => nil})

  defp clear_retryable_readiness_blocker(state), do: state

  # This predicate intentionally reads both durable facts and the live host
  # state.  A persisted `head` or review map is only a claim; it is never the
  # authority for final readiness.
  defp readiness_evidence(db, runtime, feature_id, state, context, lock_mode \\ :owned) do
    final_sha = state["final_sha"]

    with true <- Readiness.ready?(state, active_writer?(db, feature_id), processes_confirmed?(db, feature_id)),
         {:ok, facts, identity} <- live_workspace(db, runtime, feature_id, context, final_sha, lock_mode),
         :ok <- captured_final?(db, feature_id, state, facts, final_sha),
         :ok <- final_validation?(db, feature_id, final_sha, identity.tree),
         :ok <- required_reviews?(db, feature_id, state, facts.repository, final_sha) do
      :ok
    else
      false -> {:blocked, :state_readiness_invariant_failed}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp live_workspace(db, runtime, feature_id, context, final_sha, lock_mode) do
    with workspace when is_binary(workspace) and workspace != "" <- context[:workspace] || context["workspace"],
         branch when is_binary(branch) and branch != "" <- context[:expected_branch] || context["expected_branch"],
         true <- is_binary(final_sha) and final_sha != "",
         :ok <- workspace_fence(workspace, runtime, feature_id, lock_mode),
         {:ok, facts} <- Git.workspace_state(workspace, branch),
         true <- facts.sha == final_sha and facts.dirty_paths == [],
         :ok <- GitIntegrity.verify(facts.repository, final_sha),
         [[^feature_id, ^branch, ^final_sha]] <-
           Store.execute(
             db,
             "SELECT feature_id, expected_branch, expected_head_sha FROM workspace_ownership WHERE workspace = ?",
             [Path.expand(workspace)]
           ),
         {:ok, identity} <- Git.candidate_identity(facts.repository, final_sha) do
      {:ok, facts, identity}
    else
      false -> {:blocked, :workspace_integrity_blocker}
      [] -> {:blocked, :workspace_ownership_missing}
      [_] -> {:blocked, :workspace_ownership_mismatch}
      {:blocked, _} = blocked -> blocked
      _ -> {:blocked, :invalid_live_workspace}
    end
  end

  defp workspace_fence(workspace, runtime, feature_id, :owned), do: WorkspaceLock.owned?(workspace, runtime, feature_id)
  defp workspace_fence(workspace, runtime, feature_id, :release), do: WorkspaceLock.releasable?(workspace, runtime, feature_id)

  defp captured_final?(db, feature_id, state, repository, final_sha) when is_binary(final_sha) do
    attempt_id = state["implementation_attempt_id"]
    task_shas = Enum.map(state["tasks"] || [], & &1["head_sha"])

    case Store.execute(
           db,
           "SELECT task_id FROM implementation_commits WHERE feature_id = ? AND attempt_id = ? AND role = 'developer' AND repository = ? AND branch = ? AND sha = ?",
           [feature_id, attempt_id, repository.repository, repository.branch, final_sha]
         ) do
      [[task_id]] ->
        if(final_sha in task_shas and is_binary(task_id),
          do: :ok,
          else: {:blocked, :final_capture_missing_or_stale}
        )

      _ ->
        {:blocked, :final_capture_missing_or_stale}
    end
  end

  defp captured_final?(_, _, _, _, _), do: {:blocked, :final_capture_missing_or_stale}

  defp final_validation?(db, feature_id, sha, tree) when is_binary(sha) and is_binary(tree) do
    rows =
      Store.execute(
        db,
        "SELECT evidence_json FROM validation_evidence WHERE feature_id = ? AND purpose = 'final' AND sha = ? AND tree = ? AND status = 'passed'",
        [feature_id, sha, tree]
      )

    if Enum.any?(rows, &valid_final_validation?(&1, db, feature_id, sha, tree)), do: :ok, else: {:blocked, :final_validation_missing_or_stale}
  end

  defp final_validation?(_, _, _, _), do: {:blocked, :final_validation_missing_or_stale}

  defp valid_final_validation?([json], db, feature_id, sha, tree) do
    with {:ok, evidence} <- Jason.decode(json),
         true <- evidence["status"] == "passed" and evidence["sha"] == sha and evidence["tree"] == tree,
         true <- is_binary(evidence["started_at"]) and is_binary(evidence["ended_at"]),
         execution_id when is_binary(execution_id) and execution_id != "" <- evidence["process_execution_id"],
         [["terminated", ^sha, ^tree]] <-
           Store.execute(
             db,
             "SELECT status, candidate_sha, candidate_tree FROM process_executions WHERE execution_id = ? AND feature_id = ? AND execution_kind = 'validation'",
             [execution_id, feature_id]
           ) do
      true
    else
      _ -> false
    end
  end

  defp valid_final_validation?(_, _, _, _, _), do: false

  defp required_reviews?(db, feature_id, state, repository, final_sha) do
    task_reviews = Enum.all?(state["tasks"] || [], &task_reviewed?(db, feature_id, &1, repository))

    final_review =
      (state["final_review"] || state["review"] || %{})
      |> Map.put_new("task_id", get_in(state, ["tasks", Access.at(state["current"] || 0), "id"]))

    if task_reviews and review_assignment?(db, feature_id, final_review, repository, final_sha, state["implementation_attempt_id"]),
      do: :ok,
      else: {:blocked, :review_assignment_missing_or_stale}
  end

  defp task_reviewed?(db, feature_id, task, repository) when is_map(task) do
    review = (task["review"] || %{}) |> Map.put_new("task_id", task["id"])
    task["status"] == "accepted" and review_assignment?(db, feature_id, review, repository, review["sha"], nil)
  end

  defp task_reviewed?(_, _, _, _), do: false

  defp review_assignment?(db, feature_id, review, repository, sha, implementation_attempt_id)
       when is_map(review) and is_binary(sha) do
    attempt_id = review["review_attempt_id"]
    execution_id = review["review_execution_id"]
    task_id = review["task_id"]

    query =
      "SELECT 1 FROM reviewer_checkouts WHERE feature_id = ? AND attempt_id = ? AND execution_id = ? AND task_id = ? AND role = 'reviewer' AND reviewed_sha = ? AND repository = ?" <>
        if(is_binary(implementation_attempt_id), do: " AND implementation_attempt_id = ?", else: "")

    params =
      [feature_id, attempt_id, execution_id, task_id, sha, repository] ++
        if(is_binary(implementation_attempt_id), do: [implementation_attempt_id], else: [])

    review["status"] == "approved" and Store.execute(db, query, params) == [[1]]
  end

  defp review_assignment?(_, _, _, _, _, _), do: false
  defp ensure_revision!(%{"revision" => revision}, revision), do: :ok
  defp ensure_revision!(_, _), do: raise(ArgumentError, "stale revision")

  defp encode_result(state, result) do
    if State.valid_result?(state, result) do
      case Jason.encode(result) do
        {:ok, json} -> json
        {:error, _} -> invalid_result_json()
      end
    else
      invalid_result_json()
    end
  rescue
    Protocol.UndefinedError -> invalid_result_json()
  end

  defp invalid_result_json, do: Jason.encode!(%{"status" => "invalid"})
end
