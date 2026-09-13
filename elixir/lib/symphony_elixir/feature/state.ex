defmodule SymphonyElixir.Feature.State do
  @moduledoc "Pure, closed Stage 1 transition rules. Fake SHA values are evidence placeholders."

  @spec new(String.t()) :: map()
  def new(spec) do
    %{"phase" => "Planning", "spec" => spec, "tasks" => [], "current" => 0, "head" => "base", "review" => nil}
  end

  @spec role(map()) :: String.t() | nil
  def role(%{"phase" => phase}) do
    case phase do
      p when p in ["Planning", "Resolving"] -> "mastermind"
      "Implementing" -> "developer"
      p when p in ["Reviewing", "FinalReview"] -> "reviewer"
      p when p in ["WaitingForHuman", "ReadyForHuman", "Failed"] -> nil
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

  defp next(state, %{"status" => "failed", "reason" => reason}) when is_binary(reason) and reason != "" do
    {:ok, Map.merge(state, %{"phase" => "Failed", "error" => reason})}
  end

  defp next(%{"phase" => "Planning"} = state, %{"status" => "planned", "tasks" => tasks}) when is_list(tasks) and length(tasks) == 2 do
    if valid_tasks?(tasks) do
      tasks = Enum.map(tasks, &Map.merge(&1, %{"status" => "pending", "base_sha" => nil, "head_sha" => nil}))
      {:ok, Map.merge(state, %{"phase" => "Implementing", "tasks" => tasks})}
    else
      :invalid
    end
  end

  defp next(%{"phase" => "Implementing"} = state, %{"status" => "completed", "sha" => sha}) when is_binary(sha) and sha != "" do
    task = Enum.at(state["tasks"], state["current"])
    task = Map.merge(task, %{"status" => "reviewing", "base_sha" => task["base_sha"] || state["head"], "head_sha" => sha})
    {:ok, state |> put_task(task) |> Map.merge(%{"phase" => "Reviewing", "head" => sha, "review" => nil})}
  end

  defp next(%{"phase" => phase} = state, %{"status" => "technical_question", "question" => question})
       when phase in ["Implementing", "Reviewing", "FinalReview"] and is_binary(question) and question != "" do
    {:ok, Map.merge(state, %{"phase" => "Resolving", "return_phase" => phase, "question" => question})}
  end

  defp next(%{"phase" => phase} = state, %{"status" => "human_decision_required", "question" => question})
       when phase in ["Planning", "Resolving"] and is_binary(question) and question != "" do
    {:ok, Map.merge(state, %{"phase" => "WaitingForHuman", "return_phase" => state["return_phase"] || phase, "question" => question})}
  end

  defp next(%{"phase" => "Resolving"} = state, %{"status" => "resolved", "answer" => answer}) when is_binary(answer) and answer != "" do
    {:ok, answer(state, answer)}
  end

  defp next(%{"phase" => phase, "head" => sha} = state, %{"status" => "approved", "sha" => sha} = result)
       when phase in ["Reviewing", "FinalReview"] do
    approved(state, result)
  end

  defp next(%{"phase" => phase, "head" => sha} = state, %{"status" => "changes_requested", "sha" => sha, "findings" => findings} = result)
       when phase in ["Reviewing", "FinalReview"] and is_list(findings) and findings != [] do
    index = if phase == "FinalReview", do: Enum.find_index(state["tasks"], &(&1["id"] == result["task_id"])), else: state["current"]

    if is_integer(index) and Enum.all?(findings, &(is_binary(&1) and &1 != "")) do
      state = Map.merge(state, %{"phase" => "Implementing", "current" => index, "findings" => findings, "review" => nil, "final_rework" => state["final_rework"] == true or phase == "FinalReview"})
      task = Enum.at(state["tasks"], index) |> Map.put("status", "pending")
      {:ok, put_task(state, task)}
    else
      :invalid
    end
  end

  defp next(_, _), do: :invalid

  defp approved(%{"phase" => "FinalReview"} = state, result) do
    if Enum.all?(state["tasks"], &(&1["status"] == "accepted")) do
      {:ok, Map.merge(state, %{"phase" => "ReadyForHuman", "review" => result})}
    else
      :invalid
    end
  end

  defp approved(state, result) do
    task = Enum.at(state["tasks"], state["current"]) |> Map.put("status", "accepted") |> Map.put("review", result)
    state = put_task(state, task)

    if state["final_rework"] == true or state["current"] == length(state["tasks"]) - 1 do
      {:ok, Map.merge(state, %{"phase" => "FinalReview", "review" => result})}
    else
      {:ok, Map.merge(state, %{"phase" => "Implementing", "current" => state["current"] + 1, "findings" => []})}
    end
  end

  @spec answer(map(), String.t()) :: map()
  def answer(state, answer) when is_binary(answer) and answer != "" do
    Map.merge(state, %{"phase" => state["return_phase"], "answer" => answer, "question" => nil, "return_phase" => nil})
  end

  defp valid_tasks?(tasks) do
    Enum.all?(tasks, fn task -> is_map(task) and Enum.all?(["id", "scope", "acceptance"], &(is_binary(task[&1]) and task[&1] != "")) end) and
      length(Enum.uniq_by(tasks, & &1["id"])) == 2
  end

  defp put_task(state, task), do: Map.put(state, "tasks", List.replace_at(state["tasks"], state["current"], task))
end
