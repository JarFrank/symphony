defmodule SymphonyElixir.Feature.LocalRunnerTest do
  use ExUnit.Case, async: false

  alias Exqlite.Sqlite3
  alias SymphonyElixir.Feature.{Effects, Git, LocalRunner, State, Store, Validation, WorkspaceLock}
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
      SymphonyElixir.FeatureTestCleanup.cleanup(root)
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

  @tag :acceptance_reliability
  test "full local flow captures exact SHAs, requires fresh rework review, and reaches ReadyForHuman", context do
    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", context.config)
    assert ready["phase"] == "ReadyForHuman"
    assert ready["final_sha"] == git!(context.workspace, ["rev-parse", "HEAD"])
    assert ready["validation"]["status"] == "passed"
    assert ready["validation"]["diagnostic"] == "fixture validation"
    assert ready["validation"]["sha"] == ready["final_sha"]
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

  test "LocalRunner omits allowed_paths for ordinary whole-repository feature work", context do
    config = Map.delete(context.config, :allowed_paths)

    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", config)
    assert ready["phase"] == "ReadyForHuman"
    assert ready["final_sha"] == git!(context.workspace, ["rev-parse", "HEAD"])
  end

  test "public State and FeatureRunner transitions cannot turn synthetic readiness state into ReadyForHuman", context do
    state = rearm_readiness(context)

    assert State.transition(state, %{"status" => "ready_for_human", "active_writer" => false})["phase"] == "Failed"

    direct = FeatureRunner.complete_readiness(context.runtime, "feature", state["revision"])
    refute direct["phase"] == "ReadyForHuman"

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "DELETE FROM reviewer_checkouts WHERE feature_id = ?", ["feature"])
      Store.execute(db, "DELETE FROM implementation_commits WHERE feature_id = ?", ["feature"])
    end)

    blocked = finalize(context)
    refute blocked["phase"] == "ReadyForHuman"
    assert blocked["technical_blocker"]["reason"] =~ "final_capture_missing_or_stale"
  end

  test "final readiness requires exact durable capture, validation, and review records", context do
    for {sql, expected} <- [
          {"UPDATE implementation_commits SET sha = 'stale-sha' WHERE feature_id = 'feature'", "final_capture_missing_or_stale"},
          {"DELETE FROM validation_evidence WHERE feature_id = 'feature'", "final_validation_missing_or_stale"},
          {"UPDATE validation_evidence SET sha = 'stale-sha' WHERE feature_id = 'feature'", "final_validation_missing_or_stale"},
          {"UPDATE validation_evidence SET tree = 'wrong-tree' WHERE feature_id = 'feature'", "final_validation_missing_or_stale"},
          {"DELETE FROM reviewer_checkouts WHERE feature_id = 'feature'", "review_assignment_missing_or_stale"},
          {"UPDATE reviewer_checkouts SET reviewed_sha = 'stale-sha' WHERE feature_id = 'feature'", "review_assignment_missing_or_stale"}
        ] do
      state = rearm_readiness(context)

      Store.transaction(context.runtime, fn db ->
        Store.execute(db, sql)
      end)

      blocked = finalize(context, state)
      refute blocked["phase"] == "ReadyForHuman"
      assert blocked["technical_blocker"]["reason"] =~ expected
      reset_feature_fixture(context)
    end
  end

  @tag :acceptance_reliability
  test "final readiness rejects unconfirmed validation and active process executions", context do
    state = rearm_readiness(context)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'ambiguous' WHERE feature_id = ? AND execution_kind = 'validation'", ["feature"])
    end)

    blocked = finalize(context, state)
    refute blocked["phase"] == "ReadyForHuman"

    reset_feature_fixture(context)
    state = rearm_readiness(context)
    active_execution_id = "active-finalization-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, execution_kind) VALUES (?, ?, ?, 0, ?, 'running', 'role')",
        [active_execution_id, active_execution_id, "feature", "symphony-feature-#{active_execution_id}.service"]
      )
    end)

    refute finalize(context, state)["phase"] == "ReadyForHuman"
  end

  @tag :acceptance_reliability
  test "foreign live HEAD blocks readiness and retains the workspace until controlled HEAD is restored", context do
    state = rearm_readiness(context)
    final_sha = state["final_sha"]
    File.write!(Path.join(context.workspace, "foreign.txt"), "foreign\n")
    git!(context.workspace, ["add", "foreign.txt"])
    git!(context.workspace, ["commit", "-m", "foreign head"])

    blocked = finalize(context, state)
    refute blocked["phase"] == "ReadyForHuman"
    assert blocked["technical_blocker"]["reason"] =~ "workspace_integrity_blocker"
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT feature_id FROM workspace_ownership WHERE feature_id = 'feature'") end) == [["feature"]]

    git!(context.workspace, ["reset", "--hard", final_sha])
    ready = finalize(context)
    assert ready["phase"] == "ReadyForHuman"
    assert :ok = LocalRunner.release_workspace(context.runtime, "feature", readiness_context(context))
  end

  test "workspace claim and host lock ownership are final readiness invariants; release follows durable readiness", context do
    state = rearm_readiness(context)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE workspace_ownership SET expected_head_sha = 'foreign-sha' WHERE feature_id = ?", ["feature"])
    end)

    refute finalize(context, state)["phase"] == "ReadyForHuman"

    reset_feature_fixture(context)
    state = rearm_readiness(context)
    assert :ok = WorkspaceLock.release(context.workspace, context.runtime, "feature")
    other_runtime = Path.join(context.root, "other-lock.sqlite3")
    assert :ok = Store.init(other_runtime)
    assert :ok = WorkspaceLock.acquire(context.workspace, other_runtime, "other")
    refute finalize(context, state)["phase"] == "ReadyForHuman"

    assert :ok = WorkspaceLock.release(context.workspace, other_runtime, "other")
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime, "feature")
    ready = finalize(context)
    assert ready["phase"] == "ReadyForHuman"
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT feature_id FROM workspace_ownership WHERE feature_id = 'feature'") end) == [["feature"]]
    assert :ok = LocalRunner.release_workspace(context.runtime, "feature", readiness_context(context))
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT feature_id FROM workspace_ownership WHERE feature_id = 'feature'") end) == []
  end

  test "records the real clean baseline and exposes it through read-only status", context do
    sha = git!(context.workspace, ["rev-parse", "HEAD"])
    revision = FeatureRunner.get(context.runtime, "feature")["revision"]

    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", context.config)
    state = FeatureRunner.get(context.runtime, "feature")
    assert state["initial_base_sha"] == sha
    assert state["expected_head_sha"] == sha

    assert {:ok, status} = LocalRunner.status(context.runtime, "feature")
    assert status.role == "developer"
    assert status.task_id == "task-1"
    assert status.sha == sha
    assert FeatureRunner.get(context.runtime, "feature")["revision"] == revision + 1
  end

  test "workspace claim survives an idle coordinator and a coordinator restart", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    Store.init(context.runtime)
    FeatureRunner.create(context.runtime, "second", "other approved feature")
    assert {:blocked, :workspace_already_owned} = LocalRunner.step(context.runtime, "second", context.config)
  end

  @tag :acceptance_reliability
  test "a second journal is denied before baseline adoption can mutate Git", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    before = git!(context.workspace, ["rev-parse", "HEAD"])
    File.write!(Path.join(context.workspace, "unowned-change.txt"), "must not be committed\n")

    other_runtime = Path.join(context.root, "other-runtime/state.sqlite3")
    Store.init(other_runtime)
    FeatureRunner.create(other_runtime, "other-feature", "Approved specification")

    other_config =
      Map.merge(context.config, %{
        output_root: Path.join(context.root, "other-output"),
        reviewer_root: Path.join(context.root, "other-reviewers"),
        baseline_adoption: :commit,
        executor: fn assignment -> envelope(assignment, plan()) end
      })

    assert {:blocked, :workspace_owned_by_another_journal} = LocalRunner.step(other_runtime, "other-feature", other_config)
    assert git!(context.workspace, ["rev-parse", "HEAD"]) == before
    assert git!(context.workspace, ["status", "--porcelain"]) =~ "unowned-change.txt"
  end

  test "explicit release permits a later feature to claim the workspace", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
    discard_workspace_claim(context, "feature")

    FeatureRunner.create(context.runtime, "second", "other approved feature")
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "second", planning)
  end

  test "successful Codex session identity is persisted in LocalRunner status", context do
    executor = fn assignment ->
      envelope(assignment, plan())
      |> Map.put("codex_session_id", "fixture-codex-session")
    end

    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: executor})
    assert {:ok, status} = LocalRunner.status(context.runtime, "feature")
    # The planner execution is historical once its output has been applied;
    # status must not advertise that old Codex session as the next role's one.
    assert status.session_id == nil
    assert FeatureRunner.get(context.runtime, "feature")["status"]["codex_session_id"] == "fixture-codex-session"
  end

  test "workspace release refuses an active execution and reports missing ownership", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    {:execute, _execution} = FeatureRunner.prepare(context.runtime, "feature")
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "DELETE FROM workspace_ownership WHERE feature_id = ?", ["feature"])
    end)

    assert {:blocked, :workspace_ownership_missing} = LocalRunner.step(context.runtime, "feature", context.config)
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
  end

  test "an ambiguous process execution keeps the workspace claimed until termination is confirmed", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status) VALUES (?, ?, ?, ?, ?, ?)",
        ["ambiguous-release", "attempt", "feature", 1, "symphony-feature-ambiguous-release.service", "ambiguous"]
      )
    end)

    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT feature_id FROM workspace_ownership WHERE feature_id = ?", ["feature"])
           end) == [["feature"]]

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'terminated' WHERE execution_id = ?", ["ambiguous-release"])
    end)

    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
  end

  test "workspace ownership mismatch fails closed", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    FeatureRunner.create(context.runtime, "other", "other feature")

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE workspace_ownership SET feature_id = ?, expected_head_sha = ? WHERE workspace = ?", ["other", "wrong", context.workspace])
    end)

    assert {:blocked, :workspace_ownership_mismatch} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "legacy baseline adoption reuses the feature's existing claim", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, implementing} = LocalRunner.step(context.runtime, "feature", planning)

    legacy =
      implementing
      |> Map.put("initial_base_sha", nil)
      |> Map.put("expected_head_sha", nil)

    replace_state(context.runtime, "feature", legacy)

    completed = fn assignment -> envelope(assignment, %{"status" => "completed"}) end
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: completed})
  end

  test "legacy non-base historical HEAD is retained and a moved workspace is not adopted", context do
    File.write!(Path.join(context.workspace, "historical.txt"), "historical\n")
    git!(context.workspace, ["add", "historical.txt"])
    git!(context.workspace, ["commit", "-m", "historical head"])
    historical = git!(context.workspace, ["rev-parse", "HEAD"])
    git!(context.workspace, ["commit", "--allow-empty", "-m", "foreign current head"])

    legacy =
      FeatureRunner.get(context.runtime, "feature")
      |> Map.put("head", historical)
      |> Map.put("initial_base_sha", nil)
      |> Map.put("expected_head_sha", nil)

    replace_state(context.runtime, "feature", legacy)
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, state} = LocalRunner.step(context.runtime, "feature", planning)
    assert state["head"] == historical
    assert state["initial_base_sha"] == historical
    assert {:blocked, :workspace_integrity_blocker} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "an unverifiable legacy historical HEAD fails closed", context do
    legacy =
      FeatureRunner.get(context.runtime, "feature")
      |> Map.put("head", "not-a-git-commit")
      |> Map.put("initial_base_sha", nil)
      |> Map.put("expected_head_sha", nil)

    replace_state(context.runtime, "feature", legacy)
    assert {:blocked, :legacy_authoritative_head_unverified} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "terminal cleanup retains its claim when a process is still unconfirmed", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, state} = LocalRunner.step(context.runtime, "feature", planning)
    replace_state(context.runtime, "feature", Map.put(state, "phase", "ReadyForHuman"))

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status) VALUES (?, ?, ?, ?, ?, ?)",
        ["terminal-ambiguous", "attempt", "feature", 1, "symphony-feature-terminal-ambiguous.service", "ambiguous"]
      )
    end)

    assert {:ok, %{"phase" => "ReadyForHuman"}} = LocalRunner.step(context.runtime, "feature", context.config)

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT feature_id FROM workspace_ownership WHERE feature_id = ?", ["feature"])
           end) == [["feature"]]
  end

  test "a second running attempt blocks the developer workspace before execution", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    FeatureRunner.create(context.runtime, "other", "Approved specification")
    assert {:execute, _} = FeatureRunner.prepare(context.runtime, "other")
    assert {:blocked, :unknown_active_workspace_execution} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "blocked explicit baseline adoption is returned without a fallback claim", context do
    File.write!(Path.join(context.workspace, "dirty.txt"), "dirty\n")
    git!(context.workspace, ["config", "--local", "--unset", "user.name"])
    git!(context.workspace, ["config", "--local", "--unset", "user.email"])

    assert {:blocked, :git_author_identity_unavailable} =
             LocalRunner.step(context.runtime, "feature", Map.put(context.config, :baseline_adoption, :commit))
  end

  test "a claim cannot reconcile to a missing coordinator SHA", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, state} = LocalRunner.step(context.runtime, "feature", planning)
    replace_state(context.runtime, "feature", Map.put(state, "expected_head_sha", nil))
    assert {:blocked, :workspace_ownership_mismatch} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "review assignment requires passed validation before it reserves a reviewer", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, state} = LocalRunner.step(context.runtime, "feature", planning)
    reviewing = state |> Map.put("phase", "Reviewing") |> Map.put("validation", nil)
    replace_state(context.runtime, "feature", reviewing)
    assert {:blocked, :review_assignment_requires_passed_validation} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "terminal cleanup retains its claim while an attempt remains active", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, state} = LocalRunner.step(context.runtime, "feature", planning)
    assert {:execute, _} = FeatureRunner.prepare(context.runtime, "feature")
    replace_state(context.runtime, "feature", Map.put(state, "phase", "ReadyForHuman"))
    assert {:ok, %{"phase" => "ReadyForHuman"}} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "an idle terminal run reports no progress instead of inventing another transition", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, state} = LocalRunner.step(context.runtime, "feature", planning)
    replace_state(context.runtime, "feature", Map.put(state, "phase", "ReadyForHuman"))
    assert {:blocked, :local_flow_made_no_progress} = LocalRunner.run(context.runtime, "feature", context.config)
  end

  test "a crash-window claim mismatch reconciles only the durable coordinator SHA", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "reconcile candidate\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, reviewing} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})
    initial = reviewing["initial_base_sha"]
    candidate = reviewing["expected_head_sha"]

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE workspace_ownership SET expected_head_sha = ? WHERE feature_id = ?", [initial, "feature"])
    end)

    reviewer = fn assignment -> envelope(assignment, %{"status" => "approved"}) |> Map.put("reviewed_sha", assignment.reviewed_sha) end
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: reviewer})

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT expected_head_sha FROM workspace_ownership WHERE feature_id = ?", ["feature"])
           end) == [[candidate]]
  end

  test "a foreign HEAD is never reconciled into a stale claim", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "foreign-head guard\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, reviewing} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})
    initial = reviewing["initial_base_sha"]
    candidate = reviewing["expected_head_sha"]

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "UPDATE workspace_ownership SET expected_head_sha = ? WHERE feature_id = ?", [initial, "feature"])
    end)

    git!(context.workspace, ["commit", "--allow-empty", "-m", "foreign head"])
    assert {:blocked, :workspace_ownership_mismatch} = LocalRunner.step(context.runtime, "feature", context.config)

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT expected_head_sha FROM workspace_ownership WHERE feature_id = ?", ["feature"])
           end) == [[initial]]

    assert candidate != git!(context.workspace, ["rev-parse", "HEAD"])
  end

  test "invalid baseline adoption policy is rejected before touching the workspace", context do
    assert {:blocked, :invalid_local_runner_config} =
             LocalRunner.step(context.runtime, "feature", Map.put(context.config, :baseline_adoption, :unexpected))

    assert FeatureRunner.get(context.runtime, "feature")["initial_base_sha"] == nil
  end

  test "status is unavailable for an unknown runtime" do
    runtime = "/tmp/no-such-feature-runtime.sqlite3"
    File.rm(runtime)
    assert {:blocked, :feature_status_unavailable} = LocalRunner.status(runtime, "missing")
  end

  @tag :acceptance_reliability
  test "an incompatible runtime fails before workspace ownership or Git mutation", context do
    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "DELETE FROM runtime_metadata")
    end)

    File.write!(Path.join(context.workspace, "would-be-adopted.txt"), "forensic workspace state\n")
    before_runtime = File.read!(context.runtime)
    before_head = git!(context.workspace, ["rev-parse", "HEAD"])
    config = Map.merge(context.config, %{baseline_adoption: :commit, executor: fn _ -> flunk("model must not start") end})

    assert {:blocked, :incompatible_runtime_version} = LocalRunner.step(context.runtime, "feature", config)
    assert {:blocked, :incompatible_runtime_version} = LocalRunner.status(context.runtime, "feature")
    assert git!(context.workspace, ["rev-parse", "HEAD"]) == before_head
    assert git!(context.workspace, ["status", "--porcelain"]) =~ "would-be-adopted.txt"
    assert raw_rows(context.runtime, "SELECT feature_id FROM workspace_ownership") == []
    assert File.read!(context.runtime) == before_runtime
  end

  test "dirty initial workspace and a second active writer fail closed", context do
    File.write!(Path.join(context.workspace, "unadopted.txt"), "dirty\n")
    assert {:blocked, :dirty_workspace_requires_explicit_baseline_adoption} = LocalRunner.step(context.runtime, "feature", context.config)
    File.rm!(Path.join(context.workspace, "unadopted.txt"))

    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: fn assignment -> envelope(assignment, plan()) end})
    assert {:execute, _} = FeatureRunner.prepare(context.runtime, "feature")
    FeatureRunner.create(context.runtime, "second", "other approved feature")
    assert {:blocked, :workspace_already_owned} = LocalRunner.step(context.runtime, "second", context.config)
  end

  test "explicit adoption commits the dirty baseline before any role runs", context do
    File.write!(Path.join(context.workspace, "adopted.txt"), "user baseline\n")
    config = context.config |> Map.put(:baseline_adoption, :commit) |> Map.put(:executor, fn assignment -> envelope(assignment, plan()) end)

    assert {:ok, %{"phase" => "Implementing"} = state} = LocalRunner.step(context.runtime, "feature", config)
    assert state["initial_base_sha"] == git!(context.workspace, ["rev-parse", "HEAD"])
    assert File.read!(Path.join(context.workspace, "adopted.txt")) == "user baseline\n"
    assert git!(context.workspace, ["status", "--porcelain"]) == ""
  end

  test "unexpected HEAD before and during Developer execution is an integrity blocker", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", planning)
    git!(context.workspace, ["commit", "--allow-empty", "-m", "external head change"])
    assert {:blocked, :workspace_integrity_blocker} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "Developer commit is detected after execution and never adopted", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, _} = LocalRunner.step(context.runtime, "feature", planning)

    committing_developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "unauthorized commit\n")
      git!(context.workspace, ["commit", "-am", "developer bypass"])
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, %{"phase" => "Failed", "error" => error}} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: committing_developer})
    assert error =~ "implementation capture blocked"
  end

  test "LocalRunner adds caller protections without replacing default protections", context do
    config = Map.put(context.config, :protected_paths, [".github/workflows/**"])

    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", config)
    assert ready["phase"] == "ReadyForHuman"
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

    assert failed["phase"] == "ValidationBlocked"
    assert failed["validation_blocker"]["status"] == "repair_exhausted"
    assert Enum.any?(failed["findings"], &(&1["status"] == "open"))
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

  test "final executable validation failure returns the candidate to Developer repair", context do
    {:ok, failed_final} = Agent.start_link(fn -> false end)
    on_exit(fn -> if Process.alive?(failed_final), do: Agent.stop(failed_final) end)

    validator = fn context ->
      fail? = context.purpose == "final" and Agent.get_and_update(failed_final, fn seen -> {not seen, true} end)
      if fail?, do: {:error, :tests_failed}, else: {:ok, "fixture validation"}
    end

    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", %{context.config | validator: validator})
    assert ready["phase"] == "ReadyForHuman"
    assert ready["final_validation"]["status"] == "passed"
  end

  test "compiler failure repairs before any Reviewer starts", context do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    executor = fn assignment ->
      Agent.update(calls, &[{assignment.role, assignment.phase} | &1])

      case assignment.role do
        "mastermind" ->
          envelope(assignment, plan())

        "developer" ->
          File.write!(Path.join(context.workspace, "implementation.txt"), "broken\n")
          envelope(assignment, %{"status" => "completed"})

        "reviewer" ->
          flunk("Reviewer must not start after compiler failure")
      end
    end

    config = %{context.config | executor: executor, validator: fn _ -> {:error, %{exit_status: 1, output: "compile error"}} end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", config)
    assert {:ok, %{"phase" => "Implementing"} = state} = LocalRunner.step(context.runtime, "feature", config)

    assert [finding] = state["findings"]
    assert finding["message"] == "Executable validation failed: compile error"
    assert finding["status"] == "open"
    refute Enum.any?(Agent.get(calls, & &1), &match?({"reviewer", _}, &1))
  end

  test "unavailable validation environment stays blocked and never starts Reviewer", context do
    validator = fn _ -> {:blocked, :compiler_not_installed} end

    executor = fn assignment ->
      case assignment.role do
        "mastermind" ->
          envelope(assignment, plan())

        "developer" ->
          File.write!(Path.join(context.workspace, "implementation.txt"), "candidate\n")
          envelope(assignment, %{"status" => "completed"})

        "reviewer" ->
          flunk("Reviewer requires passed validation")
      end
    end

    assert {:ok, blocked} = LocalRunner.run(context.runtime, "feature", %{context.config | executor: executor, validator: validator})
    assert blocked["phase"] == "ValidationBlocked"
    assert blocked["validation"]["status"] == "blocked"
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT status FROM validation_evidence WHERE feature_id = ?", ["feature"]) end) == [["blocked"]]
  end

  test "validator source mutation invalidates its evidence", context do
    validator = fn %{workspace: workspace} ->
      File.write!(Path.join(workspace, "implementation.txt"), "mutated by validator\n")
      :ok
    end

    assert {:ok, blocked} = LocalRunner.run(context.runtime, "feature", %{context.config | validator: validator})
    assert blocked["phase"] == "ValidationBlocked"
    assert blocked["validation"]["diagnostic"] =~ "validator_modified_sources"
    assert File.read!(Path.join(context.workspace, "implementation.txt")) != "mutated by validator\n"
  end

  test "validation evidence is durable, reusable, and validates its target", context do
    target = %{
      key: "durable-validation",
      purpose: "review",
      repository: context.workspace,
      sha: git!(context.workspace, ["rev-parse", "HEAD"])
    }

    assert :missing == Validation.evidence(context.runtime, "feature", target.key)

    checkout = Path.join(context.config.reviewer_root, "direct-validation")

    assert {:ok, evidence} =
             Validation.run(context.runtime, "feature", target, fn _ -> {:ok, %{command: "mix test", output: "green"}} end, checkout)

    assert evidence["command"] == "mix test"
    assert evidence["diagnostic"] == "green"
    assert {:ok, ^evidence} = Validation.evidence(context.runtime, "feature", target.key)

    assert {:ok, ^evidence} =
             Validation.run(context.runtime, "feature", target, fn _ -> flunk("durable evidence must be reused") end, checkout)

    assert {:blocked, :invalid_validation_target} =
             Validation.run(context.runtime, "feature", %{}, fn _ -> :ok end, checkout)

    assert {:blocked, :invalid_validation_target} =
             Validation.run(context.runtime, "feature", :invalid, fn _ -> :ok end, checkout)
  end

  @tag :acceptance_reliability
  test "validation reuses only its own crash-window checkout", context do
    sha = git!(context.workspace, ["rev-parse", "HEAD"])
    {:ok, %{tree: tree}} = Git.candidate_identity(context.workspace, sha)
    checkout = Path.join(context.config.reviewer_root, "recovered-validation")
    operation_key = "validation-crash-window"
    effect_key = "validation_checkout:#{operation_key}"

    intent = %{
      "checkout_path" => Path.expand(checkout),
      "feature_id" => "feature",
      "operation" => "validation_checkout",
      "operation_key" => effect_key,
      "repository" => Path.expand(context.workspace),
      "sha" => sha,
      "tree" => tree
    }

    assert :ok = Effects.intent(context.runtime, "feature", effect_key, intent)
    File.mkdir_p!(Path.dirname(checkout))
    assert {:ok, ^checkout} = Git.prepare_validation_checkout(context.workspace, sha, checkout)

    target = %{key: "recovered-validation", purpose: "review", repository: context.workspace, sha: sha}

    assert {:ok, %{"status" => "passed"}} =
             Validation.run(context.runtime, "feature", target, fn _ -> :ok end, checkout, 1_000, %{operation_key: operation_key})

    refute File.exists?(checkout)
  end

  test "validation refuses an existing checkout with no durable ownership", context do
    sha = git!(context.workspace, ["rev-parse", "HEAD"])
    checkout = Path.join(context.config.reviewer_root, "foreign-validation")
    File.mkdir_p!(Path.dirname(checkout))
    assert {:ok, ^checkout} = Git.prepare_validation_checkout(context.workspace, sha, checkout)

    target = %{key: "foreign-validation", purpose: "review", repository: context.workspace, sha: sha}

    assert {:blocked, :reviewer_checkout_path_unsafe} =
             Validation.run(context.runtime, "feature", target, fn _ -> :ok end, checkout, 1_000, %{operation_key: "foreign-validation"})
  end

  test "blocked validation evidence is durable and idempotent", context do
    target = %{key: "blocked-validation", purpose: "review", sha: "candidate-sha"}
    assert {:ok, first} = Validation.record_blocked(context.runtime, "feature", target, "toolchain unavailable")
    assert first["status"] == "blocked"
    assert {:ok, ^first} = Validation.record_blocked(context.runtime, "feature", target, "later diagnostic")
  end

  test "validation records failed and blocked executable outcomes", context do
    sha = git!(context.workspace, ["rev-parse", "HEAD"])

    for {key, validator, status} <- [
          {"failed-outcome", fn _ -> {:error, %{exit_status: 7, output: "test failure"}} end, "failed"},
          {"blocked-outcome", fn _ -> {:blocked, :missing_toolchain} end, "blocked"},
          {"raised-outcome", fn _ -> raise "validator unavailable" end, "blocked"},
          {"thrown-outcome", fn _ -> throw(:validator_unavailable) end, "blocked"},
          {"exited-outcome", fn _ -> exit(:validator_shutdown) end, "blocked"}
        ] do
      checkout = Path.join(context.config.reviewer_root, key)
      target = %{key: key, purpose: "review", repository: context.workspace, sha: sha}
      assert {:ok, %{"status" => ^status} = evidence} = Validation.run(context.runtime, "feature", target, validator, checkout)
      assert evidence["exit_status"] in [nil, 7]
    end

    stale = %{key: "stale-tree", purpose: "review", repository: context.workspace, sha: sha, tree: "wrong-tree"}
    assert {:blocked, :stale_validation_tree} = Validation.run(context.runtime, "feature", stale, fn _ -> :ok end, Path.join(context.config.reviewer_root, "stale-tree"))
  end

  test "stale or malformed validation targets become durable blockers", context do
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", context.config)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "candidate\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, reviewing} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})

    stale =
      reviewing
      |> Map.put("phase", "Validating")
      |> Map.put("head", "stale-sha")
      |> Map.put("validation_target", %{"purpose" => "review", "sha" => reviewing["head"], "task_id" => "task-1"})

    replace_state(context.runtime, "feature", stale)
    assert {:ok, %{"phase" => "ValidationBlocked", "validation" => %{"diagnostic" => diagnostic}}} = LocalRunner.step(context.runtime, "feature", context.config)
    assert diagnostic =~ "candidate SHA is stale"

    malformed = stale |> Map.put("revision", stale["revision"] + 1) |> Map.put("validation_target", nil)
    replace_state(context.runtime, "feature", malformed)
    assert {:ok, %{"phase" => "ValidationBlocked"}} = LocalRunner.step(context.runtime, "feature", context.config)
  end

  test "prepared and recorded attempts recover without duplicate role execution", context do
    FeatureRunner.create(context.runtime, "captured", "Approved attendance feature")
    {:execute, captured} = FeatureRunner.prepare(context.runtime, "captured")
    assert {:captured, 0} = FeatureRunner.record(context.runtime, "captured", captured, plan())

    forbidden = %{context.config | executor: fn _ -> flunk("captured planner must not rerun") end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "captured", forbidden)
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "captured")
    discard_workspace_claim(context, "captured")

    FeatureRunner.create(context.runtime, "running", "Approved attendance feature")
    assert {:execute, _running} = FeatureRunner.prepare(context.runtime, "running")
    # A durable ProcessOwner lookup confirms that this merely prepared marker
    # has no live process tree, so same-VM recovery replaces it.
    assert {:ok, %{"phase" => "Failed"}} = LocalRunner.step(context.runtime, "running", forbidden)
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

      assert {:error, :workspace_release_requires_readiness_context} =
               LocalRunner.release_workspace(context.runtime, id)

      discard_workspace_claim(context, id)
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
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
    discard_workspace_claim(context, "feature")

    FeatureRunner.create(context.runtime, "dirty", "Approved attendance feature")
    assert {:ok, _} = LocalRunner.step(context.runtime, "dirty", planning)
    File.write!(Path.join(context.workspace, "unexpected.txt"), "dirty\n")
    completed = fn assignment -> envelope(assignment, %{"status" => "completed"}) end
    assert {:blocked, :workspace_integrity_blocker} = LocalRunner.step(context.runtime, "dirty", %{context.config | executor: completed})
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
    assert ready["validation"]["diagnostic"] == "validator passed"

    for {id, validator} <- [
          {"invalid-validator", fn _ -> :unexpected end},
          {"raised-validator", fn _ -> raise "validation crashed" end}
        ] do
      FeatureRunner.create(context.runtime, id, "Approved attendance feature")
      assert {:ok, blocked} = LocalRunner.run(context.runtime, id, %{context.config | validator: validator})
      assert blocked["phase"] == "ValidationBlocked"
      assert blocked["validation"]["status"] == "blocked"

      assert {:error, :workspace_release_requires_readiness_context} =
               LocalRunner.release_workspace(context.runtime, id)

      discard_workspace_claim(context, id)
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

    assert dirty_failed["phase"] == "ReadinessCheck"
    assert dirty_failed["technical_blocker"]["reason"] =~ "workspace_integrity_blocker"
  end

  test "config and autonomous step bounds reject invalid operation", context do
    assert {:blocked, :invalid_local_runner_config} = LocalRunner.run(context.runtime, "feature", :invalid)
    assert {:blocked, :invalid_local_runner_config} = LocalRunner.run(context.runtime, "feature", %{})

    assert {:blocked, :invalid_local_runner_config} =
             LocalRunner.run(context.runtime, "feature", Map.put(context.config, :allowed_paths, ["../outside"]))

    assert {:blocked, :invalid_local_runner_config} =
             LocalRunner.run(context.runtime, "feature", Map.put(context.config, :protected_paths, ["/outside"]))

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

    assert {:blocked, :workspace_already_owned} =
             LocalRunner.step(context.runtime, "conflict", %{context.config | executor: conflict})
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

  test "LocalRunner resumes a retried Developer with fresh durable identities without replanning", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    failed_executor = fn assignment ->
      assert assignment.role == "developer"
      envelope(assignment, %{"status" => "failed", "reason" => "temporary infrastructure failure"})
    end

    assert {:ok, %{"phase" => "Failed"}} =
             LocalRunner.step(context.runtime, "feature", %{context.config | executor: failed_executor})

    [[old_attempt, old_execution, "applied"]] =
      Store.read(context.runtime, fn db ->
        Store.execute(db, "SELECT attempt_id, execution_id, status FROM attempts WHERE feature_id = ? AND revision = 1", ["feature"])
      end)

    assert {:ok, %{"phase" => "Implementing"}} = FeatureRunner.retry(context.runtime, "feature")
    assert {:ok, %{"phase" => "Reviewing"}} = LocalRunner.step(context.runtime, "feature", context.config)

    [[new_attempt, new_execution, "applied"]] =
      Store.read(context.runtime, fn db ->
        Store.execute(db, "SELECT attempt_id, execution_id, status FROM attempts WHERE feature_id = ? ORDER BY revision DESC LIMIT 1", ["feature"])
      end)

    refute new_attempt == old_attempt
    refute new_execution == old_execution

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT COUNT(*) FROM local_role_outputs WHERE feature_id = ? AND role = 'mastermind'", ["feature"])
           end) == [[1]]
  end

  test "technical capture retry reuses durable Developer output without rerunning Developer", context do
    calls = Agent.start_link(fn -> 0 end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    git!(context.workspace, ["config", "--local", "--unset", "user.name"])
    git!(context.workspace, ["config", "--local", "--unset", "user.email"])

    developer = fn assignment ->
      Agent.update(calls, &(&1 + 1))
      File.write!(Path.join(context.workspace, "implementation.txt"), "captured once\n")
      envelope(assignment, %{"status" => "completed"})
    end

    retrying = Map.merge(context.config, %{executor: developer, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :validation_environment_blocked}} = LocalRunner.step(context.runtime, "feature", retrying)
    assert Agent.get(calls, & &1) == 1

    git!(context.workspace, ["config", "--local", "user.name", "Recovered Identity"])
    git!(context.workspace, ["config", "--local", "user.email", "recovered@example.test"])
    assert {:ok, %{"phase" => "Reviewing"}} = LocalRunner.step(context.runtime, "feature", retrying)
    assert Agent.get(calls, & &1) == 1
  end

  test "exhausted capture preserves its fingerprint and blocks changed bytes without rerunning Developer", context do
    calls = Agent.start_link(fn -> 0 end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)
    git!(context.workspace, ["config", "--local", "--unset", "user.name"])
    git!(context.workspace, ["config", "--local", "--unset", "user.email"])

    developer = fn assignment ->
      Agent.update(calls, &(&1 + 1))
      File.write!(Path.join(context.workspace, "implementation.txt"), "captured once\n")
      envelope(assignment, %{"status" => "completed"})
    end

    config = Map.merge(context.config, %{executor: developer, technical_retry_attempts: 1, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :validation_environment_blocked}} = LocalRunner.step(context.runtime, "feature", config)
    assert {:blocked, {:technical_retry_exhausted, :capture}} = LocalRunner.step(context.runtime, "feature", config)
    assert FeatureRunner.get(context.runtime, "feature")["phase"] == "Implementing"
    git!(context.workspace, ["config", "--local", "user.name", "Recovered Identity"])
    git!(context.workspace, ["config", "--local", "user.email", "recovered@example.test"])
    File.write!(Path.join(context.workspace, "implementation.txt"), "foreign changes\n")
    assert {:blocked, :workspace_integrity_blocker} = LocalRunner.step(context.runtime, "feature", config)
    File.write!(Path.join(context.workspace, "implementation.txt"), "captured once\n")
    assert {:ok, %{"phase" => "Reviewing"}} = LocalRunner.step(context.runtime, "feature", config)
    assert Agent.get(calls, & &1) == 1
  end

  test "validation environment retry preserves the candidate and never runs Reviewer", context do
    validator_calls = Agent.start_link(fn -> 0 end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(validator_calls), do: Agent.stop(validator_calls) end)

    config =
      Map.merge(context.config, %{
        technical_retry_backoff_ms: 0,
        validator: fn _context ->
          call = Agent.get_and_update(validator_calls, fn n -> {n + 1, n + 1} end)
          if call == 1, do: {:blocked, :missing_tool}, else: :ok
        end
      })

    planning = %{config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "candidate\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:blocked, {:technical_retry_scheduled, :validation_environment_blocked}} = LocalRunner.step(context.runtime, "feature", %{config | executor: developer})
    validating = FeatureRunner.get(context.runtime, "feature")
    assert validating["phase"] == "Validating"
    sha = validating["head"]
    assert {:ok, %{"phase" => "Reviewing", "head" => ^sha}} = LocalRunner.step(context.runtime, "feature", %{config | executor: fn _ -> flunk("Reviewer must not run during validation retry") end})
    assert Agent.get(validator_calls, & &1) == 2
  end

  test "a validation retry remains pending until due and then exhausts into a durable blocker", context do
    config =
      Map.merge(context.config, %{
        technical_retry_attempts: 1,
        technical_retry_backoff_ms: 1_000,
        now_ms: fn -> 100 end,
        validator: fn _ -> {:blocked, :missing_tool} end
      })

    planning = %{config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "candidate\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:blocked, {:technical_retry_scheduled, :validation_environment_blocked}} =
             LocalRunner.step(context.runtime, "feature", %{config | executor: developer})

    assert {:blocked, {:technical_retry_pending, :validation}} =
             LocalRunner.step(context.runtime, "feature", %{config | executor: fn _ -> flunk("retry is not due") end})

    due_config = %{config | now_ms: fn -> 1_100 end}

    assert {:ok, %{"phase" => "ValidationBlocked", "validation" => validation}} =
             LocalRunner.step(context.runtime, "feature", due_config)

    assert validation["failure_classification"] == "retry_exhausted"

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT status, attempts FROM technical_retries WHERE feature_id = ?", ["feature"])
           end) == [["exhausted", 2]]
  end

  test "role timeout is technical recovery and leaves no accepted role output", context do
    blocking = fn _assignment ->
      receive do
        _ -> :ok
      after
        10_000 -> :ok
      end
    end

    config = Map.merge(context.config, %{executor: blocking, role_execution_timeout_ms: 1, technical_retry_backoff_ms: 0})

    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    assert FeatureRunner.get(context.runtime, "feature")["phase"] == "Planning"
    assert Store.read(context.runtime, fn db -> Store.execute(db, "SELECT COUNT(*) FROM local_role_outputs WHERE feature_id = ?", ["feature"]) end) == [[0]]
  end

  test "tagged transient executor outage is retried without applying a role failure", context do
    config = Map.merge(context.config, %{executor: fn _ -> {:error, {:transient_infrastructure, :offline}} end, technical_retry_backoff_ms: 0})

    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    assert FeatureRunner.get(context.runtime, "feature")["phase"] == "Planning"
  end

  test "real Codex transport envelope retries one logical Developer attempt with a fresh execution", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    calls = Agent.start_link(fn -> [] end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    executor = fn assignment ->
      call = Agent.get_and_update(calls, fn seen -> {length(seen), [assignment | seen]} end)

      if call == 0 do
        # This is the atom-keyed envelope returned by CodexExec for an
        # interrupted transport, including the session event it already read.
        {:error, %{kind: :transport, detail: %{output: "connection reset", truncated?: false, codex_session_id: "transport-session"}}}
      else
        assert {:ok, active} = LocalRunner.status(context.runtime, "feature")
        assert active.session_id == nil
        File.write!(Path.join(context.workspace, "implementation.txt"), "recovered\n")
        envelope(assignment, %{"status" => "completed"})
      end
    end

    config = Map.merge(context.config, %{executor: executor, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)

    assert {:ok, status} = LocalRunner.status(context.runtime, "feature")
    assert status.session_id == "transport-session"

    assert {:ok, %{"phase" => "Reviewing"}} = LocalRunner.step(context.runtime, "feature", config)
    [second, first] = Agent.get(calls, & &1)
    assert first.attempt_id == second.attempt_id
    refute first.execution_id == second.execution_id

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT attempts, status FROM technical_retries WHERE feature_id = ?", ["feature"])
           end) == [[1, "completed"]]

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT COUNT(*) FROM role_executions WHERE attempt_id = ?", [first.attempt_id])
           end) == [[2]]
  end

  test "Developer retry resumes its own fingerprinted partial edits and rejects later unknown edits", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    calls = Agent.start_link(fn -> [] end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    developer = fn assignment ->
      index = Agent.get_and_update(calls, fn seen -> {length(seen), [assignment | seen]} end)

      if index == 0 do
        File.write!(Path.join(context.workspace, "implementation.txt"), "partial\n")
        {:error, %{kind: :transport, detail: %{output: "temporary transport failure"}}}
      else
        assert File.read!(Path.join(context.workspace, "implementation.txt")) == "partial\n"
        File.write!(Path.join(context.workspace, "implementation.txt"), "completed after resume\n")
        envelope(assignment, %{"status" => "completed"})
      end
    end

    config = Map.merge(context.config, %{executor: developer, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)

    assert {:ok, %{operation: "technical_retry_wait", technical_retry_count: 1, next_retry_at: due_at, latest_event: event}} =
             LocalRunner.status(context.runtime, "feature")

    assert is_integer(due_at)
    assert event =~ "technical retry scheduled"
    assert {:ok, %{"phase" => "Reviewing"}} = LocalRunner.step(context.runtime, "feature", config)
    [replacement, failed] = Agent.get(calls, &Enum.filter(&1, fn assignment -> assignment.task_id == "task-1" end))
    assert replacement.attempt_id == failed.attempt_id
    refute replacement.execution_id == failed.execution_id
  end

  test "Developer retry does not adopt dirty changes after its provenance fingerprint changes", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    failing = fn _assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "partial\n")
      {:error, %{kind: :transport, detail: %{output: "temporary transport failure"}}}
    end

    config = Map.merge(context.config, %{executor: failing, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    File.write!(Path.join(context.workspace, "unknown.txt"), "not owned\n")
    assert {:blocked, :workspace_integrity_blocker} = LocalRunner.step(context.runtime, "feature", config)
  end

  test "Developer retry rejects a changed HEAD even when its failed execution had provenance", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    failing = fn _assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "partial\n")
      {:error, %{kind: :transport, detail: %{output: "temporary transport failure"}}}
    end

    config = Map.merge(context.config, %{executor: failing, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    git!(context.workspace, ["add", "-A"])
    git!(context.workspace, ["commit", "-m", "foreign head"])
    assert {:blocked, :workspace_integrity_blocker} = LocalRunner.step(context.runtime, "feature", config)
  end

  test "a runner restarted before due_at autonomously resumes the durable retry", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    failed = fn _assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "restart partial\n")
      {:error, %{kind: :transport, detail: %{output: "temporary transport failure"}}}
    end

    scheduled = Map.merge(context.config, %{executor: failed, technical_retry_backoff_ms: 10, now_ms: fn -> 0 end})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", scheduled)
    assert :ok = Store.init(context.runtime)

    clock = Agent.start_link(fn -> 0 end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(clock), do: Agent.stop(clock) end)

    resumed = fn assignment ->
      assert File.read!(Path.join(context.workspace, "implementation.txt")) == "restart partial\n"
      File.write!(Path.join(context.workspace, "implementation.txt"), "restart success\n")
      envelope(assignment, %{"status" => "completed"})
    end

    config =
      Map.merge(context.config, %{
        executor: resumed,
        max_steps: 2,
        now_ms: fn -> Agent.get(clock, & &1) end,
        sleeper: fn milliseconds -> Agent.update(clock, &(&1 + milliseconds)) end,
        technical_retry_backoff_ms: 10
      })

    assert {:blocked, :local_flow_step_limit_exceeded} = LocalRunner.run(context.runtime, "feature", config)
    assert File.read!(Path.join(context.workspace, "implementation.txt")) == "restart success\n"
  end

  @tag :acceptance_reliability
  test "LocalRunner waits for due_at and resumes a partial Developer retry without another run call", context do
    clock = Agent.start_link(fn -> 0 end) |> then(fn {:ok, agent} -> agent end)
    calls = Agent.start_link(fn -> [] end) |> then(fn {:ok, agent} -> agent end)

    on_exit(fn ->
      if Process.alive?(clock), do: Agent.stop(clock)
      if Process.alive?(calls), do: Agent.stop(calls)
    end)

    executor = fn assignment ->
      case assignment.role do
        "mastermind" ->
          envelope(assignment, plan())

        "developer" ->
          index = Agent.get_and_update(calls, fn seen -> {length(seen), [assignment | seen]} end)

          if index == 0 do
            File.write!(Path.join(context.workspace, "implementation.txt"), "partial autonomous\n")
            {:error, %{kind: :transport, detail: %{output: "temporary transport failure"}}}
          else
            if index == 1, do: assert(File.read!(Path.join(context.workspace, "implementation.txt")) == "partial autonomous\n")
            File.write!(Path.join(context.workspace, "implementation.txt"), "autonomous success\n")
            envelope(assignment, %{"status" => "completed"})
          end

        "reviewer" ->
          envelope(assignment, %{"status" => "approved"})
      end
    end

    config =
      Map.merge(context.config, %{
        executor: executor,
        now_ms: fn -> Agent.get(clock, & &1) end,
        sleeper: fn milliseconds -> Agent.update(clock, &(&1 + milliseconds)) end,
        technical_retry_backoff_ms: 10
      })

    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", config)
    assert ready["phase"] == "ReadyForHuman"
    [replacement, failed] = Agent.get(calls, &Enum.filter(&1, fn assignment -> assignment.task_id == "task-1" end))
    assert replacement.attempt_id == failed.attempt_id
    refute replacement.execution_id == failed.execution_id
    assert {:ok, status} = LocalRunner.status(context.runtime, "feature")
    assert status.next_retry_at == nil
    assert status.technical_retry_count == 0
    refute status.operation == "technical_retry_wait"
  end

  test "technical retry budget survives replacement executions and journal restart", context do
    calls = Agent.start_link(fn -> [] end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    failing = fn assignment ->
      Agent.update(calls, &[assignment | &1])
      {:error, %{kind: :process, detail: %{exit_status: 75, output: "temporary CLI outage", codex_session_id: "session-#{assignment.execution_id}"}}}
    end

    config = Map.merge(context.config, %{executor: failing, technical_retry_attempts: 2, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    Store.init(context.runtime)
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    assert {:ok, %{"phase" => "Failed", "error" => error}} = LocalRunner.step(context.runtime, "feature", config)
    assert error =~ "technical retry exhausted"

    [third, second, first] = Agent.get(calls, & &1)
    assert first.attempt_id == second.attempt_id
    assert second.attempt_id == third.attempt_id
    assert Enum.uniq(Enum.map([first, second, third], & &1.execution_id)) |> length() == 3

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT attempts, status FROM technical_retries WHERE feature_id = ?", ["feature"])
           end) == [[3, "exhausted"]]
  end

  @tag :acceptance_reliability
  test "Reviewer technical recovery keeps one reviewer attempt and one immutable reviewed SHA", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "review target\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:ok, %{"phase" => "Reviewing"}} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: developer})

    calls = Agent.start_link(fn -> [] end) |> then(fn {:ok, agent} -> agent end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

    reviewer = fn assignment ->
      index = Agent.get_and_update(calls, fn seen -> {length(seen), [assignment | seen]} end)

      if index == 0 do
        {:error, %{kind: :process, detail: %{exit_status: 1, output: "Codex temporarily unavailable"}}}
      else
        assert git!(assignment.workspace, ["rev-parse", "HEAD"]) == assignment.reviewed_sha
        envelope(assignment, %{"status" => "approved"})
      end
    end

    config = Map.merge(context.config, %{executor: reviewer, technical_retry_backoff_ms: 0})
    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", config)
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", config)

    [second, first] = Agent.get(calls, & &1)
    assert first.attempt_id == second.attempt_id
    assert first.reviewed_sha == second.reviewed_sha
    refute first.execution_id == second.execution_id
    assert {:ok, binding} = Git.reviewer_checkout(context.runtime, "feature", first.attempt_id)
    assert binding.execution_id == second.execution_id
    assert binding.reviewed_sha == first.reviewed_sha
  end

  test "malformed and unconfirmed Codex errors remain terminal rather than technical retries", context do
    malformed = fn _ -> {:error, %{kind: :schema, detail: :required_fields_or_failed_reason}} end
    assert {:ok, %{"phase" => "Failed"}} = LocalRunner.step(context.runtime, "feature", %{context.config | executor: malformed})
    assert {:error, :workspace_release_requires_readiness_context} = LocalRunner.release_workspace(context.runtime, "feature")
    discard_workspace_claim(context, "feature")

    FeatureRunner.create(context.runtime, "unconfirmed", "Approved attendance feature")

    unconfirmed = fn _ -> {:error, %{kind: :transport, detail: {:process_cleanup_unconfirmed, :cgroup_not_empty}}} end

    assert {:ok, %{"phase" => "Failed"}} = LocalRunner.step(context.runtime, "unconfirmed", %{context.config | executor: unconfirmed})

    assert Store.read(context.runtime, fn db ->
             Store.execute(db, "SELECT COUNT(*) FROM technical_retries WHERE feature_id = ?", ["unconfirmed"])
           end) == [[0]]
  end

  test "validation timeout is classified as transient infrastructure", context do
    config =
      Map.merge(context.config, %{
        technical_retry_backoff_ms: 0,
        validation_timeout_ms: 1,
        validator: fn _ ->
          receive do
            _ -> :ok
          after
            10_000 -> :ok
          end
        end
      })

    planning = %{config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    developer = fn assignment ->
      File.write!(Path.join(context.workspace, "implementation.txt"), "timeout candidate\n")
      envelope(assignment, %{"status" => "completed"})
    end

    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} = LocalRunner.step(context.runtime, "feature", %{config | executor: developer})
    assert FeatureRunner.get(context.runtime, "feature")["phase"] == "Validating"
  end

  test "technical role retries do not change durable per-task repair counts", context do
    planning = %{context.config | executor: fn assignment -> envelope(assignment, plan()) end}
    assert {:ok, %{"phase" => "Implementing"}} = LocalRunner.step(context.runtime, "feature", planning)

    retrying =
      Map.merge(context.config, %{
        executor: fn _ -> {:error, %{kind: :process, detail: %{exit_status: 1, output: "temporary outage"}}} end,
        technical_retry_backoff_ms: 0
      })

    assert {:blocked, {:technical_retry_scheduled, :transient_infrastructure}} =
             LocalRunner.step(context.runtime, "feature", retrying)

    assert Enum.map(FeatureRunner.get(context.runtime, "feature")["tasks"], & &1["repair_count"]) == [0, 0]
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

  # The ordinary LocalRunner flow releases a completed workspace. These helpers
  # rebuild its final, durable evidence and then re-arm only the terminal gate
  # so each regression mutates one authoritative fact at a time.
  defp rearm_readiness(context) do
    assert {:ok, ready} = LocalRunner.run(context.runtime, "feature", context.config)
    assert ready["phase"] == "ReadyForHuman"

    replace_state(context.runtime, "feature", Map.put(ready, "phase", "ReadinessCheck"))

    Store.transaction(context.runtime, fn db ->
      Store.execute(
        db,
        "INSERT INTO workspace_ownership (workspace, feature_id, expected_branch, initial_base_sha, expected_head_sha, adopted, claimed_at_ms) VALUES (?, ?, ?, ?, ?, 0, 0)",
        [Path.expand(context.workspace), "feature", context.config.expected_branch, ready["initial_base_sha"], ready["final_sha"]]
      )
    end)

    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime, "feature")
    FeatureRunner.get(context.runtime, "feature")
  end

  defp finalize(context, state \\ nil) do
    state = state || FeatureRunner.get(context.runtime, "feature")
    FeatureRunner.complete_readiness(context.runtime, "feature", state["revision"], readiness_context(context))
  end

  defp readiness_context(context), do: %{workspace: context.workspace, expected_branch: context.config.expected_branch}

  defp reset_feature_fixture(context) do
    _ = WorkspaceLock.release(context.workspace, context.runtime, "feature")

    Store.transaction(context.runtime, fn db ->
      for table <- [
            "reviewer_checkouts",
            "implementation_commits",
            "validation_evidence",
            "local_role_outputs",
            "technical_retries",
            "effects",
            "role_executions",
            "process_executions",
            "attempts",
            "workspace_ownership"
          ] do
        Store.execute(db, "DELETE FROM #{table} WHERE feature_id = ?", ["feature"])
      end

      Store.execute(db, "DELETE FROM features WHERE id = ?", ["feature"])
    end)

    Agent.update(context.calls, fn _ -> [] end)
    FeatureRunner.create(context.runtime, "feature", "Approved attendance feature")
  end

  # Test-fixture teardown for deliberately failed/abandoned flows. Production
  # release is intentionally restricted to the readiness path above.
  defp discard_workspace_claim(context, feature_id) do
    _ = WorkspaceLock.release(context.workspace, context.runtime, feature_id)

    Store.transaction(context.runtime, fn db ->
      Store.execute(db, "DELETE FROM workspace_ownership WHERE feature_id = ?", [feature_id])
    end)
  end

  defp git!(directory, args) do
    {output, status} = System.cmd("git", ["-C", directory | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp raw_rows(path, sql) do
    {:ok, db} = Sqlite3.open(path)
    {:ok, statement} = Sqlite3.prepare(db, sql)

    try do
      :ok = Sqlite3.bind(statement, [])
      raw_rows(db, statement, [])
    after
      Sqlite3.release(db, statement)
      Sqlite3.close(db)
    end
  end

  defp raw_rows(db, statement, rows) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> raw_rows(db, statement, [row | rows])
      :done -> Enum.reverse(rows)
    end
  end
end
