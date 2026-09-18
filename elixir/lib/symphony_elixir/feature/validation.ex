defmodule SymphonyElixir.Feature.Validation do
  @moduledoc "Runs and journals executable validation for one immutable Git tree."

  alias SymphonyElixir.Feature.{Effects, Failure, Git, ProcessOwner, Sandbox, Store}

  @diagnostic_limit 4_096

  @spec run(Path.t(), String.t(), map(), (map() -> term()), Path.t(), pos_integer()) ::
          {:ok, map()} | {:blocked, term()}
  def run(runtime, feature_id, target, validator, checkout_path, timeout_ms \\ 300_000) do
    run(runtime, feature_id, target, validator, checkout_path, timeout_ms, %{})
  end

  @doc "Runs a validation command under durable ProcessOwner ownership when given an executable map."
  @spec run(Path.t(), String.t(), map(), (map() -> term()) | map(), Path.t(), pos_integer(), map()) ::
          {:ok, map()} | {:blocked, term()}
  def run(runtime, feature_id, target, validator, checkout_path, timeout_ms, options) when is_map(options) do
    with {:ok, target} <- valid_target(target),
         :missing <- evidence(runtime, feature_id, target.key),
         {:ok, identity} <- Git.candidate_identity(target.repository, target.sha),
         :ok <- ensure_expected_tree(target, identity),
         {:ok, checkout} <-
           prepare_or_reconcile_checkout(runtime, feature_id, target, identity, checkout_path, options) do
      {evidence, cleanup?} = execute(runtime, feature_id, validator, target, identity, checkout, timeout_ms, options)
      if cleanup?, do: cleanup_checkout(runtime, feature_id, target, options, target.repository, checkout)
      persist(runtime, feature_id, target.key, target.purpose, evidence)
    else
      {:ok, evidence} -> {:ok, evidence}
      {:blocked, _} = blocked -> blocked
    end
  end

  @spec evidence(Path.t(), String.t(), String.t()) :: :missing | {:ok, map()}
  def evidence(runtime, feature_id, key) do
    Store.read(runtime, fn db ->
      case Store.execute(db, "SELECT evidence_json FROM validation_evidence WHERE feature_id = ? AND validation_key = ?", [feature_id, key]) do
        [[json]] -> {:ok, Jason.decode!(json)}
        [] -> :missing
      end
    end)
  end

  @doc "Recovers every nonterminated validation process for one feature before a new validation can start."
  @spec recover(Path.t(), String.t()) :: :ok | {:blocked, term()}
  def recover(runtime, feature_id) do
    runtime
    |> ProcessOwner.current()
    |> Enum.filter(&(&1.feature_id == feature_id and &1.execution_kind == "validation"))
    |> Enum.reduce_while(:ok, fn execution, :ok ->
      case ProcessOwner.recover_execution(runtime, execution.execution_id) do
        :ok -> {:cont, :ok}
        {:blocked, reason} -> {:halt, {:blocked, {:validation_recovery_unconfirmed, execution.execution_id, reason}}}
      end
    end)
  end

  @doc "Persists a blocked outcome when an immutable checkout cannot be prepared."
  @spec record_blocked(Path.t(), String.t(), map(), String.t()) :: {:ok, map()}
  def record_blocked(runtime, feature_id, target, diagnostic) do
    evidence = %{
      "command" => "configured validator",
      "diagnostic" => bounded(diagnostic),
      "ended_at" => timestamp(),
      "exit_status" => nil,
      "sha" => target.sha,
      "started_at" => timestamp(),
      "status" => "blocked",
      "tree" => target[:tree] || "unavailable",
      "working_directory" => "unavailable"
    }

    case evidence(runtime, feature_id, target.key) do
      {:ok, existing} -> {:ok, existing}
      :missing -> persist(runtime, feature_id, target.key, target.purpose, evidence)
    end
  end

  defp valid_target(target) when is_map(target) do
    required = [:key, :purpose, :repository, :sha]

    if Enum.all?(required, &(is_binary(target[&1]) and target[&1] != "")), do: {:ok, target}, else: {:blocked, :invalid_validation_target}
  end

  defp valid_target(_), do: {:blocked, :invalid_validation_target}

  defp ensure_expected_tree(target, identity) do
    if is_nil(target[:tree]) or target.tree == identity.tree, do: :ok, else: {:blocked, :stale_validation_tree}
  end

  # The intent is the only authority for reusing an extant path.  A new run
  # checks absence before writing it, while a restart can reconcile only the
  # same feature/operation/SHA/tree/path tuple.
  defp prepare_or_reconcile_checkout(runtime, feature_id, target, identity, checkout_path, options) do
    key = validation_checkout_effect_key(options, target)
    intent = validation_checkout_intent(feature_id, target, identity, checkout_path, key)

    with :ok <- ensure_checkout_intent(runtime, feature_id, key, intent, target.repository, checkout_path),
         result <- Git.reconcile_validation_checkout(target.repository, identity.sha, identity.tree, checkout_path),
         {:ok, checkout} <- create_or_reuse_checkout(result, target.repository, identity.sha, checkout_path),
         :ok <- Effects.complete(runtime, feature_id, key, %{"checkout_path" => Path.expand(checkout), "sha" => identity.sha, "tree" => identity.tree}) do
      {:ok, checkout}
    end
  end

  defp ensure_checkout_intent(runtime, feature_id, key, intent, repository, checkout_path) do
    case Effects.fetch(runtime, feature_id, key) do
      :missing ->
        with :ok <- Git.validation_checkout_path_available(repository, checkout_path) do
          Effects.intent(runtime, feature_id, key, intent)
        end

      {_status, existing, _result} when existing == intent ->
        :ok

      _ ->
        {:blocked, :validation_checkout_ownership_mismatch}
    end
  end

  defp create_or_reuse_checkout(:missing, repository, sha, checkout_path) do
    with :ok <- File.mkdir_p(Path.dirname(checkout_path)) do
      Git.prepare_validation_checkout(repository, sha, checkout_path)
    end
  end

  defp create_or_reuse_checkout({:ok, checkout}, _repository, _sha, _checkout_path), do: {:ok, checkout}
  defp create_or_reuse_checkout({:blocked, _} = blocked, _repository, _sha, _checkout_path), do: blocked

  defp validation_checkout_effect_key(options, target), do: "validation_checkout:#{options[:operation_key] || target.key}"

  defp validation_checkout_intent(feature_id, target, identity, checkout_path, key) do
    %{
      "checkout_path" => Path.expand(checkout_path),
      "feature_id" => feature_id,
      "operation" => "validation_checkout",
      "operation_key" => key,
      "repository" => Path.expand(target.repository),
      "sha" => identity.sha,
      "tree" => identity.tree
    }
  end

  defp execute(runtime, feature_id, validator, target, identity, checkout, timeout_ms, options) do
    started_at = timestamp()
    context = %{candidate_sha: identity.sha, command: "configured validator", purpose: target.purpose, sha: identity.sha, tree: identity.tree, workspace: checkout}

    invocation = %{
      runtime: runtime,
      feature_id: feature_id,
      target: target,
      identity: identity,
      checkout: checkout,
      context: context,
      timeout_ms: timeout_ms,
      options: options
    }

    {result, cleanup?, process_execution_id} = invoke(validator, invocation)
    integrity = Git.validation_checkout_integrity(checkout, identity)

    {status, exit_status, diagnostic, classification} =
      case integrity do
        :ok -> normalize(result)
        {:blocked, reason} -> {"blocked", nil, inspect(reason), Failure.classify(:validation, reason)}
      end

    evidence = %{
      "command" => command(result),
      "diagnostic" => bounded(diagnostic),
      "ended_at" => timestamp(),
      "exit_status" => exit_status,
      "sha" => identity.sha,
      "started_at" => started_at,
      "status" => status,
      "tree" => identity.tree,
      "working_directory" => checkout,
      "failure_classification" => if(status == "blocked", do: Atom.to_string(classification), else: nil)
    }

    {maybe_process_execution_id(evidence, process_execution_id), cleanup?}
  end

  defp invoke(%{executable: executable, args: args} = command, invocation)
       when is_binary(executable) and is_list(args) do
    owned_invoke(command, invocation)
  end

  # Function validators are retained for deterministic in-VM tests and policy
  # adapters. They are not an executable-validator interface: production
  # commands must be supplied as %{executable: binary, args: [binary]}.
  defp invoke(validator, invocation) when is_function(validator, 1) do
    # Callback validators are test/policy adapters, but their bounded BEAM
    # execution still receives a durable lifecycle record. This preserves the
    # same final termination invariant as command validators.
    case callback_execution(invocation) do
      {:ok, execution_id} ->
        result = invoke_callback(validator, invocation.context, invocation.timeout_ms)
        :ok = finish_callback_execution(invocation.runtime, execution_id)
        {result, true, execution_id}

      {:blocked, reason} ->
        {{:blocked, reason}, false, nil}
    end
  end

  defp invoke(_validator, _invocation),
    do: {{:blocked, :invalid_validation_command}, true, nil}

  defp owned_invoke(command, invocation) do
    with {:ok, execution} <- validation_execution(invocation.feature_id, invocation.target, invocation.identity, invocation.options),
         {:ok, sandbox} <- validation_sandbox(invocation.runtime, invocation.checkout, execution, invocation.options),
         {:ok, _started} <- ProcessOwner.start(invocation.runtime, execution, command, sandbox) do
      case ProcessOwner.await(invocation.runtime, execution.execution_id, invocation.timeout_ms) do
        {:ok, 0} ->
          {{:ok, %{command: command_label(command), output: "validator exited successfully", exit_status: 0}}, true, execution.execution_id}

        {:ok, status} ->
          {{:error, %{command: command_label(command), output: "validator exited with status #{status}", exit_status: status}}, true, execution.execution_id}

        {:timeout, nil} ->
          {{:blocked, :timeout}, true, execution.execution_id}

        {:blocked, reason} ->
          {{:blocked, reason}, false, execution.execution_id}
      end
    else
      {:blocked, reason} -> {{:blocked, reason}, false, nil}
      {:error, reason} -> {{:blocked, reason}, false, nil}
    end
  end

  defp callback_execution(invocation) do
    execution_id = "validation-callback-" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

    Store.transaction(invocation.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, execution_kind, operation_key, candidate_sha, candidate_tree) VALUES (?, ?, ?, ?, ?, 'running', 'validation', ?, ?, ?)",
        [
          execution_id,
          invocation.target.key,
          invocation.feature_id,
          invocation.options[:revision] || 0,
          "symphony-feature-#{execution_id}.callback",
          invocation.options[:operation_key] || invocation.target.key,
          invocation.identity.sha,
          invocation.identity.tree
        ]
      )
    end)

    {:ok, execution_id}
  rescue
    _ -> {:blocked, :validation_callback_execution_unavailable}
  end

  defp finish_callback_execution(runtime, execution_id) do
    Store.transaction(runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'terminated' WHERE execution_id = ? AND execution_kind = 'validation'", [execution_id])
      :ok
    end)
  end

  defp maybe_process_execution_id(evidence, execution_id) when is_binary(execution_id), do: Map.put(evidence, "process_execution_id", execution_id)
  defp maybe_process_execution_id(evidence, _), do: evidence

  defp validation_execution(feature_id, _target, identity, options) do
    with operation_key when is_binary(operation_key) and operation_key != "" <- options[:operation_key],
         revision when is_integer(revision) and revision >= 0 <- options[:revision] do
      nonce = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

      {:ok,
       %{
         attempt_id: operation_key,
         candidate_sha: identity.sha,
         candidate_tree: identity.tree,
         execution_id: "validation-#{nonce}",
         execution_kind: "validation",
         feature_id: feature_id,
         operation_key: operation_key,
         revision: revision
       }}
    else
      _ -> {:blocked, :validation_execution_identity_required}
    end
  end

  defp validation_sandbox(runtime, checkout, execution, options) do
    with output_root when is_binary(output_root) and output_root != "" <- options[:output_root],
         output = Path.join([output_root, "validation", execution.execution_id]),
         :ok <- File.mkdir_p(output) do
      Sandbox.profile(role: :test, workspace: checkout, output: output, runtime: runtime)
    else
      _ -> {:blocked, :validation_sandbox_required}
    end
  end

  defp command_label(%{executable: executable, args: args}), do: Enum.join([executable | args], " ")

  defp cleanup_checkout(runtime, feature_id, target, options, repository, checkout) do
    :ok = Git.remove_validation_checkout(repository, checkout)
    _ = File.rmdir(Path.dirname(checkout))
    :ok = Effects.discard(runtime, feature_id, validation_checkout_effect_key(options, target))
  end

  defp invoke_callback(validator, context, timeout_ms) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, validator.(context)}
          rescue
            error -> {:error, {:validator_raised, Exception.message(error)}}
          catch
            kind, reason -> {:error, {:validator_raised, kind, reason}}
          end

        send(caller, {token, result})
      end)

    receive do
      {^token, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {^token, {:error, reason}} ->
        Process.demonitor(monitor, [:flush])
        {:blocked, reason}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:blocked, {:validator_raised, reason}}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        {:blocked, :timeout}
    end
  rescue
    error -> {:blocked, {:validator_raised, Exception.message(error)}}
  catch
    kind, reason -> {:blocked, {:validator_raised, kind, reason}}
  end

  defp normalize(:ok), do: {"passed", 0, "validator passed", nil}
  defp normalize({:ok, evidence}), do: {"passed", 0, diagnostic(evidence), nil}
  defp normalize({:error, reason}), do: {"failed", exit_status(reason, 1), diagnostic(reason), :implementation_failure}
  defp normalize({:blocked, reason}), do: {"blocked", exit_status(reason, nil), diagnostic(reason), Failure.classify(:validation, reason)}
  defp normalize(other), do: {"blocked", nil, "invalid validator result: #{inspect(other)}", :implementation_failure}

  defp command({_, evidence}) when is_map(evidence), do: Map.get(evidence, :command) || Map.get(evidence, "command") || "configured validator"
  defp command(_), do: "configured validator"
  defp exit_status(evidence, default) when is_map(evidence), do: Map.get(evidence, :exit_status) || Map.get(evidence, "exit_status") || default
  defp exit_status(_, default), do: default
  defp diagnostic(evidence) when is_binary(evidence), do: evidence
  defp diagnostic(evidence) when is_map(evidence), do: Map.get(evidence, :output) || Map.get(evidence, "output") || inspect(evidence)
  defp diagnostic(evidence), do: inspect(evidence)
  defp bounded(value), do: value |> to_string() |> String.slice(0, @diagnostic_limit)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp persist(runtime, feature_id, key, purpose, evidence) do
    Store.transaction(runtime, fn db ->
      Store.execute(db, "INSERT INTO validation_evidence (feature_id, validation_key, purpose, sha, tree, status, evidence_json) VALUES (?, ?, ?, ?, ?, ?, ?)", [
        feature_id,
        key,
        purpose,
        evidence["sha"],
        evidence["tree"],
        evidence["status"],
        Jason.encode!(evidence)
      ])

      {:ok, evidence}
    end)
  end
end
