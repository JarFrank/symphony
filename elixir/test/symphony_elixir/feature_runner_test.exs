defmodule SymphonyElixir.FeatureRunnerTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Feature.{Effects, Fake, Readiness, State, Store}
  alias SymphonyElixir.FeatureRunner, as: Runner

  setup do
    dir = Path.join(System.tmp_dir!(), "feature-core-#{System.unique_integer([:positive])}")
    db = Path.join(dir, "state.sqlite3")
    Store.init(db)
    Runner.create(db, "feature", "Approved specification")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: db}
  end

  defp step(db, role, result), do: Runner.step(db, "feature", Fake.executor(role, result))
  defp plan(db), do: step(db, "mastermind", Fake.plan())

  defp develop(db, sha) do
    state = step(db, "developer", %{"status" => "completed", "sha" => sha})
    validate(db, state, sha)
  end

  defp approve(db, sha) do
    state = step(db, "reviewer", %{"status" => "approved", "sha" => sha})

    if state["phase"] == "Validating" do
      state = validate(db, state, sha)
      if state["phase"] == "ReadinessCheck", do: Runner.complete_readiness(db, "feature", state["revision"]), else: state
    else
      state
    end
  end

  defp validate(db, state, sha) do
    Runner.apply_validation(db, "feature", state["revision"], %{
      "sha" => sha,
      "status" => "passed",
      "tree" => "tree-#{sha}",
      "diagnostic" => "fixture",
      "command" => "fixture",
      "working_directory" => "fixture",
      "started_at" => "start",
      "ended_at" => "end",
      "exit_status" => 0
    })
  end

  defp forbidden(_, _), do: flunk("executor must not run")

  defp reject(db, sha, extra \\ %{}) do
    step(db, "reviewer", Map.merge(%{"status" => "changes_requested", "sha" => sha, "findings" => ["Fix boundary condition"]}, extra))
  end

  test "two tasks are sequential, rework keeps identity, final approval stops execution", %{db: db} do
    assert Runner.get(db, "feature")["phase"] == "Planning"
    assert plan(db)["current"] == 0
    assert develop(db, "sha1")["phase"] == "Reviewing"
    assert reject(db, "sha1")["current"] == 0
    assert develop(db, "sha2")["current"] == 0
    accepted = approve(db, "sha2")
    assert accepted["current"] == 1
    assert Enum.map(accepted["tasks"], & &1["id"]) == ["task-1", "task-2"]
    assert hd(accepted["tasks"])["status"] == "accepted"
    develop(db, "sha3")
    assert approve(db, "sha3")["phase"] == "FinalReview"
    final = approve(db, "sha3")
    assert final["phase"] == "ReadinessCheck"
    assert Runner.step(db, "feature", &forbidden/2) == final
    assert Runner.get(db, "feature") == final
  end

  test "restart after developer result replays without invoking developer", %{db: db} do
    plan(db)

    pid =
      spawn(fn ->
        Runner.capture(db, "feature", Fake.executor("developer", %{"status" => "completed", "sha" => "sha1"}))
      end)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    state = Runner.step(db, "feature", &forbidden/2)
    state = validate(db, state, "sha1")
    assert state["phase"] == "Reviewing"
    assert state["head"] == "sha1"
    assert attempts(db) == [[0, "applied"], [1, "applied"]]
  end

  test "restart after review result advances exactly once", %{db: db} do
    plan(db)
    develop(db, "sha1")
    {:captured, revision} = Runner.capture(db, "feature", Fake.executor("reviewer", %{"status" => "approved", "sha" => "sha1"}))
    state = Runner.step(db, "feature", &forbidden/2)
    assert state["current"] == 1
    assert_raise ArgumentError, "stale revision", fn -> Runner.advance(db, "feature", revision) end
    assert Runner.get(db, "feature") == state
  end

  test "human wait survives restart and answer resumes same task and stage", %{db: db} do
    plan(db)
    step(db, "developer", %{"status" => "technical_question", "question" => "Contract?"})
    waiting = step(db, "mastermind", %{"status" => "human_decision_required", "question" => "Choose contract"})
    assert waiting["phase"] == "WaitingForHuman"
    assert Runner.step(db, "feature", &forbidden/2) == waiting
    answer = Runner.answer(db, "feature", waiting["revision"], "Keep approved contract")
    assert answer["phase"] == "Implementing"
    assert answer["current"] == 0
    assert_raise ArgumentError, "stale revision", fn -> Runner.answer(db, "feature", waiting["revision"], "Other") end
    assert develop(db, "sha1")["phase"] == "Reviewing"
  end

  test "technical resolution resumes review and final review rework returns to final", %{db: db} do
    plan(db)
    develop(db, "sha1")
    step(db, "reviewer", %{"status" => "technical_question", "question" => "Clarify"})
    assert step(db, "mastermind", %{"status" => "resolved", "answer" => "As specified"})["phase"] == "Reviewing"
    approve(db, "sha1")
    develop(db, "sha2")
    approve(db, "sha2")
    assert reject(db, "sha2", %{"task_id" => "task-1"})["current"] == 0
    develop(db, "sha3")
    assert approve(db, "sha3")["phase"] == "FinalReview"
    assert approve(db, "sha3")["phase"] == "ReadinessCheck"
  end

  test "invalid plan, stale SHA and explicit failures fail closed", %{db: db} do
    assert State.transition(State.new("s"), %{"status" => "planned", "tasks" => []})["phase"] == "Failed"
    plan(db)
    develop(db, "sha1")
    failed = approve(db, "wrong-sha")
    assert failed["phase"] == "Failed"
    assert Runner.step(db, "feature", &forbidden/2) == failed
    assert State.transition(State.new("s"), %{"status" => "failed", "reason" => "offline"})["error"] == "offline"
  end

  test "central readiness gate rejects stale validation, unresolved findings, and a mismatched FinalReview SHA" do
    for state <- [
          Map.put(ready_state(), "final_validation", Map.put(ready_state()["final_validation"], "sha", "older-sha")),
          Map.put(ready_state(), "findings", ["must fix"]),
          Map.put(ready_state(), "final_review_sha", "other-sha")
        ] do
      rejected = State.transition(state, %{"status" => "ready_for_human", "active_writer" => false})
      assert rejected["phase"] == "Failed"
    end
  end

  test "approved review with actionable findings is not acceptance" do
    state = %{
      "phase" => "Reviewing",
      "head" => "candidate",
      "validation" => %{"status" => "passed", "sha" => "candidate"},
      "tasks" => [%{"status" => "reviewing"}],
      "current" => 0
    }

    assert State.transition(state, %{"status" => "approved", "sha" => "candidate", "findings" => ["Fix compile error"]})["phase"] == "Failed"
  end

  test "developer capture records a task-review candidate without resolving it", %{db: db} do
    plan(db)
    develop(db, "sha1")
    reject(db, "sha1")

    repaired = develop(db, "sha2")
    assert [finding] = repaired["findings"]
    assert finding["source_role"] == "Reviewer"
    assert finding["status"] == "open"
    assert finding["addressed_by_sha"] == "sha2"
    assert is_map(finding["candidate_resolution"])
  end

  test "task Reviewer approval resolves only its addressed task finding", %{db: db} do
    plan(db)
    develop(db, "sha1")
    reject(db, "sha1")
    develop(db, "sha2")

    accepted = approve(db, "sha2")
    assert [%{"source_role" => "Reviewer", "status" => "resolved", "resolved_by_sha" => "sha2"}] = accepted["findings"]
  end

  test "task Reviewer approval does not resolve a FinalReview finding", %{db: db} do
    plan(db)
    develop(db, "sha1")
    approve(db, "sha1")
    develop(db, "sha2")
    approve(db, "sha2")
    reject(db, "sha2", %{"task_id" => "task-1"})
    develop(db, "sha3")

    task_approved = approve(db, "sha3")
    assert task_approved["phase"] == "FinalReview"
    assert [%{"source_role" => "FinalReview", "status" => "open", "addressed_by_sha" => "sha3"}] = task_approved["findings"]
  end

  test "FinalReview approval resolves its addressed final finding", %{db: db} do
    plan(db)
    develop(db, "sha1")
    approve(db, "sha1")
    develop(db, "sha2")
    approve(db, "sha2")
    reject(db, "sha2", %{"task_id" => "task-1"})
    develop(db, "sha3")
    approve(db, "sha3")

    final = approve(db, "sha3")
    assert [%{"source_role" => "FinalReview", "status" => "resolved", "resolved_by_sha" => "sha3"}] = final["findings"]
  end

  test "a validation finding resolves only after validation passes for its repair SHA", %{db: db} do
    plan(db)
    validating = step(db, "developer", %{"status" => "completed", "sha" => "sha1"})

    failed =
      Runner.apply_validation(db, "feature", validating["revision"], %{
        "sha" => "sha1",
        "status" => "failed",
        "diagnostic" => "compile error"
      })

    assert [%{"source_role" => "Validation", "status" => "open"}] = failed["findings"]

    repaired = develop(db, "sha2")
    assert [%{"source_role" => "Validation", "status" => "resolved", "resolved_by_sha" => "sha2"}] = repaired["findings"]
  end

  test "stale SHA and wrong task approval do not resolve findings" do
    finding = %{
      "finding_id" => "review:1",
      "source_role" => "Reviewer",
      "affected_task_id" => "task-2",
      "source_sha" => "old-sha",
      "addressed_by_sha" => "repair-sha",
      "status" => "open"
    }

    state = %{
      "phase" => "Reviewing",
      "head" => "repair-sha",
      "validation" => %{"status" => "passed", "sha" => "repair-sha"},
      "tasks" => [%{"id" => "task-1", "status" => "reviewing"}, %{"id" => "task-2", "status" => "pending"}],
      "current" => 0,
      "findings" => [finding]
    }

    wrong_task = State.transition(state, %{"status" => "approved", "sha" => "repair-sha"})
    assert [%{"status" => "open"}] = wrong_task["findings"]

    stale = State.transition(state, %{"status" => "approved", "sha" => "stale-sha"})
    assert stale["phase"] == "Failed"
    assert [%{"status" => "open"}] = stale["findings"]
  end

  test "invalid validation evidence and invalid readiness inputs fail closed", %{db: db} do
    assert Readiness.ready?(:invalid, false) == false
    assert Runner.apply_validation(db, "feature", 0, %{"status" => "unknown"})["phase"] == "Failed"
  end

  test "an ambiguous owned process blocks readiness while retaining the workspace claim", %{db: db} do
    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE features SET state_json = ? WHERE id = ?", [Jason.encode!(ready_state()), "feature"])

      Store.execute(
        conn,
        "INSERT INTO workspace_ownership (workspace, feature_id, expected_branch, initial_base_sha, expected_head_sha, adopted, claimed_at_ms) VALUES (?, ?, ?, ?, ?, 0, 0)",
        ["/workspace", "feature", "feature/test", "base-sha", "final-sha"]
      )

      Store.execute(
        conn,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status) VALUES (?, ?, ?, ?, ?, ?)",
        ["ambiguous-process", "attempt", "feature", 0, "symphony-feature-ambiguous-process.service", "ambiguous"]
      )
    end)

    blocked = Runner.complete_readiness(db, "feature", 0)
    refute blocked["phase"] == "ReadyForHuman"
    assert blocked["technical_blocker"] == "process termination is not confirmed"

    assert Store.read(db, fn conn ->
             Store.execute(conn, "SELECT feature_id FROM workspace_ownership WHERE workspace = ?", ["/workspace"])
           end) == [["feature"]]
  end

  test "duplicate feature does not overwrite state or specification", %{db: db} do
    state = plan(db)
    assert Runner.create(db, "feature", "Approved specification") == state
    assert_raise ArgumentError, fn -> Runner.create(db, "feature", "different spec") end
  end

  test "optimistic store update rejects stale writer and rolls back", %{db: db} do
    state = plan(db)

    assert_raise ArgumentError, "stale revision", fn ->
      Store.transaction(db, &Store.save(&1, "feature", 0, State.new("bad")))
    end

    assert Runner.get(db, "feature") == state
  end

  test "independent connection cannot start second executor; killed owner releases lock", %{db: db} do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Runner.capture(db, "feature", fn _, _ ->
          send(parent, :executing)

          receive do
            :continue -> Fake.plan()
          end
        end)
      end)

    assert_receive :executing
    assert Runner.get(db, "feature")["phase"] == "Planning"
    assert {:running, _} = Runner.capture(db, "feature", &forbidden/2)
    assert Runner.step(db, "feature", &forbidden/2) == Runner.get(db, "feature")
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # SQLite is available, but ownership remains fenced until a new VM recovers it.    :erlang.garbage_collect()    assert Runner.get(db, "feature")["phase"] == "Planning"
  end

  test "effect execution then crash is reconciled without duplicate execution", %{db: db} do
    {:ok, external} = Agent.start_link(fn -> %{} end)
    on_exit(fn -> if Process.alive?(external), do: Agent.stop(external) end)
    Effects.intent(db, "feature", "create-pr", %{"kind" => "create_pr"})

    reconcile = fn key, _ ->
      case Agent.get(external, &Map.fetch(&1, key)) do
        {:ok, result} -> {:found, result}
        :error -> :missing
      end
    end

    assert_raise RuntimeError, "lost confirmation", fn ->
      Effects.run(db, "feature", "create-pr", reconcile, fn key, _ ->
        Agent.update(external, &Map.put(&1, key, %{"pr" => 1}))
        raise "lost confirmation"
      end)
    end

    assert Effects.run(db, "feature", "create-pr", reconcile, &forbidden/2) == %{"pr" => 1}
    assert Effects.run(db, "feature", "create-pr", &forbidden/2, &forbidden/2) == %{"pr" => 1}
    assert_raise ArgumentError, fn -> Effects.intent(db, "feature", "create-pr", %{"kind" => "push"}) end
  end

  test "effect intent survives restart before execution", %{db: db} do
    Effects.intent(db, "feature", "commit", %{"kind" => "commit"})
    assert Effects.run(db, "feature", "commit", fn _, _ -> :missing end, fn _, _ -> %{"sha" => "fake"} end) == %{"sha" => "fake"}
  end

  test "stale pending effect cannot execute against a newer feature", %{db: db} do
    Effects.intent(db, "feature", "push", %{"kind" => "push"})
    plan(db)

    assert_raise ArgumentError, "stale effect revision", fn ->
      Effects.run(db, "feature", "push", fn _, _ -> :missing end, &forbidden/2)
    end
  end

  test "planning and final review questions resume their exact phase", %{db: db} do
    waiting = step(db, "mastermind", %{"status" => "human_decision_required", "question" => "Which behavior?"})
    assert Runner.answer(db, "feature", waiting["revision"], "Approved behavior")["phase"] == "Planning"
    plan(db)
    develop(db, "sha1")
    approve(db, "sha1")
    develop(db, "sha2")
    approve(db, "sha2")
    step(db, "reviewer", %{"status" => "technical_question", "question" => "Security contract?"})
    waiting = step(db, "mastermind", %{"status" => "human_decision_required", "question" => "Confirm contract"})
    assert Runner.step(db, "feature", &forbidden/2) == waiting
    assert Runner.answer(db, "feature", waiting["revision"], "Preserve contract")["phase"] == "FinalReview"
    assert approve(db, "sha2")["phase"] == "ReadinessCheck"
  end

  test "executor failure retains running attempt for retry", %{db: db} do
    assert_raise RuntimeError, "interrupted", fn ->
      Runner.capture(db, "feature", fn _, _ -> raise "interrupted" end)
    end

    assert attempts(db) == [[0, "running"]]
    assert plan(db)["phase"] == "Implementing"
  end

  test "invalid executor results fail durably without running the next task", %{db: db} do
    for result <- [
          :not_a_map,
          %{"status" => "planned"},
          %{"status" => "completed", "sha" => 1},
          %{"status" => "approved", "sha" => "base"},
          %{"status" => "planned", "tasks" => Fake.plan()["tasks"], "extra" => self()}
        ] do
      id = "invalid-#{System.unique_integer([:positive])}"
      Runner.create(db, id, "Approved specification")

      failed = Runner.step(db, id, Fake.executor("mastermind", result))

      assert failed["phase"] == "Failed"
      assert failed["error"] == "invalid role result"
      assert Store.transaction(db, &Store.execute(&1, "SELECT status FROM attempts WHERE feature_id = ?", [id])) == [["applied"]]
      assert Runner.step(db, id, &forbidden/2) == failed
    end
  end

  test "SQLite constraint error rolls back all writes in transaction", %{db: db} do
    assert_raise RuntimeError, fn ->
      Store.transaction(db, fn conn ->
        Store.execute(conn, "INSERT INTO attempts (feature_id, revision, status) VALUES ('feature', 99, 'running')")
        Store.execute(conn, "INSERT INTO attempts (feature_id, revision, status) VALUES ('missing-feature', 0, 'running')")
      end)
    end

    assert attempts(db) == []
    assert Runner.get(db, "feature")["revision"] == 0
  end

  test "completed external effect can reconcile after feature advances", %{db: db} do
    Effects.intent(db, "feature", "published", %{"kind" => "push"})

    assert_raise RuntimeError, "confirmation lost", fn ->
      Effects.run(db, "feature", "published", fn _, _ -> :missing end, fn _, _ -> raise "confirmation lost" end)
    end

    plan(db)
    assert Effects.run(db, "feature", "published", fn _, _ -> {:found, %{"sha" => "published"}} end, &forbidden/2) == %{"sha" => "published"}
  end

  test "developer failure is durable and does not cause automatic work", %{db: db} do
    plan(db)
    failed = step(db, "developer", %{"status" => "failed", "reason" => "fixture error"})
    assert failed["phase"] == "Failed"
    assert Runner.step(db, "feature", &forbidden/2) == failed
  end

  test "retry restores a failed Developer input with a fresh execution and retains history", %{db: db} do
    planned = plan(db)
    failed = step(db, "developer", %{"status" => "failed", "reason" => "infrastructure unavailable"})

    [[old_attempt, old_execution, "applied"]] =
      Store.read(db, &Store.execute(&1, "SELECT attempt_id, execution_id, status FROM attempts WHERE feature_id = ? AND revision = 1", ["feature"]))

    assert {:ok, restored} = Runner.retry(db, "feature")
    assert restored["phase"] == "Implementing"
    assert restored["tasks"] == planned["tasks"]
    assert restored["spec"] == planned["spec"]
    assert restored["revision"] == failed["revision"] + 1

    assert {:execute, execution} = Runner.prepare(db, "feature")
    refute execution.attempt_id == old_attempt
    refute execution.execution_id == old_execution
    assert execution.state_role == "developer"
    assert {:captured, _} = Runner.record(db, "feature", execution, %{"status" => "completed", "sha" => "retry-sha"})
    state = Runner.advance(db, "feature", execution.revision)
    assert validate(db, state, "retry-sha")["phase"] == "Reviewing"

    assert Store.read(db, &Store.execute(&1, "SELECT status FROM attempts WHERE feature_id = ? AND revision = 1", ["feature"])) == [["applied"]]
    assert Store.read(db, &Store.execute(&1, "SELECT COUNT(*) FROM attempts WHERE feature_id = ? AND revision = 0", ["feature"])) == [[1]]
  end

  test "retry restores Reviewer and FinalReview failures at their exact logical step", %{db: db} do
    plan(db)
    develop(db, "sha1")
    assert step(db, "reviewer", %{"status" => "failed", "reason" => "review service unavailable"})["phase"] == "Failed"
    assert {:ok, reviewing} = Runner.retry(db, "feature")
    assert reviewing["phase"] == "Reviewing"
    assert approve(db, "sha1")["phase"] == "Implementing"
    develop(db, "sha2")
    assert approve(db, "sha2")["phase"] == "FinalReview"
    assert step(db, "reviewer", %{"status" => "failed", "reason" => "final review unavailable"})["phase"] == "Failed"
    assert {:ok, final_review} = Runner.retry(db, "feature")
    assert final_review["phase"] == "FinalReview"
  end

  test "retry rejects non-failed and repeated requests without reopening twice", %{db: db} do
    assert {:error, :retry_not_recoverable} = Runner.retry(db, "feature")
    plan(db)
    step(db, "developer", %{"status" => "failed", "reason" => "retry once"})
    assert {:ok, restored} = Runner.retry(db, "feature")
    assert {:error, :retry_not_recoverable} = Runner.retry(db, "feature")
    assert Runner.get(db, "feature") == restored
  end

  test "retry fails closed for a corrupt failed input without changing the terminal state", %{db: db} do
    plan(db)
    failed = step(db, "developer", %{"status" => "failed", "reason" => "bad journal"})

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE attempts SET input_json = ? WHERE feature_id = ? AND revision = ?", ["{not-json", "feature", failed["revision"] - 1])
    end)

    assert {:error, :retry_not_recoverable} = Runner.retry(db, "feature")
    assert Runner.get(db, "feature") == failed
  end

  test "retry fails closed when the durable failed attempt is missing", %{db: db} do
    plan(db)
    failed = step(db, "developer", %{"status" => "failed", "reason" => "missing journal"})

    Store.transaction(db, fn conn ->
      Store.execute(conn, "DELETE FROM attempts WHERE feature_id = ? AND revision = ?", ["feature", failed["revision"] - 1])
    end)

    assert {:error, :retry_not_recoverable} = Runner.retry(db, "feature")
    assert Runner.get(db, "feature") == failed
  end

  test "a fresh runner process can resume the retry state without rerunning planning", %{db: db} do
    plan(db)
    step(db, "developer", %{"status" => "failed", "reason" => "temporary outage"})
    assert {:ok, %{"phase" => "Implementing"}} = Runner.retry(db, "feature")

    resumed = Runner.step(db, "feature", Fake.executor("developer", %{"status" => "completed", "sha" => "resumed-sha"}))
    assert validate(db, resumed, "resumed-sha")["phase"] == "Reviewing"
    assert Store.read(db, &Store.execute(&1, "SELECT COUNT(*) FROM attempts WHERE feature_id = ? AND revision = 0", ["feature"])) == [[1]]
  end

  test "an exhausted task repair budget does not consume another task's first repair", %{db: db} do
    state =
      task_review_state(
        [
          repair_task("task-a", 2),
          repair_task("task-b", 0)
        ],
        1
      )

    save_state(db, state)

    repaired =
      step(db, "reviewer", %{
        "status" => "changes_requested",
        "sha" => "task-b-sha",
        "findings" => ["Repair task b"],
        "repair_budget" => %{"task" => 2, "final" => 1}
      })

    assert repaired["phase"] == "Implementing"
    assert repaired["current"] == 1
    assert Enum.map(repaired["tasks"], & &1["repair_count"]) == [2, 1]
  end

  test "per-task repair counts survive a journal reopen", %{db: db} do
    state =
      task_review_state(
        [
          repair_task("task-a", 1),
          repair_task("task-b", 0)
        ],
        1
      )

    save_state(db, state)

    repaired =
      step(db, "reviewer", %{
        "status" => "changes_requested",
        "sha" => "task-b-sha",
        "findings" => ["Repair task b"],
        "repair_budget" => %{"task" => 2, "final" => 1}
      })

    assert Enum.map(repaired["tasks"], & &1["repair_count"]) == [1, 1]
    assert :ok = Store.init(db)
    assert Enum.map(Runner.get(db, "feature")["tasks"], & &1["repair_count"]) == [1, 1]
  end

  test "final repair budget is feature-level and FinalReview routes to its named task" do
    state =
      %{
        "phase" => "FinalReview",
        "head" => "final-sha",
        "validation" => %{"status" => "passed", "sha" => "final-sha"},
        "tasks" => [repair_task("task-a", 2), repair_task("task-b", 0)],
        "current" => 1,
        "findings" => [],
        "final_repair_count" => 0
      }

    repaired =
      State.transition(state, %{
        "status" => "changes_requested",
        "sha" => "final-sha",
        "task_id" => "task-b",
        "findings" => ["Repair final integration"],
        "repair_budget" => %{"task" => 0, "final" => 1}
      })

    assert repaired["phase"] == "Implementing"
    assert repaired["current"] == 1
    assert repaired["final_repair_count"] == 1
    assert Enum.map(repaired["tasks"], & &1["repair_count"]) == [2, 0]

    exhausted =
      repaired
      |> Map.merge(%{"phase" => "FinalReview", "validation" => %{"status" => "passed", "sha" => "final-sha"}})
      |> State.transition(%{
        "status" => "changes_requested",
        "sha" => "final-sha",
        "task_id" => "task-b",
        "findings" => ["One more final repair"],
        "repair_budget" => %{"task" => 99, "final" => 1}
      })

    assert exhausted["phase"] == "ValidationBlocked"
    assert exhausted["final_repair_count"] == 1
    assert Enum.map(exhausted["tasks"], & &1["repair_count"]) == [2, 0]
  end

  defp attempts(db) do
    Store.transaction(db, &Store.execute(&1, "SELECT revision, status FROM attempts ORDER BY revision"))
  end

  defp save_state(db, state) do
    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE features SET state_json = ? WHERE id = ?", [Jason.encode!(Map.delete(state, "revision")), "feature"])
    end)
  end

  defp task_review_state(tasks, current) do
    %{
      "phase" => "Reviewing",
      "head" => "task-b-sha",
      "validation" => %{"status" => "passed", "sha" => "task-b-sha"},
      "tasks" => tasks,
      "current" => current,
      "findings" => [],
      "final_repair_count" => 0
    }
  end

  defp repair_task(id, repair_count) do
    %{
      "id" => id,
      "status" => "accepted",
      "repair_count" => repair_count,
      "rework_count" => repair_count
    }
  end

  defp ready_state do
    %{
      "phase" => "ReadinessCheck",
      "tasks" => [%{"status" => "accepted"}, %{"status" => "accepted"}],
      "final_sha" => "final-sha",
      "final_review_sha" => "final-sha",
      "final_review" => %{"status" => "approved", "sha" => "final-sha"},
      "final_validation" => %{"status" => "passed", "sha" => "final-sha"},
      "findings" => [],
      "validation_blocker" => nil,
      "technical_blocker" => nil,
      "question" => nil
    }
  end

  test "stale execution result is fenced after recovery takes ownership", %{db: db} do
    {:execute, old_execution} = Runner.prepare(db, "feature")

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE attempts SET execution_owner = 'terminated-vm' WHERE feature_id = ? AND revision = ?", ["feature", old_execution.revision])
    end)

    {:execute, current_execution} = Runner.prepare(db, "feature")
    refute old_execution.execution_id == current_execution.execution_id

    assert_raise ArgumentError, "stale execution", fn ->
      Runner.record(db, "feature", old_execution, Fake.plan())
    end

    assert {:captured, 0} = Runner.record(db, "feature", current_execution, Fake.plan())
    assert Runner.advance(db, "feature", 0)["phase"] == "Implementing"
  end

  test "replacement process retains the logical attempt identity", %{db: db} do
    {:execute, first} = Runner.prepare(db, "feature")

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE attempts SET execution_owner = 'dead-coordinator' WHERE feature_id = ? AND revision = ?", ["feature", first.revision])
    end)

    {:execute, replacement} = Runner.prepare(db, "feature")
    assert replacement.attempt_id == first.attempt_id
    refute replacement.execution_id == first.execution_id

    assert Store.read(db, &Store.execute(&1, "SELECT attempt_id, execution_id FROM attempts WHERE feature_id = ? AND revision = ?", ["feature", first.revision])) ==
             [[replacement.attempt_id, replacement.execution_id]]
  end

  test "recovery reopens the selected task without deleting durable history", %{db: db} do
    plan(db)
    before = Runner.get(db, "feature")

    assert {:ok, recovered} =
             Runner.recover_task(db, "feature", before["revision"], "task-1", "compile defect")

    assert recovered["phase"] == "Implementing"
    assert recovered["current"] == 0
    assert recovered["head"] == before["head"]
    assert [%{"source_role" => "Recovery", "status" => "open"}] = recovered["findings"]
    assert {:error, :recovery_not_applicable} = Runner.recover_task(db, "feature", before["revision"], "task-1", "again")
  end
end
