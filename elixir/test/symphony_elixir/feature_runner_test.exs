defmodule SymphonyElixir.FeatureRunnerTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Feature.{Effects, Fake, State, Store}
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
  defp develop(db, sha), do: step(db, "developer", %{"status" => "completed", "sha" => sha})
  defp approve(db, sha), do: step(db, "reviewer", %{"status" => "approved", "sha" => sha})
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
    assert final["phase"] == "ReadyForHuman"
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
    assert approve(db, "sha3")["phase"] == "ReadyForHuman"
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
    assert_raise RuntimeError, fn -> Runner.capture(db, "feature", &forbidden/2) end
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    # The NIF resource closes when the dead process releases its connection.
    :erlang.garbage_collect()
    assert plan(db)["phase"] == "Implementing"
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
    assert approve(db, "sha2")["phase"] == "ReadyForHuman"
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
        Store.execute(conn, "INSERT INTO attempts VALUES ('feature', 99, 'running', NULL)")
        Store.execute(conn, "INSERT INTO attempts VALUES ('missing-feature', 0, 'running', NULL)")
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

  defp attempts(db) do
    Store.transaction(db, &Store.execute(&1, "SELECT revision, status FROM attempts ORDER BY revision"))
  end
end
