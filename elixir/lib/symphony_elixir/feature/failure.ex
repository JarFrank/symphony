defmodule SymphonyElixir.Feature.Failure do
  @moduledoc "Small, explicit recovery taxonomy shared by the local coordinator."

  @type classification ::
          :implementation_failure
          | :validation_environment_blocked
          | :transient_infrastructure
          | :integrity_failure
          | :retry_exhausted

  @spec classify(:capture | :validation | :executor, term()) :: classification()
  def classify(_operation, reason) when reason in [:validator_changed_tree, :validator_modified_sources, :stale_validation_tree], do: :integrity_failure
  def classify(_operation, {:process_identity_mismatch, _, _}), do: :integrity_failure
  def classify(_operation, {:ambiguous_execution, _}), do: :integrity_failure
  def classify(_operation, {:liveness_unknown, _, _}), do: :integrity_failure
  def classify(_operation, {:cgroup_not_empty, _}), do: :integrity_failure
  def classify(_operation, reason) when reason in [:timeout, :executor_timeout, :systemd_unavailable, :executor_unavailable], do: :transient_infrastructure
  def classify(_operation, {:systemd_run_failed, _}), do: :transient_infrastructure
  def classify(_operation, {:transport, _}), do: :transient_infrastructure
  def classify(:validation, reason) when reason in [:missing_tool, :missing_runtime, :runtime_unavailable, :tooling_unavailable], do: :validation_environment_blocked
  def classify(:validation, reason) when reason in [:invalid_validation_target, :git_directory_unavailable], do: :validation_environment_blocked
  def classify(:capture, reason) when reason in [:git_author_identity_missing, :git_author_identity_unavailable, :missing_git_identity], do: :validation_environment_blocked
  def classify(:validation, _reason), do: :implementation_failure
  def classify(:capture, _reason), do: :integrity_failure
  def classify(:executor, _reason), do: :transient_infrastructure

  @spec retryable?(classification()) :: boolean()
  def retryable?(classification), do: classification in [:validation_environment_blocked, :transient_infrastructure]
end
