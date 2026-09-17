defmodule SymphonyElixir.Feature.State do
  @moduledoc "Pure, closed feature lifecycle transition rules."

  alias SymphonyElixir.Feature.Readiness

  @spec new(String.t()) :: map()
  def new(spec), do: %{"phase" => "Planning", "spec" => spec, "tasks" => [], "current" => 0, "head" => "base", "review" => nil}

  @spec role(map()) :: String.t() | nil
  def role(%{"phase" => phase}) do
    case phase do
      p when p in ["Planning", "Resolving"] -> "mastermind"
      "Implementing" -> "developer"
      p when p in ["Reviewing", "FinalReview"] -> "reviewer"
      p when p in ["Validating", "ValidationBlocked", "ReadinessCheck", "WaitingForHuman", "ReadyForHuman", "Failed"] -> nil
    end
  end

  @spec transition(map(), map()) :: map()
  def transition(state, result) do
    case next(state, result) do
      {:ok, next} -> next
      :invalid -> Map.merge(state, %{"phase" => "Failed", "error" => "invalid role result"})
    end
  end

  @spec valid_result?(map(), term()) :: boolean()
  def valid_result?(state, result), do: match?({:ok, _}, next(state, result))

  defp next(state, %{"status" => "failed", "reason" => reason}) when is_binary(reason) and reason != "", do: {:ok, Map.merge(state, %{"phase" => "Failed", "error" => reason})}

  defp next(%{"phase" => "Planning"} = state, %{"status" => "planned", "tasks" => tasks}) when is_list(tasks) and length(tasks) == 2 do
    if valid_tasks?(tasks) do
      tasks = Enum.map(tasks, &Map.merge(&1, %{"status" => "pending", "base_sha" => nil, "head_sha" => nil, "rework_count" => 0}))
      {:ok, Map.merge(state, %{"phase" => "Implementing", "tasks" => tasks})}
    else
      :invalid
    end
  end

  defp next(%{"phase" => "Implementing"} = state, %{"status" => "completed", "sha" => sha} = result) when is_binary(sha) and sha != "" do
    task = Enum.at(state["tasks"], state["current"])

    task =
      Map.merge(task, %{
        "status" => "validating",
        "base_sha" => task["base_sha"] || state["head"],
        "head_sha" => sha,
        "implementation_attempt_id" => result["implementation_attempt_id"],
        "implementation_execution_id" => result["implementation_execution_id"]
      })

    {:ok,
     state
     |> put_task(task)
     |> Map.merge(%{
       "phase" => "Validating",
       "head" => sha,
       "implementation_attempt_id" => result["implementation_attempt_id"],
       "implementation_execution_id" => result["implementation_execution_id"],
       "findings" => [],
       "review" => nil,
       "validation_target" => %{"purpose" => "review", "sha" => sha, "task_id" => task["id"]},
       "validation_blocker" => nil
     })}
  end

  defp next(%{"phase" => phase} = state, %{"status" => "technical_question", "question" => question})
       when phase in ["Implementing", "Reviewing", "FinalReview"] and is_binary(question) and question != "",
       do: {:ok, Map.merge(state, %{"phase" => "Resolving", "return_phase" => phase, "question" => question, "technical_blocker" => question})}

  defp next(%{"phase" => phase} = state, %{"status" => "human_decision_required", "question" => question}) when phase in ["Planning", "Resolving"] and is_binary(question) and question != "",
    do: {:ok, Map.merge(state, %{"phase" => "WaitingForHuman", "return_phase" => state["return_phase"] || phase, "question" => question})}

  defp next(%{"phase" => "Resolving"} = state, %{"status" => "resolved", "answer" => answer}) when is_binary(answer) and answer != "", do: {:ok, answer(state, answer)}

  defp next(%{"phase" => "Validating", "validation_target" => target} = state, %{"status" => "validation_passed", "validation" => evidence}) do
    if matching_validation?(target, evidence, "passed") do
      if target["purpose"] == "final" do
        {:ok, Map.merge(state, %{"phase" => "ReadinessCheck", "final_validation" => evidence, "validation" => evidence, "validation_target" => nil})}
      else
        task = Enum.at(state["tasks"], state["current"]) |> Map.put("status", "reviewing")
        {:ok, state |> put_task(task) |> Map.merge(%{"phase" => "Reviewing", "validation" => evidence, "validation_target" => nil})}
      end
    else
      :invalid
    end
  end

  defp next(%{"phase" => "Validating", "validation_target" => target} = state, %{"status" => "validation_failed", "validation" => evidence}) do
    if matching_validation?(target, evidence, "failed"),
      do: repair_after_validation_failure(state, target, evidence),
      else: :invalid
  end

  defp next(%{"phase" => "Validating", "validation_target" => target} = state, %{"status" => "validation_blocked", "validation" => evidence}) do
    if matching_validation?(target, evidence, "blocked") or not is_map(target),
      do: {:ok, Map.merge(state, %{"phase" => "ValidationBlocked", "validation" => evidence, "validation_blocker" => evidence, "validation_target" => nil})},
      else: :invalid
  end

  defp next(%{"phase" => phase, "head" => sha, "validation" => validation} = state, %{"status" => "approved", "sha" => sha} = result) when phase in ["Reviewing", "FinalReview"] do
    if passed_for?(validation, sha) and no_actionable_findings?(result), do: approved(state, result), else: :invalid
  end

  defp next(%{"phase" => phase, "head" => sha} = state, %{"status" => "changes_requested", "sha" => sha, "findings" => findings} = result)
       when phase in ["Reviewing", "FinalReview"] and is_list(findings) and findings != [] do
    index = if phase == "FinalReview", do: Enum.find_index(state["tasks"], &(&1["id"] == result["task_id"])), else: state["current"]

    if is_integer(index) and Enum.all?(findings, &(is_binary(&1) and &1 != "")) do
      state = Map.merge(state, %{"phase" => "Implementing", "current" => index, "findings" => findings, "review" => nil, "final_rework" => state["final_rework"] == true or phase == "FinalReview"})
      task = state["tasks"] |> Enum.at(index) |> Map.put("status", "pending") |> Map.update("rework_count", 1, &(&1 + 1))
      {:ok, put_task(state, task)}
    else
      :invalid
    end
  end

  defp next(%{"phase" => "ReadinessCheck"} = state, %{"status" => "ready_for_human", "active_writer" => active_writer?}) when is_boolean(active_writer?) do
    if Readiness.ready?(state, active_writer?), do: {:ok, Map.put(state, "phase", "ReadyForHuman")}, else: :invalid
  end

  defp next(_, _), do: :invalid

  defp approved(%{"phase" => "FinalReview"} = state, result) do
    if Enum.all?(state["tasks"], &(&1["status"] == "accepted")) do
      task_id = result["task_id"] || Enum.at(state["tasks"], state["current"])["id"]

      {:ok,
       Map.merge(state, %{
         "phase" => "Validating",
         "review" => result,
         "final_review" => result,
         "final_review_sha" => state["head"],
         "final_sha" => state["head"],
         "validation_target" => %{"purpose" => "final", "sha" => state["head"], "task_id" => task_id}
       })}
    else
      :invalid
    end
  end

  defp approved(state, result) do
    task = Enum.at(state["tasks"], state["current"]) |> Map.put("status", "accepted") |> Map.put("review", result)
    state = put_task(state, task)

    if state["final_rework"] == true or state["current"] == length(state["tasks"]) - 1,
      do: {:ok, Map.merge(state, %{"phase" => "FinalReview", "review" => result})},
      else: {:ok, Map.merge(state, %{"phase" => "Implementing", "current" => state["current"] + 1, "findings" => []})}
  end

  defp repair_after_validation_failure(state, target, evidence) do
    index = Enum.find_index(state["tasks"], &(&1["id"] == target["task_id"]))

    if is_integer(index) do
      task = state["tasks"] |> Enum.at(index) |> Map.put("status", "pending")
      state = put_task(state, task)
      final? = target["purpose"] == "final"

      {:ok,
       Map.merge(state, %{
         "phase" => "Implementing",
         "current" => index,
         "findings" => ["Executable validation failed: #{evidence["diagnostic"]}"],
         "review" => nil,
         "final_rework" => state["final_rework"] == true or final?,
         "validation" => evidence,
         "validation_target" => nil,
         "final_review" => if(final?, do: nil, else: state["final_review"]),
         "final_review_sha" => if(final?, do: nil, else: state["final_review_sha"]),
         "final_sha" => if(final?, do: nil, else: state["final_sha"])
       })}
    else
      :invalid
    end
  end

  @spec answer(map(), String.t()) :: map()
  def answer(state, answer) when is_binary(answer) and answer != "",
    do: Map.merge(state, %{"phase" => state["return_phase"], "answer" => answer, "question" => nil, "return_phase" => nil, "technical_blocker" => nil})

  defp matching_validation?(target, evidence, status), do: is_map(target) and is_map(evidence) and evidence["status"] == status and evidence["sha"] == target["sha"]
  defp passed_for?(validation, sha), do: is_map(validation) and validation["status"] == "passed" and validation["sha"] == sha
  defp no_actionable_findings?(result), do: result["findings"] in [nil, []]

  defp valid_tasks?(tasks),
    do: Enum.all?(tasks, fn task -> is_map(task) and Enum.all?(["id", "scope", "acceptance"], &(is_binary(task[&1]) and task[&1] != "")) end) and length(Enum.uniq_by(tasks, & &1["id"])) == 2

  defp put_task(state, task), do: Map.put(state, "tasks", List.replace_at(state["tasks"], state["current"], task))
end
