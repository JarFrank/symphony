defmodule SymphonyElixir.Feature.LocalRunner do
  @moduledoc """
  Durable coordinator for the complete local FeatureRunner lifecycle.

  Role output is fenced and journaled before coordinator-owned Git work. A
  Developer can propose completion, but only this coordinator reads and stores
  the implementation SHA. Reviewers run from a separate worktree at that exact
  SHA, and their result must repeat the durable assignment identity.
  """

  alias SymphonyElixir.Feature.{Git, State, Store}
  alias SymphonyElixir.FeatureRunner

  @default_max_reworks 2
  @default_max_steps 100

  @type config :: %{
          required(:workspace) => Path.t(),
          required(:expected_branch) => String.t(),
          required(:reviewer_root) => Path.t(),
          required(:output_root) => Path.t(),
          required(:executor) => (map() -> map() | {:ok, map()} | {:error, term()}),
          required(:validator) => (map() -> :ok | {:ok, term()} | {:error, term()}),
          optional(:allowed_paths) => [Path.t()],
          optional(:max_reworks) => non_neg_integer(),
          optional(:max_steps) => pos_integer()
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
         :ok <- cleanup_applied_reviewers(runtime, feature_id) do
      state = FeatureRunner.get(runtime, feature_id)

      case State.role(state) do
        nil -> {:ok, state}
        _role -> continue_step(runtime, feature_id, state, config)
      end
    end
  end

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
      State.role(after_step) == nil -> {:ok, after_step}
      after_step["revision"] == before["revision"] -> {:blocked, :local_flow_made_no_progress}
      true -> run_steps(runtime, feature_id, config, remaining - 1)
    end
  end

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
    case FeatureRunner.prepare(runtime, feature_id) do
      {:execute, execution} -> execute_role(runtime, feature_id, state, execution, config)
      {:captured, revision} -> {:ok, FeatureRunner.advance(runtime, feature_id, revision)}
      {:running, _execution} -> {:blocked, :role_execution_already_running}
      {:idle, idle} -> {:ok, idle}
    end
  end

  defp execute_role(runtime, feature_id, state, execution, config) do
    with {:ok, assignment} <- assignment(runtime, feature_id, state, execution, config),
         envelope <- invoke(config.executor, assignment),
         {:ok, envelope} <- validate_or_fail_envelope(envelope, assignment),
         :ok <- persist_output(runtime, feature_id, execution, assignment, envelope),
         {:ok, pending} <- durable_output(runtime, feature_id, state["revision"]) do
      apply_durable_output(runtime, feature_id, state, pending, config)
    end
  end

  defp assignment(runtime, feature_id, state, execution, config) do
    role = execution.state_role
    task_id = task_id(state)
    output = Path.join(config.output_root, execution.attempt_id)
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
      false -> {:blocked, :review_assignment_is_not_current_implementation}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp invoke(executor, assignment) do
    case executor.(assignment) do
      {:ok, envelope} -> envelope
      {:error, reason} -> failure_envelope(assignment, "role execution failed: #{inspect(reason)}")
      envelope -> envelope
    end
  rescue
    error -> failure_envelope(assignment, "role execution raised: #{Exception.message(error)}")
  catch
    kind, reason -> failure_envelope(assignment, "role execution #{kind}: #{inspect(reason)}")
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
    with :ok <- cleanup_if_reviewer(runtime, feature_id, pending), do: {:ok, advanced}
  end

  defp apply_durable_output(runtime, feature_id, state, %{status: "running"} = pending, config) do
    result = coordinator_result(runtime, state, pending, config)
    {:captured, revision} = FeatureRunner.record(runtime, feature_id, pending.execution, result)
    advanced = FeatureRunner.advance(runtime, feature_id, revision)
    with :ok <- cleanup_if_reviewer(runtime, feature_id, pending), do: {:ok, advanced}
  end

  defp coordinator_result(runtime, state, pending, config) do
    result = pending.envelope["result"]

    case pending.execution.state_role do
      "developer" -> developer_result(runtime, state, pending, result, config)
      "reviewer" -> reviewer_result(runtime, state, pending, result, config)
      _role -> valid_state_result(result, state)
    end
  end

  defp developer_result(runtime, state, pending, %{"status" => "completed"} = result, config) do
    if Map.has_key?(result, "sha") do
      failed("Developer output attempted to control the authoritative SHA")
    else
      context = %{
        allowed_paths: config.allowed_paths,
        attempt_id: pending.execution.attempt_id,
        execution_id: pending.execution.execution_id,
        expected_branch: config.expected_branch,
        feature_id: pending.execution.feature_id,
        task_id: pending.task_id,
        workspace: config.workspace
      }

      case Git.capture_implementation(runtime, context) do
        {:ok, implementation} ->
          result
          |> Map.put("sha", implementation.sha)
          |> Map.put("implementation_attempt_id", implementation.attempt_id)
          |> Map.put("implementation_execution_id", implementation.execution_id)
          |> valid_state_result(state)

        {:blocked, reason} ->
          failed("implementation capture blocked: #{inspect(reason)}")
      end
    end
  end

  defp developer_result(_runtime, state, _pending, result, _config), do: valid_state_result(result, state)

  defp reviewer_result(runtime, state, pending, result, config) do
    identity =
      pending.envelope
      |> Map.take(["attempt_id", "execution_id", "reviewed_sha", "role", "task_id"])
      |> Map.put("feature_id", pending.execution.feature_id)

    with {:ok, assignment} <- Git.validate_reviewer_result(runtime, identity),
         true <- assignment.reviewed_sha == state["head"],
         true <- assignment.implementation_attempt_id == state["implementation_attempt_id"] do
      result
      |> enforce_rework_limit(state, config.max_reworks)
      |> validate_final_acceptance(runtime, state, pending, config)
      |> review_state_result(state, pending)
    else
      false -> failed("review result is stale for the current implementation")
      {:blocked, reason} -> failed("review result rejected: #{inspect(reason)}")
    end
  end

  defp enforce_rework_limit(%{"status" => "changes_requested"} = result, state, max_reworks) do
    task = Enum.at(state["tasks"], state["current"])

    if task["rework_count"] >= max_reworks,
      do: failed("rework limit exceeded for task #{task["id"]}"),
      else: result
  end

  defp enforce_rework_limit(result, _state, _max_reworks), do: result

  defp validate_final_acceptance(%{"status" => "approved"} = result, runtime, %{"phase" => "FinalReview"} = state, pending, config) do
    context = %{
      allowed_paths: [],
      attempt_id: state["implementation_attempt_id"],
      execution_id: state["implementation_execution_id"],
      expected_branch: config.expected_branch,
      feature_id: pending.execution.feature_id,
      task_id: pending.task_id,
      workspace: config.workspace
    }

    with {:ok, implementation} <- Git.capture_implementation(runtime, context),
         true <- implementation.sha == state["head"],
         {:ok, evidence} <- validate(config.validator, Map.merge(context, %{sha: implementation.sha})) do
      Map.put(result, "validation", %{"evidence" => evidence, "status" => "passed"})
    else
      false -> failed("final implementation SHA changed before validation")
      {:blocked, reason} -> failed("final implementation validation blocked: #{inspect(reason)}")
      {:error, reason} -> failed("final implementation validation failed: #{inspect(reason)}")
    end
  end

  defp validate_final_acceptance(result, _runtime, _state, _pending, _config), do: result

  defp validate(validator, context) do
    case validator.(context) do
      :ok -> {:ok, "coordinator validator passed"}
      {:ok, evidence} -> {:ok, evidence}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_validator_result, other}}
    end
  rescue
    error -> {:error, {:validator_raised, Exception.message(error)}}
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
          allowed_paths: [],
          max_reworks: @default_max_reworks,
          max_steps: @default_max_steps
        },
        config
      )

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
      valid_allowed_paths?(config) and
      valid_limits?(config) and
      isolated_roots?(config, names)
  end

  defp valid_paths?(config, names) do
    Enum.all?(names, &(is_binary(config[&1]) and config[&1] != "")) and File.dir?(config.workspace) and
      is_binary(config[:expected_branch]) and config[:expected_branch] != ""
  end

  defp valid_callbacks?(config), do: is_function(config[:executor], 1) and is_function(config[:validator], 1)

  defp valid_allowed_paths?(config) do
    is_list(config.allowed_paths) and Enum.all?(config.allowed_paths, &(is_binary(&1) and &1 != ""))
  end

  defp valid_limits?(config) do
    is_integer(config.max_reworks) and config.max_reworks >= 0 and is_integer(config.max_steps) and config.max_steps > 0
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
end
