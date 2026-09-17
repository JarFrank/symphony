defmodule SymphonyElixir.Feature.State do
  @moduledoc "Pure, closed feature lifecycle transition rules."
  alias SymphonyElixir.Feature.Readiness

  @spec new(String.t()) :: map()
  def new(spec),
    do: %{
      "phase" => "Planning",
      "spec" => spec,
      "tasks" => [],
      "current" => 0,
      "head" => "base",
      "initial_base_sha" => nil,
      "expected_head_sha" => nil,
      "review" => nil,
      "findings" => [],
      "task_repair_count" => 0,
      "final_repair_count" => 0,
      "status" => %{"current_phase" => "Planning", "latest_event" => "feature created"}
    }

  @doc "Adopts an observed coordinator baseline; this is the only legacy `base` upgrade path."
  @spec adopt_baseline(map(), String.t(), boolean()) :: map()
  def adopt_baseline(state, sha, adopted) when is_binary(sha) and sha != "" and is_boolean(adopted) do
    now = System.system_time(:millisecond)

    state
    |> Map.put("head", sha)
    |> Map.put("initial_base_sha", sha)
    |> Map.put("expected_head_sha", sha)
    |> put_status(%{"started_at" => now, "last_event_at" => now, "latest_event" => if(adopted, do: "explicit dirty baseline adopted", else: "clean workspace baseline recorded")})
  end

  @doc "Stores the compact durable status projection used by the read-only CLI."
  @spec put_status(map(), map()) :: map()
  def put_status(state, updates) when is_map(updates) do
    status = Map.merge(state["status"] || %{}, updates)
    Map.put(state, "status", Map.put(status, "current_phase", state["phase"]))
  end

  @spec role(map()) :: String.t() | nil
  def role(%{"phase" => phase}) do
    case phase do
      p when p in ["Planning", "Resolving"] -> "mastermind"
      "Implementing" -> "developer"
      p when p in ["Reviewing", "FinalReview"] -> "reviewer"
      _ -> nil
    end
  end

  @spec transition(map(), map()) :: map()
  def transition(state, result) do
    next =
      case next(state, result) do
        {:ok, next} -> next
        :invalid -> Map.merge(state, %{"phase" => "Failed", "error" => "invalid role result"})
      end

    put_status(next, %{"last_event_at" => System.system_time(:millisecond), "latest_event" => "transitioned to #{next["phase"]}"})
  end

  @spec valid_result?(map(), term()) :: boolean()
  def valid_result?(state, result), do: match?({:ok, _}, next(state, result))

  @doc "Reopens one concrete task for a coordinator-recorded implementation repair."
  @spec reopen_for_repair(map(), String.t(), String.t()) :: {:ok, map()} | :invalid
  def reopen_for_repair(state, task_id, diagnostic) when is_binary(task_id) and task_id != "" and is_binary(diagnostic) and diagnostic != "" do
    case Enum.find_index(state["tasks"] || [], &(&1["id"] == task_id)) do
      index when is_integer(index) ->
        task = Enum.at(state["tasks"], index) |> Map.put("status", "pending")

        finding = %{
          "finding_id" => "recovery:#{task_id}:#{state["revision"] || 0}",
          "source_role" => "Recovery",
          "source_attempt_id" => nil,
          "source_execution_id" => nil,
          "source_sha" => state["head"],
          "affected_task_id" => task_id,
          "severity" => "actionable",
          "message" => diagnostic,
          "status" => "open",
          "addressed_by_sha" => nil,
          "candidate_resolution" => nil,
          "resolved_by_sha" => nil,
          "resolution_evidence" => nil
        }

        {:ok,
         state
         |> Map.put("tasks", List.replace_at(state["tasks"], index, task))
         |> Map.merge(%{
           "phase" => "Implementing",
           "current" => index,
           "findings" => (state["findings"] || []) ++ [finding],
           "repair_origin" => "recovery",
           "repair_affected_task_id" => task_id,
           "validation_blocker" => nil,
           "technical_blocker" => nil
         })}

      _ ->
        :invalid
    end
  end

  def reopen_for_repair(_, _, _), do: :invalid

  defp next(state, %{"status" => "failed", "reason" => r}) when is_binary(r) and r != "", do: {:ok, Map.merge(state, %{"phase" => "Failed", "error" => r})}

  defp next(%{"phase" => "Planning"} = s, %{"status" => "planned", "tasks" => ts}) when is_list(ts) and length(ts) == 2 do
    if valid_tasks?(ts),
      do: {:ok, Map.merge(s, %{"phase" => "Implementing", "tasks" => Enum.map(ts, &Map.merge(&1, %{"status" => "pending", "base_sha" => nil, "head_sha" => nil, "rework_count" => 0}))})},
      else: :invalid
  end

  defp next(%{"phase" => "Implementing"} = s, %{"status" => "completed", "sha" => sha} = r) when is_binary(sha) and sha != "" do
    task = Enum.at(s["tasks"], s["current"])

    with {:ok, fs} <- record_candidate_resolutions(s, task["id"], sha, r) do
      task =
        Map.merge(task, %{
          "status" => "validating",
          "base_sha" => task["base_sha"] || s["head"],
          "head_sha" => sha,
          "implementation_attempt_id" => r["implementation_attempt_id"],
          "implementation_execution_id" => r["implementation_execution_id"]
        })

      {:ok,
       s
       |> put_task(task)
       |> Map.merge(%{
         "phase" => "Validating",
         "head" => sha,
         "expected_head_sha" => sha,
         "implementation_attempt_id" => r["implementation_attempt_id"],
         "implementation_execution_id" => r["implementation_execution_id"],
         "findings" => fs,
         "review" => nil,
         "validation_target" => %{"purpose" => "review", "sha" => sha, "task_id" => task["id"]},
         "validation_blocker" => nil
       })}
    end
  end

  defp next(%{"phase" => p} = s, %{"status" => "technical_question", "question" => q}) when p in ["Implementing", "Reviewing", "FinalReview"] and is_binary(q) and q != "",
    do: {:ok, Map.merge(s, %{"phase" => "Resolving", "return_phase" => p, "question" => q, "technical_blocker" => q})}

  defp next(%{"phase" => p} = s, %{"status" => "human_decision_required", "question" => q}) when p in ["Planning", "Resolving"] and is_binary(q) and q != "",
    do: {:ok, Map.merge(s, %{"phase" => "WaitingForHuman", "return_phase" => s["return_phase"] || p, "question" => q})}

  defp next(%{"phase" => "Resolving"} = s, %{"status" => "resolved", "answer" => a}) when is_binary(a) and a != "", do: {:ok, answer(s, a)}

  defp next(%{"phase" => "Validating", "validation_target" => t} = s, %{"status" => "validation_passed", "validation" => e}) do
    if matching?(t, e, "passed") do
      s = validation_fact(s, e) |> resolve_validation_findings(t, e)

      if t["purpose"] == "final",
        do: {:ok, Map.merge(s, %{"phase" => "ReadinessCheck", "final_validation" => e, "validation" => e, "validation_target" => nil})},
        else: {:ok, s |> current_status("reviewing") |> Map.merge(%{"phase" => "Reviewing", "validation" => e, "validation_target" => nil})}
    else
      :invalid
    end
  end

  defp next(%{"phase" => "Validating", "validation_target" => t} = s, %{"status" => "validation_failed", "validation" => e} = r),
    do: if(matching?(t, e, "failed"), do: repair_validation(validation_fact(s, e), t, e, r), else: :invalid)

  defp next(%{"phase" => "Validating", "validation_target" => t} = s, %{"status" => "validation_blocked", "validation" => e}),
    do:
      if(matching?(t, e, "blocked") or not is_map(t),
        do: {:ok, validation_fact(s, e) |> Map.merge(%{"phase" => "ValidationBlocked", "validation" => e, "validation_blocker" => e, "validation_target" => nil})},
        else: :invalid
      )

  defp next(%{"phase" => p, "head" => sha, "validation" => v} = s, %{"status" => "approved", "sha" => sha} = r) when p in ["Reviewing", "FinalReview"],
    do: if(passed?(v, sha) and no_findings?(r), do: approved(review_fact(s, r), r), else: :invalid)

  defp next(%{"phase" => p, "head" => sha} = s, %{"status" => "changes_requested", "sha" => sha, "findings" => ms} = r) when p in ["Reviewing", "FinalReview"] and is_list(ms) and ms != [] do
    i = if(p == "FinalReview", do: Enum.find_index(s["tasks"], &(&1["id"] == r["task_id"])), else: s["current"])

    if is_integer(i) and Enum.all?(ms, &(is_binary(&1) and &1 != "")) do
      tid = Enum.at(s["tasks"], i)["id"]
      origin = if(p == "FinalReview", do: :final_review, else: :task_review)
      schedule(review_fact(s, r), i, s["findings"] ++ new_findings(r, p, tid, sha), origin, r)
    else
      :invalid
    end
  end

  defp next(%{"phase" => "ReadinessCheck"} = s, %{"status" => "ready_for_human", "active_writer" => w} = result) when is_boolean(w),
    do: if(Readiness.ready?(s, w, Map.get(result, "processes_confirmed", true)), do: {:ok, Map.put(s, "phase", "ReadyForHuman")}, else: :invalid)

  defp next(_, _), do: :invalid

  defp approved(%{"phase" => "FinalReview"} = s, r) do
    s = resolve_review_findings(s, r, "FinalReview")

    if Enum.all?(s["tasks"], &(&1["status"] == "accepted")),
      do:
        {:ok,
         Map.merge(s, %{
           "phase" => "Validating",
           "review" => r,
           "final_review" => r,
           "final_review_sha" => s["head"],
           "final_sha" => s["head"],
           "validation_target" => %{"purpose" => "final", "sha" => s["head"], "task_id" => r["task_id"] || Enum.at(s["tasks"], s["current"])["id"]}
         })},
      else: :invalid
  end

  defp approved(s, r) do
    s = resolve_review_findings(s, r, "Reviewer")
    s = put_task(s, Enum.at(s["tasks"], s["current"]) |> Map.put("status", "accepted") |> Map.put("review", r))

    if s["final_rework"] == true or s["current"] == length(s["tasks"]) - 1,
      do: {:ok, Map.merge(s, %{"phase" => "FinalReview", "review" => r})},
      else: {:ok, Map.merge(s, %{"phase" => "Implementing", "current" => s["current"] + 1})}
  end

  defp repair_validation(s, t, e, r) do
    final? = t["purpose"] == "final"
    i = Enum.find_index(s["tasks"], &(&1["id"] == t["task_id"])) || s["current"]
    tid = Enum.at(s["tasks"], i)["id"]

    f = %{
      "finding_id" => "validation:#{t["purpose"]}:#{t["sha"]}:#{length(s["findings"]) + 1}",
      "source_role" => "Validation",
      "source_attempt_id" => s["implementation_attempt_id"],
      "source_execution_id" => s["implementation_execution_id"],
      "source_sha" => t["sha"],
      "affected_task_id" => tid,
      "severity" => "actionable",
      "message" => "Executable validation failed: #{e["diagnostic"]}",
      "status" => "open",
      "addressed_by_sha" => nil,
      "candidate_resolution" => nil,
      "resolved_by_sha" => nil,
      "resolution_evidence" => %{"validation" => e}
    }

    schedule(s, i, s["findings"] ++ [f], if(final?, do: :final_validation, else: :validation), r)
  end

  defp schedule(s, i, fs, origin, r) do
    final? = origin in [:final_review, :final_validation]
    key = if(final?, do: "final_repair_count", else: "task_repair_count")
    limit = get_in(r, ["repair_budget", if(final?, do: "final", else: "task")])
    count = Map.get(s, key, 0)
    task = Enum.at(s["tasks"], i) |> Map.put("status", "pending") |> Map.update("rework_count", 1, &(&1 + 1))

    base =
      s
      |> put_task_at(i, task)
      |> Map.merge(%{
        "findings" => fs,
        "review" => nil,
        "repair_origin" => Atom.to_string(origin),
        "repair_affected_task_id" => task["id"],
        "final_rework" => s["final_rework"] == true or final?,
        key => count + 1
      })

    if is_integer(limit) and count >= limit,
      do: {:ok, Map.merge(base, %{"phase" => "ValidationBlocked", "validation_blocker" => %{"status" => "repair_exhausted", "origin" => Atom.to_string(origin), "affected_task_id" => task["id"]}})},
      else: {:ok, Map.merge(base, %{"phase" => "Implementing", "current" => i, "validation_target" => nil})}
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp record_candidate_resolutions(s, tid, sha, r) do
    # Compatibility for the pure legacy runner: it has no captured execution
    # identity with which to carry coordinator resolution evidence.  Real
    # LocalRunner executions always provide it and must use explicit entries.
    rs =
      r["resolutions"] ||
        if(is_nil(r["implementation_attempt_id"]),
          do:
            Enum.filter(s["findings"] || [], &(&1["status"] == "open" and &1["affected_task_id"] == tid))
            |> Enum.map(&%{"finding_id" => &1["finding_id"], "resolution_evidence" => %{"legacy_transition" => true, "candidate_sha" => sha}}),
          else: []
        )

    open = Enum.filter(s["findings"] || [], &(&1["status"] == "open"))
    ids = Enum.map(rs, & &1["finding_id"])
    chosen = Enum.filter(open, &(&1["finding_id"] in ids))

    cond do
      rs == [] ->
        {:ok, s["findings"] || []}

      length(ids) != length(Enum.uniq(ids)) or length(chosen) != length(rs) ->
        :invalid

      Enum.any?(chosen, &(&1["affected_task_id"] != tid or &1["source_sha"] == sha)) ->
        :invalid

      Enum.any?(rs, &(not is_map(&1["resolution_evidence"]))) ->
        :invalid

      true ->
        {:ok,
         Enum.map(s["findings"], fn f ->
           x = Enum.find(rs, &(&1["finding_id"] == f["finding_id"]))

           if x,
             do:
               Map.merge(f, %{
                 "addressed_by_sha" => sha,
                 "candidate_resolution" => x["resolution_evidence"]
               }),
             else: f
         end)}
    end
  end

  defp resolve_review_findings(s, r, source_role) do
    task_id = r["task_id"] || Enum.at(s["tasks"], s["current"])["id"]

    resolve_candidates(s, task_id, r["sha"], source_role, %{
      "review" => r,
      "approved_sha" => r["sha"]
    })
  end

  defp resolve_validation_findings(s, target, evidence) do
    resolve_candidates(s, target["task_id"], target["sha"], "Validation", %{
      "validation" => evidence,
      "passed_sha" => target["sha"]
    })
  end

  defp resolve_candidates(s, task_id, sha, source_role, evidence) do
    findings =
      Enum.map(s["findings"] || [], fn finding ->
        if finding["status"] == "open" and finding["source_role"] == source_role and
             finding["affected_task_id"] == task_id and finding["addressed_by_sha"] == sha do
          Map.merge(finding, %{
            "status" => "resolved",
            "resolved_by_sha" => sha,
            "resolution_evidence" => evidence
          })
        else
          finding
        end
      end)

    Map.put(s, "findings", findings)
  end

  defp new_findings(r, p, tid, sha) do
    Enum.with_index(r["findings"], 1)
    |> Enum.map(fn {message, number} ->
      attempt = r["review_attempt_id"] || "review-unknown"
      execution = r["review_execution_id"] || "execution-unknown"

      %{
        "finding_id" => "#{attempt}:#{execution}:#{number}",
        "source_role" => if(p == "FinalReview", do: "FinalReview", else: "Reviewer"),
        "source_attempt_id" => attempt,
        "source_execution_id" => execution,
        "source_sha" => sha,
        "affected_task_id" => tid,
        "severity" => "actionable",
        "message" => message,
        "status" => "open",
        "addressed_by_sha" => nil,
        "candidate_resolution" => nil,
        "resolved_by_sha" => nil,
        "resolution_evidence" => nil
      }
    end)
  end

  defp review_fact(s, r), do: Map.update(s, "review_evidence", [r], &(&1 ++ [r]))
  defp validation_fact(s, e), do: Map.update(s, "validation_evidence", [e], &(&1 ++ [e]))
  @spec answer(map(), String.t()) :: map()
  def answer(s, a) when is_binary(a) and a != "", do: Map.merge(s, %{"phase" => s["return_phase"], "answer" => a, "question" => nil, "return_phase" => nil, "technical_blocker" => nil})
  defp matching?(t, e, status), do: is_map(t) and is_map(e) and e["status"] == status and e["sha"] == t["sha"]
  defp passed?(v, sha), do: is_map(v) and v["status"] == "passed" and v["sha"] == sha
  defp no_findings?(r), do: r["findings"] in [nil, []]
  defp valid_tasks?(ts), do: Enum.all?(ts, fn t -> is_map(t) and Enum.all?(["id", "scope", "acceptance"], &(is_binary(t[&1]) and t[&1] != "")) end) and length(Enum.uniq_by(ts, & &1["id"])) == 2
  defp put_task(s, t), do: Map.put(s, "tasks", List.replace_at(s["tasks"], s["current"], t))
  defp put_task_at(s, index, task), do: Map.put(s, "tasks", List.replace_at(s["tasks"], index, task))
  defp current_status(s, status), do: put_task(s, Enum.at(s["tasks"], s["current"]) |> Map.put("status", status))
end
