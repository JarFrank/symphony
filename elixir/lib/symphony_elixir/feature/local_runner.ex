defmodule SymphonyElixir.Feature.LocalRunner do
  @moduledoc """
  Durable coordinator for the complete local FeatureRunner lifecycle.

  Role output is fenced and journaled before coordinator-owned Git work. A
  Developer can propose completion, but only this coordinator reads and stores
  the implementation SHA. Reviewers run from a separate worktree at that exact
  SHA, and their result must repeat the durable assignment identity.
  """

  alias SymphonyElixir.Feature.{Failure, Git, ProcessOwner, State, Store, TechnicalRetry, Validation}
  alias SymphonyElixir.FeatureRunner

  @default_max_reworks 2
  @default_max_steps 100
  @default_technical_retry_attempts 3
  @default_technical_retry_backoff_ms 1_000
  @default_role_execution_timeout_ms 300_000
  @default_validation_timeout_ms 300_000

  @type config :: %{
          required(:workspace) => Path.t(),
          required(:expected_branch) => String.t(),
          required(:reviewer_root) => Path.t(),
          required(:output_root) => Path.t(),
          required(:executor) => (map() -> map() | {:ok, map()} | {:error, term()}),
          required(:validator) => (map() -> :ok | {:ok, term()} | {:error, term()}),
          optional(:allowed_paths) => [Path.t()],
          optional(:protected_paths) => [Path.t()],
          optional(:max_reworks) => non_neg_integer(),
          optional(:max_final_reworks) => non_neg_integer(),
          optional(:max_steps) => pos_integer(),
          optional(:technical_retry_attempts) => pos_integer(),
          optional(:technical_retry_backoff_ms) => non_neg_integer(),
          optional(:now_ms) => (-> integer()),
          optional(:role_execution_timeout_ms) => pos_integer(),
          optional(:validation_timeout_ms) => pos_integer(),
          optional(:baseline_adoption) => :commit
        }

  @doc "Runs sequential local roles until the feature reaches an idle terminal or human-wait state."
  @spec run(Path.t(), String.t(), config()) :: {:ok, map()} | {:blocked, term()}
  def run(runtime, feature_id, config) do
    with {:ok, config} <- validate_config(config) do
      run_steps(runtime, feature_id, config, config.max_steps)
    end
  end

  @doc "Runs one durable local coordinator step."
  @spec step(Path.t(), String.t(), config()) :: {:ok, map()} | {:blocked, term()}
  def step(runtime, feature_id, config) do
    with {:ok, config} <- validate_config(config),
         :ok <- ensure_workspace_baseline(runtime, feature_id, config),
         :ok <- cleanup_applied_reviewers(runtime, feature_id) do
      state = FeatureRunner.get(runtime, feature_id)

      case advance_step(runtime, feature_id, state, config) do
        {:ok, state} -> finish_system_steps(runtime, feature_id, state, config)
        {:blocked, _} = blocked -> blocked
      end
    end
  end

  @doc "Returns a read-only, compact projection of a standalone feature journal."
  @spec status(Path.t(), String.t()) :: {:ok, map()} | {:blocked, term()}
  def status(runtime, feature_id) do
    Store.read(runtime, fn db ->
      state = Store.fetch(db, feature_id)

      attempt =
        case Store.execute(db, "SELECT attempt_id, execution_id, status FROM attempts WHERE feature_id = ? AND revision = ?", [feature_id, state["revision"]]) do
          [[attempt_id, execution_id, status]] -> %{attempt_id: attempt_id, execution_id: execution_id, status: status}
          [] -> %{attempt_id: nil, execution_id: nil, status: "none"}
        end

      retry =
        case Store.execute(db, "SELECT attempts, due_at_ms FROM technical_retries WHERE feature_id = ? AND status = 'pending' ORDER BY due_at_ms DESC LIMIT 1", [feature_id]) do
          [[count, due]] -> %{count: count, next_retry_at: due}
          [] -> %{count: 0, next_retry_at: nil}
        end

      status = state["status"] || %{}

      {:ok,
       %{
         feature_id: feature_id,
         revision: state["revision"],
         phase: state["phase"],
         operation: status["current_operation"],
         role: State.role(state),
         task_id: task_id(state),
         attempt_id: attempt.attempt_id,
         execution_id: attempt.execution_id,
         execution_status: attempt.status,
         session_id: status["codex_session_id"],
         sha: state["final_sha"] || state["head"],
         started_at: status["started_at"],
         last_event_at: status["last_event_at"],
         latest_event: status["latest_event"],
         blocker: state["validation_blocker"] || state["technical_blocker"] || state["error"],
         technical_retry_count: retry.count,
         next_retry_at: retry.next_retry_at
       }}
    end)
  rescue
    _ -> {:blocked, :feature_status_unavailable}
  end

  @doc "Explicitly releases a feature's durable workspace claim when no role is running."
  @spec release_workspace(Path.t(), String.t()) :: :ok | {:error, atom()}
  def release_workspace(runtime, feature_id) do
    Store.transaction(runtime, fn db ->
      case Store.execute(db, "SELECT feature_id FROM workspace_ownership WHERE feature_id = ?", [feature_id]) do
        [] ->
          {:error, :workspace_ownership_missing}

        [[^feature_id]] ->
          release_owned_workspace(db, feature_id)
      end
    end)
  end

  defp release_owned_workspace(db, feature_id) do
    if Store.execute(db, "SELECT 1 FROM attempts WHERE feature_id = ? AND status = 'running' LIMIT 1", [feature_id]) == [] do
      Store.execute(db, "DELETE FROM workspace_ownership WHERE feature_id = ?", [feature_id])
      :ok
    else
      {:error, :workspace_execution_active}
    end
  end

  defp advance_step(runtime, feature_id, state, config) do
    case system_step(runtime, feature_id, state, config) do
      {:ok, state} -> {:ok, state}
      {:blocked, _} = blocked -> blocked
      :not_applicable -> advance_role_step(runtime, feature_id, state, config)
    end
  end

  defp advance_role_step(runtime, feature_id, state, config) do
    case State.role(state) do
      nil -> {:ok, state}
      _role -> continue_step(runtime, feature_id, state, config)
    end
  end

  defp finish_system_steps(runtime, feature_id, state, config) do
    case system_step(runtime, feature_id, state, config) do
      {:ok, next} ->
        if next["revision"] != state["revision"], do: finish_system_steps(runtime, feature_id, next, config), else: {:ok, next}

      {:blocked, _} = blocked ->
        blocked

      :not_applicable ->
        {:ok, maybe_release_terminal_workspace(runtime, feature_id, state)}
    end
  end

  defp system_step(runtime, feature_id, %{"phase" => "Validating"} = state, config) do
    with %{"purpose" => purpose, "sha" => sha} <- state["validation_target"],
         {:ok, implementation} <- Git.implementation(runtime, feature_id, state["implementation_attempt_id"]),
         true <- implementation.sha == sha and state["head"] == sha,
         {:ok, evidence} <- run_validation(runtime, feature_id, state, implementation, purpose, config) do
      case validation_retry(runtime, feature_id, state, purpose, evidence, config) do
        :continue ->
          {:ok,
           FeatureRunner.apply_validation(
             runtime,
             feature_id,
             state["revision"],
             evidence,
             repair_budget(config)
           )}

        {:blocked, _} = blocked ->
          blocked

        :exhausted ->
          {:ok, validation_retry_exhausted(runtime, feature_id, state, evidence, config)}
      end
    else
      false -> {:ok, validation_blocked(runtime, feature_id, state, "candidate SHA is stale before validation", config)}
      {:blocked, reason} -> {:ok, validation_blocked(runtime, feature_id, state, inspect(reason), config)}
      _ -> {:ok, validation_blocked(runtime, feature_id, state, "invalid validation target", config)}
    end
  end

  defp system_step(runtime, feature_id, %{"phase" => "ReadinessCheck", "revision" => revision}, _config), do: {:ok, FeatureRunner.complete_readiness(runtime, feature_id, revision)}
  defp system_step(_runtime, _feature_id, _state, _config), do: :not_applicable

  defp run_validation(runtime, feature_id, state, implementation, purpose, config) do
    operation_key = validation_operation_key(state, purpose)
    key = "#{state["revision"]}:#{purpose}:#{TechnicalRetry.attempts(runtime, feature_id, operation_key) + 1}"
    checkout = Path.join([config.reviewer_root, "validation", validation_checkout_name(feature_id, key)])

    case Validation.run(runtime, feature_id, %{key: key, purpose: purpose, repository: implementation.repository, sha: state["head"]}, config.validator, checkout, config.validation_timeout_ms) do
      {:ok, evidence} ->
        {:ok, evidence}

      {:blocked, reason} ->
        {:ok, evidence} =
          Validation.record_blocked(runtime, feature_id, %{key: key, purpose: purpose, sha: state["head"]}, inspect(reason))

        {:ok, evidence}
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp validation_retry(runtime, feature_id, state, purpose, %{"status" => "blocked"} = evidence, config) do
    classification = evidence["failure_classification"] |> to_classification()

    if Failure.retryable?(classification) do
      key = validation_operation_key(state, purpose)

      if TechnicalRetry.ready?(runtime, feature_id, key, now_ms(config)) do
        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        case TechnicalRetry.schedule(
               runtime,
               feature_id,
               key,
               "validation",
               classification,
               evidence["diagnostic"],
               %{purpose: purpose, sha: state["head"]},
               config.technical_retry_attempts,
               config.technical_retry_backoff_ms,
               now_ms(config)
             ) do
          :retry -> {:blocked, {:technical_retry_scheduled, classification}}
          :exhausted -> :exhausted
        end
      else
        {:blocked, {:technical_retry_pending, :validation}}
      end
    else
      :continue
    end
  end

  defp validation_retry(_runtime, _feature_id, _state, _purpose, _evidence, _config), do: :continue

  defp validation_retry_exhausted(runtime, feature_id, state, evidence, config) do
    terminal = Map.put(evidence, "failure_classification", "retry_exhausted")
    FeatureRunner.apply_validation(runtime, feature_id, state["revision"], Map.put(terminal, "status", "blocked"), repair_budget(config))
  end

  defp validation_operation_key(state, purpose), do: "validation:#{state["revision"]}:#{purpose}:#{state["head"]}"
  defp to_classification(value) when is_binary(value), do: String.to_existing_atom(value)
  defp to_classification(_), do: :implementation_failure

  defp validation_blocked(runtime, feature_id, state, diagnostic, config) do
    target = state["validation_target"] || %{}
    purpose = target["purpose"] || "review"
    key = "#{state["revision"]}:#{purpose}"
    sha = target["sha"] || state["head"]

    {:ok, evidence} =
      Validation.record_blocked(runtime, feature_id, %{key: key, purpose: purpose, sha: sha}, diagnostic)

    FeatureRunner.apply_validation(runtime, feature_id, state["revision"], evidence, repair_budget(config))
  end

  defp validation_checkout_name(feature_id, key), do: :crypto.hash(:sha256, feature_id <> ":" <> key) |> Base.encode16(case: :lower)

  defp run_steps(_runtime, _feature_id, _config, 0), do: {:blocked, :local_flow_step_limit_exceeded}

  defp run_steps(runtime, feature_id, config, remaining) do
    before = FeatureRunner.get(runtime, feature_id)

    case step(runtime, feature_id, config) do
      {:ok, after_step} ->
        continue_run(runtime, feature_id, config, remaining, before, after_step)

      {:blocked, _} = blocked ->
        blocked
    end
  end

  defp continue_run(runtime, feature_id, config, remaining, before, after_step) do
    cond do
      after_step["revision"] == before["revision"] -> {:blocked, :local_flow_made_no_progress}
      system_phase?(after_step) -> run_steps(runtime, feature_id, config, remaining - 1)
      State.role(after_step) == nil -> {:ok, after_step}
      true -> run_steps(runtime, feature_id, config, remaining - 1)
    end
  end

  defp system_phase?(%{"phase" => phase}), do: phase in ["Validating", "ReadinessCheck"]

  defp continue_step(runtime, feature_id, state, config) do
    case durable_output(runtime, feature_id, state["revision"]) do
      {:ok, pending} ->
        apply_durable_output(runtime, feature_id, state, pending, config)

      :missing ->
        prepare_or_advance(runtime, feature_id, state, config)

      {:blocked, _} = blocked ->
        blocked
    end
  end

  defp prepare_or_advance(runtime, feature_id, state, config) do
    with :ok <- pre_role_workspace_check(runtime, feature_id, state, config) do
      case FeatureRunner.prepare(runtime, feature_id) do
        {:execute, execution} -> execute_role(runtime, feature_id, state, execution, config)
        {:captured, revision} -> {:ok, FeatureRunner.advance(runtime, feature_id, revision)}
        {:running, _execution} -> {:blocked, :role_execution_already_running}
        {:idle, idle} -> {:ok, idle}
      end
    end
  end

  # This check occurs before FeatureRunner.prepare creates an execution.  It
  # deliberately does not adopt a new HEAD: a changed branch tip is an
  # ownership/integrity fault, not an implicit baseline update.
  defp pre_role_workspace_check(runtime, feature_id, state, config) do
    if State.role(state) == "developer" do
      with :ok <- owned_workspace(runtime, feature_id, config.workspace, state["expected_head_sha"]),
           {:ok, facts} <- Git.workspace_state(config.workspace, config.expected_branch),
           true <- facts.sha == state["expected_head_sha"],
           true <- facts.dirty_paths == [],
           :ok <- no_unknown_workspace_execution(runtime, feature_id) do
        :ok
      else
        false -> {:blocked, :workspace_integrity_blocker}
        {:blocked, _} = blocked -> blocked
      end
    else
      :ok
    end
  end

  defp no_unknown_workspace_execution(runtime, feature_id) do
    Store.read(runtime, fn db ->
      case Store.execute(db, "SELECT feature_id FROM attempts WHERE status = 'running' AND feature_id != ? LIMIT 1", [feature_id]) do
        [] -> :ok
        _ -> {:blocked, :unknown_active_workspace_execution}
      end
    end)
  end

  defp ensure_workspace_baseline(runtime, feature_id, config) do
    state = FeatureRunner.get(runtime, feature_id)

    case state["initial_base_sha"] do
      sha when is_binary(sha) and sha != "" ->
        if terminal_phase?(state), do: :ok, else: owned_workspace(runtime, feature_id, config.workspace, state["expected_head_sha"])

      _ ->
        establish_workspace_baseline(runtime, feature_id, state, config)
    end
  end

  defp establish_workspace_baseline(runtime, feature_id, state, config) do
    with {:ok, facts} <- Git.workspace_state(config.workspace, config.expected_branch),
         {:ok, sha, adopted} <- baseline_sha(facts, config),
         :ok <- claim_workspace(runtime, feature_id, facts.workspace, config.expected_branch, sha, adopted) do
      save_baseline(runtime, feature_id, state, sha, adopted)
    end
  end

  defp baseline_sha(%{dirty_paths: []} = facts, _config), do: {:ok, facts.sha, false}
  defp baseline_sha(_facts, %{baseline_adoption: :commit} = config), do: Git.adopt_dirty_baseline(config.workspace, config.expected_branch) |> adoption_result()
  defp baseline_sha(_facts, _config), do: {:blocked, :dirty_workspace_requires_explicit_baseline_adoption}
  defp adoption_result({:ok, sha}), do: {:ok, sha, true}
  defp adoption_result({:blocked, _} = blocked), do: blocked

  defp save_baseline(runtime, feature_id, state, sha, adopted) do
    Store.transaction(runtime, fn db ->
      current = Store.fetch(db, feature_id)

      if current["revision"] == state["revision"] and is_nil(current["initial_base_sha"]) do
        # Baseline adoption establishes the pre-lifecycle invariant; it must
        # not consume a role-transition revision or invalidate a prepared
        # legacy attempt.
        adopted_state = State.adopt_baseline(current, sha, adopted) |> Map.delete("revision")
        Store.execute(db, "UPDATE features SET state_json = ? WHERE id = ? AND revision = ?", [Jason.encode!(adopted_state), feature_id, current["revision"]])
        :ok
      else
        :ok
      end
    end)
  end

  defp claim_workspace(runtime, feature_id, workspace, branch, sha, adopted) do
    Store.transaction(runtime, fn db ->
      case Store.execute(db, "SELECT feature_id, expected_branch, initial_base_sha FROM workspace_ownership WHERE workspace = ?", [workspace]) do
        [] ->
          Store.execute(db, "INSERT INTO workspace_ownership (workspace, feature_id, expected_branch, initial_base_sha, expected_head_sha, adopted, claimed_at_ms) VALUES (?, ?, ?, ?, ?, ?, ?)", [
            workspace,
            feature_id,
            branch,
            sha,
            sha,
            if(adopted, do: 1, else: 0),
            System.system_time(:millisecond)
          ])

          :ok

        [[^feature_id, ^branch, ^sha]] ->
          :ok

        [[_other_feature, _other_branch, _other_sha]] ->
          # A claim is durable for the whole feature lifecycle.  Absence of a
          # currently running role is not permission to transfer it; terminal
          # completion or explicit release deletes the claim first.
          {:blocked, :workspace_already_owned}
      end
    end)
  end

  defp maybe_release_terminal_workspace(runtime, feature_id, %{"phase" => "ReadyForHuman"} = state) do
    case release_workspace(runtime, feature_id) do
      :ok -> state
      {:error, :workspace_ownership_missing} -> state
      {:error, :workspace_execution_active} -> state
    end
  end

  defp maybe_release_terminal_workspace(_runtime, _feature_id, state), do: state

  defp terminal_phase?(%{"phase" => "ReadyForHuman"}), do: true
  defp terminal_phase?(_state), do: false

  defp owned_workspace(runtime, feature_id, workspace, expected_sha) do
    Store.read(runtime, fn db ->
      case Store.execute(db, "SELECT feature_id, expected_head_sha FROM workspace_ownership WHERE workspace = ?", [Path.expand(workspace)]) do
        [[^feature_id, ^expected_sha]] -> :ok
        [] -> {:blocked, :workspace_ownership_missing}
        _ -> {:blocked, :workspace_ownership_mismatch}
      end
    end)
  end

  defp sync_workspace_claim(runtime, feature_id, state) do
    case state["expected_head_sha"] do
      sha when is_binary(sha) and sha != "" ->
        Store.transaction(runtime, fn db ->
          Store.execute(db, "UPDATE workspace_ownership SET expected_head_sha = ? WHERE feature_id = ?", [sha, feature_id])
          :ok
        end)

      _ ->
        :ok
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  defp execute_role(runtime, feature_id, state, execution, config) do
    with {:ok, assignment} <- assignment(runtime, feature_id, state, execution, config) do
      mark_active_operation(runtime, feature_id, state, assignment)

      case invoke(config.executor, assignment, config.role_execution_timeout_ms) do
        {:technical, diagnostic} ->
          _ = ProcessOwner.cancel(runtime, execution.execution_id)
          technical_failure(runtime, feature_id, %{execution: execution}, :role_execution, :transient_infrastructure, diagnostic, %{role: assignment.role}, config)

        {:ok, envelope} ->
          # credo:disable-for-next-line Credo.Check.Refactor.Nesting
          with {:ok, envelope} <- validate_or_fail_envelope(envelope, assignment),
               :ok <- persist_output(runtime, feature_id, execution, assignment, envelope),
               {:ok, pending} <- durable_output(runtime, feature_id, state["revision"]) do
            apply_durable_output(runtime, feature_id, state, pending, config)
          end
      end
    end
  end

  defp mark_active_operation(runtime, feature_id, state, assignment) do
    Store.transaction(runtime, fn db ->
      current = Store.fetch(db, feature_id)

      if current["revision"] == state["revision"] do
        updated =
          State.put_status(current, %{
            "active_role" => assignment.role,
            "attempt_id" => assignment.attempt_id,
            "execution_id" => assignment.execution_id,
            "current_operation" => "role_execution",
            "last_event_at" => now_ms(%{now_ms: nil}),
            "latest_event" => "#{assignment.role} execution started"
          })
          |> Map.delete("revision")

        Store.execute(db, "UPDATE features SET state_json = ? WHERE id = ? AND revision = ?", [Jason.encode!(updated), feature_id, current["revision"]])
      end
    end)
  end

  defp assignment(runtime, feature_id, state, execution, config) do
    role = execution.state_role
    task_id = task_id(state)
    # attempt_id identifies the logical role work; execution_id identifies one
    # concrete process.  Never let a replacement process consume or overwrite
    # a predecessor's spool/result files.
    output = Path.join([config.output_root, execution.attempt_id, execution.execution_id])
    File.mkdir_p!(output)

    base = %{
      attempt_id: execution.attempt_id,
      execution_id: execution.execution_id,
      execution: execution,
      feature_id: feature_id,
      input: execution.input,
      output_dir: output,
      phase: state["phase"],
      role: role,
      runtime: runtime,
      task_id: task_id,
      workspace: config.workspace
    }

    if role == "reviewer" do
      reviewer_assignment(runtime, state, execution, task_id, base, config)
    else
      {:ok, base}
    end
  end

  defp reviewer_assignment(runtime, state, execution, task_id, base, config) do
    implementation_attempt_id = state["implementation_attempt_id"]
    checkout = Path.join(config.reviewer_root, execution.attempt_id)

    context = %{
      feature_id: execution.feature_id,
      task_id: task_id,
      attempt_id: execution.attempt_id,
      execution_id: execution.execution_id,
      implementation_attempt_id: implementation_attempt_id,
      checkout_path: checkout
    }

    with true <- is_binary(implementation_attempt_id),
         true <- passed_validation?(state),
         {:ok, review} <- Git.prepare_reviewer_checkout(runtime, context),
         true <- review.reviewed_sha == state["head"] do
      {:ok,
       Map.merge(base, %{
         developer_workspace: config.workspace,
         implementation_attempt_id: implementation_attempt_id,
         reviewed_sha: review.reviewed_sha,
         workspace: checkout
       })}
    else
      false -> {:blocked, :review_assignment_requires_passed_validation}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp invoke(executor, assignment, timeout_ms) do
    case bounded_call(fn -> executor.(assignment) end, timeout_ms) do
      {:ok, {:ok, envelope}} -> {:ok, envelope}
      {:ok, {:error, {:transient_infrastructure, reason}}} -> {:technical, "role execution failed: #{inspect(reason)}"}
      {:ok, {:error, reason}} -> {:ok, failure_envelope(assignment, "role execution failed: #{inspect(reason)}")}
      {:ok, envelope} -> {:ok, envelope}
      {:error, reason} -> {:ok, failure_envelope(assignment, "role execution raised: #{inspect(reason)}")}
      :timeout -> {:technical, "role execution timeout after #{timeout_ms}ms"}
    end
  end

  defp bounded_call(fun, timeout_ms) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(caller, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :timeout
        after
          1_000 -> :timeout
        end
    end
  end

  defp validate_or_fail_envelope(envelope, assignment) do
    if valid_envelope?(envelope, assignment) do
      {:ok, envelope}
    else
      {:ok, failure_envelope(assignment, "invalid or stale role execution result")}
    end
  end

  defp valid_envelope?(envelope, assignment) when is_map(envelope) do
    envelope["role"] == assignment.role and envelope["task_id"] == assignment.task_id and
      envelope["attempt_id"] == assignment.attempt_id and envelope["execution_id"] == assignment.execution_id and
      is_map(envelope["result"]) and
      (assignment.role != "reviewer" or envelope["reviewed_sha"] == assignment.reviewed_sha) and json_encodable?(envelope)
  end

  defp valid_envelope?(_envelope, _assignment), do: false

  defp json_encodable?(value), do: match?({:ok, _json}, Jason.encode(value))

  defp failure_envelope(assignment, reason) do
    %{
      "attempt_id" => assignment.attempt_id,
      "execution_id" => assignment.execution_id,
      "result" => %{"reason" => reason, "status" => "failed"},
      "role" => assignment.role,
      "task_id" => assignment.task_id
    }
    |> maybe_put_reviewed_sha(assignment)
  end

  defp maybe_put_reviewed_sha(envelope, %{role: "reviewer", reviewed_sha: sha}),
    do: Map.put(envelope, "reviewed_sha", sha)

  defp maybe_put_reviewed_sha(envelope, _assignment), do: envelope

  defp persist_output(runtime, feature_id, execution, assignment, envelope) do
    Store.transaction(runtime, fn db ->
      [[attempt_id, execution_id, status]] =
        Store.execute(
          db,
          "SELECT attempt_id, execution_id, status FROM attempts WHERE feature_id = ? AND revision = ?",
          [feature_id, execution.revision]
        )

      if attempt_id != execution.attempt_id or execution_id != execution.execution_id or status != "running" do
        raise ArgumentError, "stale local role output"
      end

      json = Jason.encode!(envelope)

      persist_session_id(db, feature_id, execution.revision, envelope["codex_session_id"])

      case Store.execute(
             db,
             "SELECT attempt_id, execution_id, role, task_id, result_json FROM local_role_outputs WHERE feature_id = ? AND revision = ?",
             [feature_id, execution.revision]
           ) do
        [] ->
          Store.execute(
            db,
            "INSERT INTO local_role_outputs (feature_id, revision, attempt_id, execution_id, role, task_id, result_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [feature_id, execution.revision, execution.attempt_id, execution.execution_id, assignment.role, assignment.task_id, json]
          )

          :ok

        [[^attempt_id, ^execution_id, role, task_id, ^json]]
        when role == assignment.role and task_id == assignment.task_id ->
          :ok

        _ ->
          raise ArgumentError, "local role output already bound"
      end
    end)
  end

  defp persist_session_id(_db, _feature_id, _revision, session_id) when not is_binary(session_id) or session_id == "", do: :ok

  defp persist_session_id(db, feature_id, revision, session_id) do
    current = Store.fetch(db, feature_id)

    updated =
      State.put_status(current, %{"codex_session_id" => session_id})
      |> Map.delete("revision")

    Store.execute(db, "UPDATE features SET state_json = ? WHERE id = ? AND revision = ?", [Jason.encode!(updated), feature_id, revision])
    :ok
  end

  defp durable_output(runtime, feature_id, revision) do
    Store.read(runtime, fn db ->
      sql =
        "SELECT a.status, a.attempt_id, a.execution_id, a.execution_owner, a.input_json, " <>
          "l.attempt_id, l.execution_id, l.role, l.task_id, l.result_json " <>
          "FROM attempts a JOIN local_role_outputs l ON l.feature_id = a.feature_id AND l.revision = a.revision " <>
          "WHERE a.feature_id = ? AND a.revision = ?"

      case Store.execute(
             db,
             sql,
             [feature_id, revision]
           ) do
        [[status, attempt_id, execution_id, owner, input_json, attempt_id, execution_id, role, task_id, result_json]] ->
          {:ok,
           %{
             envelope: Jason.decode!(result_json),
             execution: %{
               attempt_id: attempt_id,
               execution_id: execution_id,
               feature_id: feature_id,
               input: Jason.decode!(input_json),
               owner_token: owner,
               revision: revision,
               state_role: role
             },
             status: status,
             task_id: task_id
           }}

        [_mismatched_row] ->
          {:blocked, :durable_role_output_identity_mismatch}

        [] ->
          :missing
      end
    end)
  end

  defp apply_durable_output(runtime, feature_id, _state, %{status: "recorded"} = pending, _config) do
    advanced = FeatureRunner.advance(runtime, feature_id, pending.execution.revision)
    sync_workspace_claim(runtime, feature_id, advanced)
    with :ok <- cleanup_if_reviewer(runtime, feature_id, pending), do: {:ok, advanced}
  end

  defp apply_durable_output(runtime, feature_id, state, %{status: "running"} = pending, config) do
    case coordinator_result(runtime, state, pending, config) do
      {:ok, result} ->
        complete_operation(runtime, feature_id, pending, state)
        {:captured, revision} = FeatureRunner.record(runtime, feature_id, pending.execution, result)
        advanced = FeatureRunner.advance(runtime, feature_id, revision)
        sync_workspace_claim(runtime, feature_id, advanced)
        with :ok <- cleanup_if_reviewer(runtime, feature_id, pending), do: {:ok, advanced}

      {:retry, operation, classification, diagnostic, target} ->
        technical_failure(runtime, feature_id, pending, operation, classification, diagnostic, target, config)

      {:terminal, diagnostic} ->
        {:captured, revision} = FeatureRunner.record(runtime, feature_id, pending.execution, failed(diagnostic))
        {:ok, FeatureRunner.advance(runtime, feature_id, revision)}
    end
  end

  defp coordinator_result(runtime, state, pending, config) do
    result = pending.envelope["result"]

    case pending.execution.state_role do
      "developer" -> developer_result(runtime, state, pending, result, config)
      "reviewer" -> reviewer_result(runtime, state, pending, result, config)
      _role -> {:ok, valid_state_result(result, state)}
    end
  end

  defp developer_result(runtime, state, pending, %{"status" => "completed"} = result, config) do
    if Map.has_key?(result, "sha") do
      {:ok, failed("Developer output attempted to control the authoritative SHA")}
    else
      case Git.implementation(runtime, pending.execution.feature_id, pending.execution.attempt_id) do
        {:ok, implementation} when implementation.execution_id == pending.execution.execution_id ->
          captured_developer_result(result, state, pending, implementation)

        {:blocked, :implementation_not_captured} ->
          capture_developer_result(runtime, state, pending, result, config)

        _ ->
          {:terminal, "implementation attempt is bound to another execution"}
      end
    end
  end

  defp developer_result(_runtime, state, _pending, result, _config), do: {:ok, valid_state_result(result, state)}

  defp captured_developer_result(result, state, pending, implementation) do
    result
    |> Map.put("sha", implementation.sha)
    |> Map.put("implementation_attempt_id", implementation.attempt_id)
    |> Map.put("implementation_execution_id", implementation.execution_id)
    |> Map.put("resolutions", repair_resolutions(state, pending.task_id, implementation.sha, pending.execution))
    |> valid_state_result(state)
    |> then(&{:ok, &1})
  end

  defp capture_developer_result(runtime, state, pending, result, config) do
    context =
      %{
        attempt_id: pending.execution.attempt_id,
        execution_id: pending.execution.execution_id,
        expected_branch: config.expected_branch,
        expected_head_sha: state["expected_head_sha"],
        feature_id: pending.execution.feature_id,
        task_id: pending.task_id,
        workspace: config.workspace
      }
      |> put_scope_config(config)

    case Git.capture_implementation(runtime, context) do
      {:ok, implementation} ->
        captured_developer_result(result, state, pending, implementation)

      {:blocked, reason} ->
        classification = Failure.classify(:capture, reason)

        # credo:disable-for-next-line Credo.Check.Refactor.Nesting
        if Failure.retryable?(classification),
          do:
            {:retry, :capture, classification, inspect(reason),
             %{
               attempt_id: pending.execution.attempt_id,
               execution_id: pending.execution.execution_id,
               sha: state["head"]
             }},
          else: {:terminal, "implementation capture blocked: #{inspect(reason)}"}
    end
  end

  defp reviewer_result(runtime, state, pending, result, config) do
    identity =
      pending.envelope
      |> Map.take(["attempt_id", "execution_id", "reviewed_sha", "role", "task_id"])
      |> Map.put("feature_id", pending.execution.feature_id)

    with {:ok, assignment} <- Git.validate_reviewer_result(runtime, identity),
         true <- assignment.reviewed_sha == state["head"],
         true <- assignment.implementation_attempt_id == state["implementation_attempt_id"] do
      result
      |> Map.put("repair_budget", repair_budget(config))
      |> review_state_result(state, pending)
      |> then(&{:ok, &1})
    else
      false -> {:terminal, "review result is stale for the current implementation"}
      {:blocked, reason} -> {:terminal, "review result rejected: #{inspect(reason)}"}
    end
  end

  defp review_state_result(result, state, pending) do
    result =
      result
      |> Map.put("sha", pending.envelope["reviewed_sha"])
      |> Map.put("review_attempt_id", pending.execution.attempt_id)
      |> Map.put("review_execution_id", pending.execution.execution_id)

    valid_state_result(result, state)
  end

  defp valid_state_result(result, state) do
    if State.valid_result?(state, result), do: result, else: failed("invalid role result for #{state["phase"]}")
  end

  defp failed(reason), do: %{"reason" => reason, "status" => "failed"}

  defp technical_failure(runtime, feature_id, pending, operation, classification, diagnostic, target, config) do
    key = operation_key(operation, pending, target)

    if TechnicalRetry.ready?(runtime, feature_id, key, now_ms(config)) do
      case TechnicalRetry.schedule(
             runtime,
             feature_id,
             key,
             Atom.to_string(operation),
             classification,
             diagnostic,
             target,
             config.technical_retry_attempts,
             config.technical_retry_backoff_ms,
             now_ms(config)
           ) do
        :retry ->
          {:blocked, {:technical_retry_scheduled, classification}}

        :exhausted ->
          {:captured, revision} = FeatureRunner.record(runtime, feature_id, pending.execution, failed("technical retry exhausted: #{diagnostic}"))
          {:ok, FeatureRunner.advance(runtime, feature_id, revision)}
      end
    else
      {:blocked, {:technical_retry_pending, operation}}
    end
  end

  defp operation_key(operation, pending, target), do: "#{operation}:#{pending.execution.attempt_id}:#{pending.execution.execution_id}:#{Map.get(target, :sha, "")}"
  defp complete_operation(runtime, feature_id, pending, state), do: TechnicalRetry.complete(runtime, feature_id, operation_key(:capture, pending, %{sha: state["head"]}))
  defp now_ms(config), do: if(is_function(config.now_ms, 0), do: config.now_ms.(), else: System.system_time(:millisecond))

  defp passed_validation?(state), do: is_map(state["validation"]) and state["validation"]["status"] == "passed" and state["validation"]["sha"] == state["head"]

  defp cleanup_if_reviewer(runtime, feature_id, %{execution: %{state_role: "reviewer", attempt_id: attempt_id}}),
    do: Git.remove_reviewer_checkout(runtime, feature_id, attempt_id)

  defp cleanup_if_reviewer(_runtime, _feature_id, _pending), do: :ok

  defp cleanup_applied_reviewers(runtime, feature_id) do
    attempts =
      Store.read(runtime, fn db ->
        Store.execute(
          db,
          "SELECT r.attempt_id FROM reviewer_checkouts r JOIN attempts a ON a.attempt_id = r.attempt_id WHERE r.feature_id = ? AND a.status = 'applied'",
          [feature_id]
        )
      end)

    Enum.reduce_while(attempts, :ok, fn [attempt_id], :ok ->
      case Git.remove_reviewer_checkout(runtime, feature_id, attempt_id) do
        :ok -> {:cont, :ok}
        {:blocked, _} = blocked -> {:halt, blocked}
      end
    end)
  end

  defp task_id(%{"phase" => "Planning"}), do: "planning"

  defp task_id(state) do
    case Enum.at(state["tasks"], state["current"]) do
      %{"id" => id} -> id
      _ -> "planning"
    end
  end

  defp validate_config(config) when is_map(config) do
    config =
      Map.merge(
        %{
          max_reworks: @default_max_reworks,
          max_final_reworks: @default_max_reworks,
          max_steps: @default_max_steps,
          technical_retry_attempts: @default_technical_retry_attempts,
          technical_retry_backoff_ms: @default_technical_retry_backoff_ms,
          now_ms: nil,
          role_execution_timeout_ms: @default_role_execution_timeout_ms,
          validation_timeout_ms: @default_validation_timeout_ms,
          baseline_adoption: nil
        },
        config
      )
      |> Map.update(:protected_paths, Git.default_protected_paths(), &((Git.default_protected_paths() ++ &1) |> Enum.uniq()))

    if valid_config?(config) do
      File.mkdir_p!(config.reviewer_root)
      File.mkdir_p!(config.output_root)
      {:ok, config}
    else
      {:blocked, :invalid_local_runner_config}
    end
  end

  defp validate_config(_config), do: {:blocked, :invalid_local_runner_config}

  defp valid_config?(config) do
    names = [:workspace, :reviewer_root, :output_root]

    valid_paths?(config, names) and
      valid_callbacks?(config) and
      valid_path_patterns?(config, :allowed_paths) and
      valid_path_patterns?(config, :protected_paths) and
      valid_limits?(config) and
      valid_baseline_adoption?(config) and
      isolated_roots?(config, names)
  end

  defp valid_paths?(config, names) do
    Enum.all?(names, &(is_binary(config[&1]) and config[&1] != "")) and File.dir?(config.workspace) and
      is_binary(config[:expected_branch]) and config[:expected_branch] != ""
  end

  defp valid_callbacks?(config), do: is_function(config[:executor], 1) and is_function(config[:validator], 1)
  defp valid_baseline_adoption?(%{baseline_adoption: nil}), do: true
  defp valid_baseline_adoption?(%{baseline_adoption: :commit}), do: true
  defp valid_baseline_adoption?(_), do: false

  defp valid_path_patterns?(config, key) do
    not Map.has_key?(config, key) or
      (is_list(config[key]) and Enum.all?(config[key], &(is_binary(&1) and &1 != "" and Path.type(&1) != :absolute and not String.starts_with?(&1, "../"))))
  end

  defp put_scope_config(context, config) do
    context
    |> Map.put(:protected_paths, config.protected_paths)
    |> then(fn context -> if Map.has_key?(config, :allowed_paths), do: Map.put(context, :allowed_paths, config.allowed_paths), else: context end)
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp valid_limits?(config) do
    is_integer(config.max_reworks) and config.max_reworks >= 0 and
      is_integer(config.max_final_reworks) and config.max_final_reworks >= 0 and
      is_integer(config.max_steps) and config.max_steps > 0 and
      is_integer(config.technical_retry_attempts) and config.technical_retry_attempts > 0 and
      is_integer(config.technical_retry_backoff_ms) and config.technical_retry_backoff_ms >= 0 and
      is_integer(config.role_execution_timeout_ms) and config.role_execution_timeout_ms > 0 and
      is_integer(config.validation_timeout_ms) and config.validation_timeout_ms > 0 and
      (is_nil(config.now_ms) or is_function(config.now_ms, 0))
  end

  defp isolated_roots?(config, names) do
    roots = Enum.map(names, &(config[&1] |> Path.expand() |> String.trim_trailing("/")))

    roots
    |> Enum.with_index()
    |> Enum.all?(fn {root, index} ->
      roots
      |> Enum.with_index()
      |> Enum.all?(fn {other, other_index} ->
        index == other_index or separate_roots?(root, other)
      end)
    end)
  end

  defp separate_roots?(left, right) do
    left != right and not String.starts_with?(left, right <> "/") and not String.starts_with?(right, left <> "/")
  end

  defp repair_budget(config), do: %{"task" => config.max_reworks, "final" => config.max_final_reworks}

  # Coordinator-owned candidate evidence is bound to the captured SHA and the
  # developer execution that produced it. State decides which later approval
  # or successful validation is allowed to close each finding.
  defp repair_resolutions(state, task_id, sha, execution) do
    state["findings"]
    |> Kernel.||([])
    |> Enum.filter(&(&1["status"] == "open" and &1["affected_task_id"] == task_id))
    |> Enum.reject(&(&1["source_sha"] == sha))
    |> Enum.map(fn finding ->
      %{
        "finding_id" => finding["finding_id"],
        "resolution_evidence" => %{"implementation_attempt_id" => execution.attempt_id, "implementation_execution_id" => execution.execution_id, "candidate_sha" => sha}
      }
    end)
  end
end
