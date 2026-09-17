defmodule SymphonyElixir.Feature.Readiness do
  @moduledoc "Central predicate for the only transition to `ReadyForHuman`."

  @spec ready?(map(), boolean()) :: boolean()
  def ready?(state, active_writer?) when is_map(state) and is_boolean(active_writer?) do
    Enum.all?(readiness_checks(state, active_writer?), & &1)
  end

  def ready?(_, _), do: false

  defp readiness_checks(state, active_writer?) do
    final_sha = state["final_sha"]

    [
      state["phase"] == "ReadinessCheck",
      accepted_tasks?(state),
      approved_final_review?(state, final_sha),
      passed_for?(state["final_validation"], final_sha),
      no_actionable_findings?(state),
      not blocked?(state),
      not pending_human_decision?(state),
      not active_writer?
    ]
  end

  defp accepted_tasks?(state), do: Enum.all?(state["tasks"] || [], &(&1["status"] == "accepted"))

  defp approved_final_review?(state, sha) do
    review = state["final_review"] || state["review"]
    is_binary(sha) and sha != "" and is_map(review) and review["status"] == "approved" and review["sha"] == sha and state["final_review_sha"] == sha
  end

  defp passed_for?(validation, sha), do: is_map(validation) and validation["status"] == "passed" and validation["sha"] == sha

  defp no_actionable_findings?(state), do: state["findings"] in [nil, []]

  defp blocked?(state), do: Map.get(state, "validation_blocker") not in [nil, false] or Map.get(state, "technical_blocker") not in [nil, false]

  defp pending_human_decision?(state), do: state["phase"] == "WaitingForHuman" or is_binary(state["question"])
end
