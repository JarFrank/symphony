defmodule SymphonyElixir.Feature.LocalRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{Git, LocalRunner, Store}
  alias SymphonyElixir.FeatureRunner

  setup do
    root = Path.join(System.tmp_dir!(), "local-feature-flow-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "developer")
    runtime = Path.join(root, "runtime/state.sqlite3")
    reviewer_root = Path.join(root, "reviewers")
    output_root = Path.join(root, "outputs")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(runtime))
    git!(workspace, ["init", "-b", "feature/local-flow"])
    git!(workspace, ["config", "--local", "user.name", "Local Feature Runner"])
    git!(workspace, ["config", "--local", "user.email", "local-runner@example.test"])
    File.write!(Path.join(workspace, "implementation.txt"), "base\n")
    git!(workspace, ["add", "implementation.txt"])
    git!(workspace, ["commit", "-m", "base"])
    Store.init(runtime)
    FeatureRunner.create(runtime, "feature", "Approved attendance feature")
    {:ok, calls} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      if Process.alive?(calls), do: Agent.stop(calls)
      File.rm_rf!(root)
    end)

    config = %{
      allowed_paths: ["implementation.txt"],
      executor: fn assignment -> acceptance_executor(assignment, calls, workspace) end,
      expected_branch: "feature/local-flow",
      max_reworks: 2,
      output_root: output_root,
      reviewer_root: reviewer_root,
      validator: fn context ->
        assert git!(workspace, ["rev-parse", "HEAD"]) == context.sha
        {:ok, "fixture validation"}
      end,
      workspace: workspace
    }

    %{calls: calls, config: config, root: root, runtime: runtime, workspace: workspace}
  end

  test "full local flow captures exact SHAs, requires fresh rework review, and reaches ReadyForHuman", context do
    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", context.config)
    assert ready["phase"] == "ReadyForHuman"
    assert ready["final_sha"] == git!(context.workspace, ["rev-parse", "HEAD"])
    assert ready["validation"] == %{"evidence" => "fixture validation", "status" => "passed"}
    assert Enum.map(ready["tasks"], & &1["status"]) == ["accepted", "accepted"]
    assert hd(ready["tasks"])["rework_count"] == 1

    calls = Agent.get(context.calls, &Enum.reverse/1)
    developers = Enum.filter(calls, &match?({"developer", _, _, _}, &1))
    reviewers = Enum.filter(calls, &match?({"reviewer", _, _, _, _}, &1))
    assert length(developers) == 3
    assert length(reviewers) == 4

    [{"reviewer", "Reviewing", "task-1", first_sha, first_checkout}, {"reviewer", "Reviewing", "task-1", rework_sha, rework_checkout} | _] = reviewers
    refute first_sha == rework_sha
    refute first_checkout == rework_checkout
    refute first_checkout == context.workspace
    refute rework_checkout == context.workspace

    final_review = List.last(reviewers)
    final_sha = ready["final_sha"]
    assert {"reviewer", "FinalReview", "task-2", ^final_sha, _checkout} = final_review

    assert Store.read(context.runtime, fn db ->
             Store.execute(
               db,
               "SELECT COUNT(*), COUNT(DISTINCT reviewed_sha) FROM reviewer_checkouts WHERE feature_id = 'feature'"
             )
           end) == [[4, 3]]

    refute Enum.any?(File.ls!(context.config.reviewer_root), &File.dir?(Path.join(context.config.reviewer_root, &1)))
    assert {:ok, ^ready} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "durable Developer output and Git capture recover without invoking Developer again", context do
    planning_only = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, implementing} = LocalRunner.step(context.runtime, "feature", planning_only)
    assert implementing["phase"] == "Implementing"

    {:execute, execution} = FeatureRunner.prepare(context.runtime, "feature")
    File.write!(Path.join(context.workspace, "implementation.txt"), "recovered developer output\n")

    assert {:ok, implementation} =
             Git.capture_implementation(context.runtime, %{
               allowed_paths: ["implementation.txt"],
               attempt_id: execution.attempt_id,
               execution_id: execution.execution_id,
               expected_branch: "feature/local-flow",
               feature_id: "feature",
               task_id: "task-1",
               workspace: context.workspace
             })

    persist_output(context.runtime, execution, "developer", "task-1", envelope(execution, "developer", "task-1", %{"status" => "completed"}))

    recovery = %{context.config | executor: fn _assignment -> flunk("Developer must not execute twice") end}
    assert {:ok, reviewing} = LocalRunner.step(context.runtime, "feature", recovery)
    assert reviewing["phase"] == "Reviewing"
    assert reviewing["head"] == implementation.sha
    assert reviewing["implementation_attempt_id"] == execution.attempt_id

    {:execute, reviewer} = FeatureRunner.prepare(context.runtime, "feature")
    checkout = Path.join(context.config.reviewer_root, reviewer.attempt_id)

    assert {:ok, review} =
             Git.prepare_reviewer_checkout(context.runtime, %{
               attempt_id: reviewer.attempt_id,
               checkout_path: checkout,
               execution_id: reviewer.execution_id,
               feature_id: "feature",
               implementation_attempt_id: execution.attempt_id,
               task_id: "task-1"
             })

    review_envelope =
      envelope(reviewer, "reviewer", "task-1", %{"status" => "approved"})
      |> Map.put("reviewed_sha", review.reviewed_sha)

    persist_output(context.runtime, reviewer, "reviewer", "task-1", review_envelope)

    reviewer_revision = reviewer.revision

    assert {:captured, ^reviewer_revision} =
             FeatureRunner.record(context.runtime, "feature", reviewer, %{
               "sha" => review.reviewed_sha,
               "status" => "approved"
             })

    assert {:ok, next_task} = LocalRunner.step(context.runtime, "feature", recovery)
    assert next_task["phase"] == "Implementing"
    refute File.exists?(checkout)
  end

  test "stale reviewer SHA fails closed and cannot approve a newer implementation", context do
    stale =
      Agent.start_link(fn -> nil end)
      |> then(fn {:ok, agent} ->
        on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
        agent
      end)

    executor = fn assignment ->
      result =
        case {assignment.role, assignment.phase} do
          {"mastermind", "Planning"} ->
            plan()

          {"developer", _} ->
            File.write!(Path.join(context.workspace, "implementation.txt"), "#{assignment.task_id}\n")
            %{"status" => "completed"}

          {"reviewer", _} ->
            old = Agent.get_and_update(stale, fn value -> {value, value || assignment.reviewed_sha} end)
            envelope(assignment, %{"status" => "approved"}) |> Map.put("reviewed_sha", old || assignment.reviewed_sha)
        end

      if is_map(result) and Map.has_key?(result, "attempt_id"), do: result, else: envelope(assignment, result)
    end

    assert {:ok, failed} = LocalRunner.run(context.runtime, "feature", %{context.config | executor: executor})
    assert failed["phase"] == "Failed"
    assert failed["error"] =~ "invalid or stale role execution result"
  end

  test "bounded rework fails clearly instead of looping", context do
    executor = fn assignment ->
      result =
        case assignment.role do
          "mastermind" ->
            plan()

          "developer" ->
            File.write!(Path.join(context.workspace, "implementation.txt"), "#{assignment.attempt_id}\n")
            %{"status" => "completed"}

          "reviewer" ->
            %{"status" => "changes_requested", "findings" => ["Still incorrect"]}
        end

      envelope(assignment, result)
    end

    assert {:ok, failed} =
             LocalRunner.run(context.runtime, "feature", %{context.config | executor: executor, max_reworks: 1})

    assert failed["phase"] == "Failed"
    assert failed["error"] == "rework limit exceeded for task task-1"
  end

  test "technical questions resolve automatically or stop only for a human-level decision", context do
    {:ok, mode} = Agent.start_link(fn -> :question end)
    on_exit(fn -> if Process.alive?(mode), do: Agent.stop(mode) end)

    executor = fn assignment ->
      result =
        case {assignment.role, assignment.phase, Agent.get(mode, & &1)} do
          {"mastermind", "Planning", _} ->
            plan()

          {"developer", _, :question} ->
            Agent.update(mode, fn _ -> :resolve end)
            %{"status" => "technical_question", "question" => "Which existing boundary applies?"}

          {"mastermind", "Resolving", :resolve} ->
            Agent.update(mode, fn _ -> :develop end)
            %{"status" => "resolved", "answer" => "Use the repository contract"}

          {"developer", _, :develop} ->
            File.write!(Path.join(context.workspace, "implementation.txt"), "resolved\n")
            %{"status" => "completed"}

          {"reviewer", _, _} ->
            %{"status" => "approved"}

          {"developer", _, _} ->
            %{"status" => "human_decision_required", "question" => "new product choice"}
        end

      envelope(assignment, result)
    end

    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", %{context.config | executor: executor})
    assert ready["phase"] == "ReadyForHuman"

    FeatureRunner.create(context.runtime, "human", "Approved attendance feature")

    human_executor = fn assignment ->
      result =
        case {assignment.role, assignment.phase} do
          {"mastermind", "Planning"} -> plan()
          {"developer", _} -> %{"status" => "technical_question", "question" => "Change the product contract?"}
          {"mastermind", "Resolving"} -> %{"status" => "human_decision_required", "question" => "Approve a new requirement?"}
        end

      envelope(assignment, result)
    end

    assert {:ok, waiting} = LocalRunner.run(context.runtime, "human", %{context.config | executor: human_executor})
    assert waiting["phase"] == "WaitingForHuman"
    assert waiting["question"] == "Approve a new requirement?"
  end

  test "final coordinator validation is required before ReadyForHuman", context do
    config = %{context.config | validator: fn _ -> {:error, :tests_failed} end}
    assert {:ok, failed} = LocalRunner.run(context.runtime, "feature", config)
    assert failed["phase"] == "Failed"
    assert failed["error"] =~ "tests_failed"
    refute Map.has_key?(failed, "final_sha")
  end

  test "prepared and recorded attempts recover without duplicate role execution", context do
    FeatureRunner.create(context.runtime, "captured", "Approved attendance feature")
    {:execute, captured} = FeatureRunner.prepare(context.runtime, "captured")
    assert {:captured, 0} = FeatureRunner.record(context.runtime, "captured", captured, plan())

    forbidden = %{context.config | executor: fn _ -> flunk("captured planner must not rerun") end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "captured", forbidden)

    FeatureRunner.create(context.runtime, "running", "Approved attendance feature")
    assert {:execute, _running} = FeatureRunner.prepare(context.runtime, "running")
    assert {:blocked, :role_execution_already_running} = LocalRunner.step(context.runtime, "running", forbidden)
  end

  test "executor errors, exceptions, throws, and malformed envelopes fail durably", context do
    executors = [
      fn _ -> {:error, :offline} end,
      fn _ -> raise "boom" end,
      fn _ -> throw(:interrupted) end,
      fn _ -> :malformed end
    ]

    for executor <- executors do
      id = "failure-#{System.unique_integer([:positive])}"
      FeatureRunner.create(context.runtime, id, "Approved attendance feature")
      assert {:ok, failed} = LocalRunner.step(context.runtime, id, %{context.config | executor: executor})
      assert failed["phase"] == "Failed"
    end

    FeatureRunner.create(context.runtime, "tuple-ok", "Approved attendance feature")
    tuple_executor = fn assignment -> {:ok, envelope(assignment, plan())} end

    assert {:ok, %{"phase" => "Implementing"}} =
             LocalRunner.step(context.runtime, "tuple-ok", %{context.config | executor: tuple_executor})
  end

  test "Developer cannot claim a SHA and Git capture failures become durable failures", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", planning)

    sha_executor = fn assignment -> envelope(assignment, %{"status" => "completed", "sha" => "model-sha"}) end
    assert {:ok, failed} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: sha_executor})
    assert failed["error"] =~ "attempted to control"

    FeatureRunner.create(context.runtime, "dirty", "Approved attendance feature")
    assert {:ok, _} = LocalRunner.step(context.runtime, "dirty", planning)
    File.write!(Path.join(context.workspace, "unexpected.txt"), "dirty\n")
    completed = fn assignment -> envelope(assignment, %{"status" => "completed"}) end
    assert {:ok, dirty_failed} = LocalRunner.step(context.runtime, "dirty", %{context.config | executor: completed})
    assert dirty_failed["error"] =~ "implementation capture blocked"
  end

  test "tampering with the exact reviewer checkout rejects the review", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "implementation\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, %{"phase" => "Reviewing"}} =
             LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})

    reviewer = fn assignment ->
      File.write!(Path.join(assignment.workspace, "implementation.txt"), "reviewer mutation\n")
      envelope(assignment, %{"status" => "approved"})
    end

    assert {:ok, failed} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: reviewer})
    assert failed["error"] =~ "review result rejected"
  end

  test "successful, malformed, raised, and dirty final validators are enforced", context do
    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", %{context.config | validator: fn _ -> :ok end})
    assert ready["validation"]["evidence"] == "coordinator validator passed"

    for {id, validator} <- [
          {"invalid-validator", fn _ -> :unexpected end},
          {"raised-validator", fn _ -> raise "validation crashed" end}
        ] do
      FeatureRunner.create(context.runtime, id, "Approved attendance feature")
      assert {:ok, failed} = LocalRunner.run(context.runtime, id, %{context.config | validator: validator})
      assert failed["phase"] == "Failed"
      assert failed["error"] =~ "validation failed"
    end

    FeatureRunner.create(context.runtime, "dirty-final", "Approved attendance feature")

    dirty_final_executor = fn assignment ->
      response = acceptance_executor(assignment, context.calls, context.workspace)

      if assignment.phase == "FinalReview" do
        File.write!(Path.join(context.workspace, "unexpected-final.txt"), "dirty\n")
      end

      response
    end

    assert {:ok, dirty_failed} =
             LocalRunner.run(context.runtime, "dirty-final", %{context.config | executor: dirty_final_executor})

    assert dirty_failed["error"] =~ "validation blocked"
  end

  test "config and autonomous step bounds reject invalid operation", context do
    assert {:blocked, :invalid_local_runner_config} = LocalRunner.run(context.runtime, "feature", :invalid)
    assert {:blocked, :invalid_local_runner_config} = LocalRunner.run(context.runtime, "feature", %{})

    assert {:blocked, :invalid_local_runner_config} =
             LocalRunner.run(context.runtime, "feature", Map.delete(context.config, :validator))

    assert {:blocked, :invalid_local_runner_config} =
             LocalRunner.run(
               context.runtime,
               "feature",
               %{context.config | output_root: Path.join(context.workspace, "role-output")}
             )

    assert {:blocked, :local_flow_step_limit_exceeded} =
             LocalRunner.run(context.runtime, "feature", Map.put(context.config, :max_steps, 1))
  end

  test "review assignment creation blocks when durable implementation identity is missing", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "implementation\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, reviewing} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})
    replace_state(context.runtime, "feature", Map.put(reviewing, "implementation_attempt_id", "missing"))

    assert {:blocked, :implementation_not_captured} =
             LocalRunner.run(context.runtime, "feature", context.config)
  end

  test "a durable review for a no-longer-current SHA cannot be applied", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "implementation\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, reviewing} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})
    {:execute, reviewer} = FeatureRunner.prepare(context.runtime, "feature")
    checkout = Path.join(context.config.reviewer_root, reviewer.attempt_id)

    assert {:ok, review} =
             Git.prepare_reviewer_checkout(context.runtime, %{
               attempt_id: reviewer.attempt_id,
               checkout_path: checkout,
               execution_id: reviewer.execution_id,
               feature_id: "feature",
               implementation_attempt_id: reviewing["implementation_attempt_id"],
               task_id: "task-1"
             })

    output =
      envelope(reviewer, "reviewer", "task-1", %{"status" => "approved"})
      |> Map.put("reviewed_sha", review.reviewed_sha)

    persist_output(context.runtime, reviewer, "reviewer", "task-1", output)
    replace_state(context.runtime, "feature", Map.put(reviewing, "head", "newer-authoritative-sha"))
    forbidden = %{context.config | executor: fn _ -> flunk("durable review must be reused") end}
    assert {:ok, failed} = LocalRunner.step(context.runtime, "feature", forbidden)
    assert failed["error"] == "review result is stale for the current implementation"
  end

  test "role output persistence is idempotent and conflicting output is fenced", context do
    executor = fn assignment ->
      output = envelope(assignment, plan())
      persist_output(context.runtime, assignment.execution, assignment.role, assignment.task_id, output)
      output
    end

    assert {:ok, %{"phase" => "Implementing"}} =
             LocalRunner.step(context.runtime, "feature", %{context.config | executor: executor})

    FeatureRunner.create(context.runtime, "conflict", "Approved attendance feature")

    conflict = fn assignment ->
      persisted = envelope(assignment, plan())
      persist_output(context.runtime, assignment.execution, assignment.role, assignment.task_id, persisted)
      envelope(assignment, %{"status" => "failed", "reason" => "different"})
    end

    assert_raise ArgumentError, "local role output already bound", fn ->
      LocalRunner.step(context.runtime, "conflict", %{context.config | executor: conflict})
    end
  end

  test "durable output is fenced if another execution has taken over the attempt", context do
    {:execute, execution} = FeatureRunner.prepare(context.runtime, "feature")
    output = envelope(execution, "mastermind", "planning", plan())
    persist_output(context.runtime, execution, "mastermind", "planning", output)

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "UPDATE attempts SET execution_id = 'replacement-execution' WHERE feature_id = 'feature' AND revision = 0"
      )
    end)

    assert {:blocked, :durable_role_output_identity_mismatch} =
             LocalRunner.step(context.runtime, "feature", context.config)
  end

  defp acceptance_executor(assignment, calls, developer_workspace) do
    result =
      case {assignment.role, assignment.phase, assignment.task_id} do
        {"mastermind", "Planning", _} ->
          plan()

        {"developer", _, task_id} ->
          count = Agent.get(calls, &Enum.count(&1, fn call -> match?({"developer", _, ^task_id, _}, call) end)) + 1
          File.write!(Path.join(developer_workspace, "implementation.txt"), "#{task_id}-v#{count}\n")
          Agent.update(calls, &[{"developer", assignment.phase, task_id, assignment.attempt_id} | &1])
          %{"status" => "completed"}

        {"reviewer", phase, task_id} ->
          assert git!(assignment.workspace, ["rev-parse", "HEAD"]) == assignment.reviewed_sha
          Agent.update(calls, &[{"reviewer", phase, task_id, assignment.reviewed_sha, assignment.workspace} | &1])

          task_one_reviews =
            Agent.get(calls, &Enum.count(&1, fn call -> match?({"reviewer", "Reviewing", "task-1", _, _}, call) end))

          if phase == "Reviewing" and task_id == "task-1" and task_one_reviews == 1,
            do: %{"status" => "changes_requested", "findings" => ["Correct task one"]},
            else: %{"status" => "approved"}
      end

    envelope(assignment, result)
  end

  defp plan do
    %{
      "status" => "planned",
      "tasks" => [
        %{"id" => "task-1", "scope" => "Implement first slice", "acceptance" => "First slice passes"},
        %{"id" => "task-2", "scope" => "Implement second slice", "acceptance" => "Second slice passes"}
      ]
    }
  end

  defp envelope(assignment, result) do
    %{
      "attempt_id" => assignment.attempt_id,
      "execution_id" => assignment.execution_id,
      "result" => result,
      "role" => assignment.role,
      "task_id" => assignment.task_id
    }
    |> maybe_reviewed_sha(assignment)
  end

  defp envelope(execution, role, task_id, result) do
    %{
      "attempt_id" => execution.attempt_id,
      "execution_id" => execution.execution_id,
      "result" => result,
      "role" => role,
      "task_id" => task_id
    }
  end

  defp maybe_reviewed_sha(envelope, %{role: "reviewer"} = assignment),
    do: Map.put(envelope, "reviewed_sha", assignment.reviewed_sha)

  defp maybe_reviewed_sha(envelope, _assignment), do: envelope

  defp persist_output(runtime, execution, role, task_id, envelope) do
    Store.transaction(runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO local_role_outputs (feature_id, revision, attempt_id, execution_id, role, task_id, result_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [execution.feature_id, execution.revision, execution.attempt_id, execution.execution_id, role, task_id, Jason.encode!(envelope)]
      )
    end)
  end

  defp replace_state(runtime, feature_id, state) do
    Store.transaction(runtime, fn db ->
      Store.execute(
        db,
        "UPDATE features SET state_json = ? WHERE id = ?",
        [Jason.encode!(Map.delete(state, "revision")), feature_id]
      )
    end)
  end

  defp git!(directory, args) do
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
