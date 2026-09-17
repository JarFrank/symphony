defmodule SymphonyElixir.Feature.Validation do
  @moduledoc "Runs and journals executable validation for one immutable Git tree."

  alias SymphonyElixir.Feature.{Failure, Git, Store}

  @diagnostic_limit 4_096

  @spec run(Path.t(), String.t(), map(), (map() -> term()), Path.t(), pos_integer()) ::
          {:ok, map()} | {:blocked, term()}
  def run(runtime, feature_id, target, validator, checkout_path, timeout_ms \\ 300_000) do
    with {:ok, target} <- valid_target(target),
         :missing <- evidence(runtime, feature_id, target.key),
         {:ok, identity} <- Git.candidate_identity(target.repository, target.sha),
         :ok <- ensure_expected_tree(target, identity),
         :ok <- File.mkdir_p(Path.dirname(checkout_path)),
         {:ok, checkout} <- Git.prepare_validation_checkout(target.repository, target.sha, checkout_path) do
      evidence = execute(validator, target, identity, checkout, timeout_ms)
      :ok = Git.remove_validation_checkout(target.repository, checkout)
      _ = File.rmdir(Path.dirname(checkout))
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

  defp execute(validator, target, identity, checkout, timeout_ms) do
    started_at = timestamp()
    context = %{candidate_sha: identity.sha, command: "configured validator", purpose: target.purpose, sha: identity.sha, tree: identity.tree, workspace: checkout}
    result = invoke(validator, context, timeout_ms)
    integrity = Git.validation_checkout_integrity(checkout, identity)

    {status, exit_status, diagnostic, classification} =
      case integrity do
        :ok -> normalize(result)
        {:blocked, reason} -> {"blocked", nil, inspect(reason), Failure.classify(:validation, reason)}
      end

    %{
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
  end

  defp invoke(validator, context, timeout_ms) do
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
