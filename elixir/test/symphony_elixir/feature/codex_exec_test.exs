defmodule SymphonyElixir.Feature.CodexExecTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{CodexExec, Sandbox, Store}
  alias SymphonyElixir.FeatureRunner, as: Runner

  setup do
    root = Path.join(System.tmp_dir!(), "codex-exec-#{System.unique_integer([:positive])}")
    runtime_dir = Path.join(root, "coordinator-runtime")
    db = Path.join(runtime_dir, "state.sqlite3")
    workspace = Path.join(root, "workspace")
    output = Path.join(root, "output")
    File.mkdir_p!(runtime_dir)
    File.mkdir_p!(workspace)
    File.mkdir_p!(output)
    Store.init(db)
    {:ok, sandbox} = Sandbox.profile(role: :test, workspace: workspace, output: output, runtime: db)
    fixture = Path.join(workspace, "fixture.py")
    File.write!(fixture, fixture_source())
    File.chmod!(fixture, 0o755)

    on_exit(fn ->
      SymphonyElixir.FeatureTestCleanup.cleanup(root)
      File.rm_rf!(root)
    end)

    %{db: db, fixture: "/workspace/fixture.py", output: output, sandbox: sandbox, workspace: workspace}
  end

  test "passes argv and stdin, decodes chunked JSONL and reads event session id", context do
    assert {:ok, response} = run(context, "ok")
    assert response.codex_session_id == "session-from-event"
    assert is_binary(response.result["execution_id"])
    assert response.result["role"] == "reviewer"
  end

  test "accepts the real thread.started session field and result-event fallback", context do
    assert {:ok, %{codex_session_id: "thread-from-event"}} = run(context, "thread")
    File.rm!(Path.join(context.output, "codex-last-message.json"))
    assert {:ok, %{result: %{"status" => "completed"}}} = run(context, "event-result")
  end

  test "finds nested session IDs and rejects non-object final output", context do
    assert {:ok, %{codex_session_id: "nested-thread"}} = run(context, "nested-thread")
    assert {:ok, %{codex_session_id: "list-thread"}} = run(context, "list-thread")
    assert {:error, %{kind: :invalid_final_json}} = run(context, "invalid-final")
  end

  test "Codex argv isolates local state and model-issued network access" do
    args =
      CodexExec.argv(
        %{
          model: "fixture-model",
          reasoning_effort: "low",
          fixture_args: []
        },
        %{sandbox_schema: "/output/schema.json", sandbox_last_message: "/output/last.json"}
      )

    assert "--ephemeral" in args
    assert "--ignore-user-config" in args
    assert "--ignore-rules" in args
    assert ["--sandbox", "workspace-write"] in Enum.chunk_every(args, 2, 1, :discard)
    assert ["-c", "sandbox_workspace_write.network_access=false"] in Enum.chunk_every(args, 2, 1, :discard)
    refute ["-c", "features.code_mode_host=true"] in Enum.chunk_every(args, 2, 1, :discard)
    refute Enum.any?(args, &String.contains?(&1, "features.code_mode_host="))
  end

  test "Codex argv enables the code-mode host only for the explicit Codex profile", context do
    output = Path.join(Path.dirname(context.output), "codex-code-mode-output")
    File.mkdir_p!(output)
    {:ok, codex} = Sandbox.profile(role: :codex, workspace: context.workspace, output: output, runtime: context.db)
    paths = %{sandbox_schema: "/output/schema.json", sandbox_last_message: "/output/last.json"}
    request = %{model: "fixture-model", reasoning_effort: "low", fixture_args: [], sandbox: codex}

    assert ["-c", "features.code_mode_host=true"] in Enum.chunk_every(CodexExec.argv(request, paths), 2, 1, :discard)
    refute ["-c", "features.code_mode_host=true"] in Enum.chunk_every(CodexExec.argv(%{request | sandbox: context.sandbox}, paths), 2, 1, :discard)
  end

  test "Codex argv opts into skipping the git trust check only when requested" do
    paths = %{sandbox_schema: "/output/schema.json", sandbox_last_message: "/output/last.json"}
    request = %{model: "fixture-model", reasoning_effort: "low", fixture_args: []}

    refute "--skip-git-repo-check" in CodexExec.argv(request, paths)
    assert "--skip-git-repo-check" in CodexExec.argv(Map.put(request, :skip_git_repo_check, true), paths)
  end

  test "output schema is strict while allowing no failure reason on completion" do
    schema = CodexExec.output_schema()
    assert schema["additionalProperties"] == false
    assert "reason" in schema["required"]
    assert schema["properties"]["reason"]["type"] == ["string", "null"]
  end

  test "output schema fences every invocation identity field to its request" do
    request = %{role: "reviewer", task_id: "task-1", attempt_id: "attempt-current", execution_id: "execution-current"}
    schema = CodexExec.output_schema(request)

    assert schema["properties"]["role"] == %{"enum" => ["reviewer"]}
    assert schema["properties"]["task_id"] == %{"enum" => ["task-1"]}
    assert schema["properties"]["attempt_id"] == %{"enum" => ["attempt-current"]}
    assert schema["properties"]["execution_id"] == %{"enum" => ["execution-current"]}
  end

  test "output schema carries a role result contract and exact reviewed SHA" do
    result_schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["status"],
      "properties" => %{"status" => %{"enum" => ["approved"]}}
    }

    reviewed_sha = String.duplicate("a", 40)
    schema = CodexExec.output_schema(%{result_schema: result_schema, reviewed_sha: reviewed_sha})
    assert schema["properties"]["result"] == result_schema
    assert schema["properties"]["reviewed_sha"] == %{"enum" => [reviewed_sha]}
    assert "result" in schema["required"]
    assert "reviewed_sha" in schema["required"]
  end

  test "authenticated preflight uses the Codex profile and cleans its disposable auth", context do
    output = Path.join(Path.dirname(context.output), "codex-preflight-output")
    File.mkdir_p!(output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: context.workspace, output: output, runtime: context.db)
    feature_id = "preflight-#{System.unique_integer([:positive])}"
    Runner.create(context.db, feature_id, "Codex preflight")
    {:execute, execution} = Runner.prepare(context.db, feature_id)

    request = %{
      attempt_id: execution.attempt_id,
      execution_id: execution.execution_id,
      output_dir: output,
      runtime: context.db,
      execution: execution,
      sandbox: sandbox
    }

    assert {:ok, %{check: :version, exit_status: 0, output: version_output}} = CodexExec.preflight(request, :version)
    assert String.contains?(version_output, "codex-cli")
    refute File.exists?(Path.join(output, "home/.codex/auth.json"))

    login_output = Path.join(Path.dirname(context.output), "codex-login-output")
    File.mkdir_p!(login_output)
    {:ok, login_sandbox} = Sandbox.profile(role: :codex, workspace: context.workspace, output: login_output, runtime: context.db)
    login_feature_id = "login-#{System.unique_integer([:positive])}"
    Runner.create(context.db, login_feature_id, "Codex login preflight")
    {:execute, login_execution} = Runner.prepare(context.db, login_feature_id)

    login_request = %{
      attempt_id: login_execution.attempt_id,
      execution_id: login_execution.execution_id,
      output_dir: login_output,
      runtime: context.db,
      execution: login_execution,
      sandbox: login_sandbox
    }

    assert {:ok, %{check: :login_status, exit_status: 0, output: login_status}} =
             CodexExec.preflight(login_request, :login_status)

    assert String.contains?(login_status, "Logged in")
    refute File.exists?(Path.join(login_output, "home/.codex/auth.json"))
  end

  test "preflight and Codex execution reject malformed or overridden requests", context do
    assert {:error, %{kind: :invalid_preflight_request}} = CodexExec.preflight(%{}, :version)
    assert {:error, %{kind: :invalid_preflight_request}} = CodexExec.preflight(:invalid, :version)
    assert {:error, %{kind: :invalid_preflight_request}} = CodexExec.preflight(%{runtime: context.db}, :version)
    assert {:error, %{kind: :invalid_request}} = CodexExec.run(:not_a_request)

    output = Path.join(Path.dirname(context.output), "codex-override-output")
    File.mkdir_p!(output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: context.workspace, output: output, runtime: context.db)
    feature_id = "override-#{System.unique_integer([:positive])}"
    Runner.create(context.db, feature_id, "Codex executable policy")
    {:execute, execution} = Runner.prepare(context.db, feature_id)

    request = %{
      attempt_id: execution.attempt_id,
      execution_id: execution.execution_id,
      role: "test",
      task_id: "policy",
      model: "model",
      reasoning_effort: "low",
      prompt: "unused",
      output_dir: output,
      runtime: context.db,
      execution: execution,
      sandbox: sandbox,
      executable: context.fixture
    }

    assert {:error, %{kind: :invalid_request}} = CodexExec.run(request)
    assert {:error, %{kind: :invalid_request}} = CodexExec.run(%{request | execution: :invalid})
  end

  test "artifact creation fails closed before starting a process", context do
    File.mkdir!(Path.join(context.output, "codex-result-schema.json"))
    assert {:error, %{kind: :artifact_write}} = run(context, "ok")
  end

  test "sandbox/output mismatches are rejected before starting a process", context do
    other_output = Path.join(Path.dirname(context.output), "other-output")
    File.mkdir_p!(other_output)
    assert {:error, %{kind: :invalid_request}} = run(context, "ok", output_dir: other_output)
  end

  test "rejects malformed JSONL", context do
    assert {:error, %{kind: :malformed_jsonl}} = run(context, "malformed")
  end

  test "rejects partial output and non-zero exit", context do
    assert {:error, %{kind: :partial_jsonl}} = run(context, "partial")

    assert {:error, %{kind: :process, detail: %{exit_status: 7, codex_session_id: "session-from-event"}}} =
             run(context, "nonzero")
  end

  test "requires a final result and validates its schema", context do
    assert {:error, %{kind: :missing_final_result}} = run(context, "missing")
    assert {:error, %{kind: :schema}} = run(context, "schema")
  end

  test "accepts only an exact invocation identity", context do
    assert {:ok, %{result: %{"role" => "reviewer", "task_id" => "task-1"}}} = run(context, "ok")
  end

  test "rejects a wrong attempt identity", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "wrong-attempt")
  end

  test "rejects a wrong execution identity", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "wrong-execution")
  end

  test "rejects a wrong role identity", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "wrong-role")
  end

  test "rejects a wrong task identity", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "wrong-task")
  end

  test "requires the reviewer to repeat the assigned exact SHA", context do
    assert {:error, %{kind: :not_allowed}} =
             run(context, "ok", reviewed_sha: String.duplicate("a", 40))
  end

  test "a stale execution result remains rejected despite syntactically valid JSON", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "stale-execution")
  end

  test "rejects developer SHA", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "sha", role: "developer")
  end

  test "keeps diagnostic output bounded and preserves role failures", context do
    assert {:error, %{kind: :role_failed, detail: %{result: %{"reason" => "fixture failure"}}}} = run(context, "failed")
    assert {:ok, %{output: output, truncated?: true}} = run(context, "large")
    assert byte_size(output) <= 64 * 1024

    assert {:ok, %{output: combined_output, truncated?: true}} = run(context, "large-both")
    assert byte_size(combined_output) <= 64 * 1024
  end

  defp run(context, scenario, overrides \\ []) do
    feature_id = "feature-#{System.unique_integer([:positive])}"
    Runner.create(context.db, feature_id, "Approved specification")
    {:execute, execution} = Runner.prepare(context.db, feature_id)

    request = %{
      attempt_id: execution.attempt_id,
      execution_id: execution.execution_id,
      role: "reviewer",
      task_id: "task-1",
      model: "fixture-model",
      reasoning_effort: "low",
      prompt: "stdin prompt",
      output_dir: context.output,
      runtime: context.db,
      execution: execution,
      sandbox: context.sandbox,
      executable: context.fixture,
      fixture_args: [scenario, execution.attempt_id, execution.execution_id]
    }

    CodexExec.run(Map.merge(request, Map.new(overrides)))
  end

  defp fixture_source do
    ~S"""
    #!/usr/bin/env python3
    #!/usr/bin/env python3
    import json, os, sys
    last = sys.argv[sys.argv.index('--output-last-message') + 1]
    scenario, attempt_id, execution_id = sys.argv[-3:]
    assert sys.stdin.readline() == 'stdin prompt\n'
    assert '--json' in sys.argv and '--model' in sys.argv and '-c' in sys.argv
    base = {'status':'completed','role':'reviewer','task_id':'task-1','attempt_id':attempt_id,'execution_id':execution_id}
    if scenario == 'malformed': print('{bad'); sys.exit(0)
    if scenario == 'partial': sys.stdout.write('{\"type\":'); sys.exit(0)
    if scenario == 'nonzero': print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(7)
    if scenario == 'missing': print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'event-result': print(json.dumps({'type':'session','session_id':'session-from-event'})); print(json.dumps({'type':'result','result':base})); sys.exit(0)
    if scenario == 'thread': print(json.dumps({'type':'thread.started','thread_id':'thread-from-event'})); open(last,'w').write(json.dumps(base)); sys.exit(0)
    if scenario == 'nested-thread': print(json.dumps({'type':'event','payload':{'thread_id':'nested-thread'}})); open(last,'w').write(json.dumps(base)); sys.exit(0)
    if scenario == 'list-thread': print(json.dumps({'type':'event','items':[{'thread_id':'list-thread'}]})); open(last,'w').write(json.dumps(base)); sys.exit(0)
    if scenario == 'invalid-final': open(last,'w').write('[]'); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'schema': base.pop('task_id'); open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'wrong-attempt': base['attempt_id']='other-attempt'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'wrong-execution': base['execution_id']='other-execution'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'wrong-role': base['role']='test'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'wrong-task': base['task_id']='other-task'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'stale-execution': base['execution_id']='stale-execution-id'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'sha': base['role']='developer'; base['sha']='not-authoritative'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'failed': base['status']='failed'; base['reason']='fixture failure'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'large': print(json.dumps({'type':'session','session_id':'session-from-event'})); print(json.dumps({'noise':'x'*70000})); open(last,'w').write(json.dumps(base)); sys.exit(0)
    if scenario == 'large-both': print(json.dumps({'type':'session','session_id':'session-from-event'})); print(json.dumps({'noise':'x'*40000})); sys.stderr.write('y'*40000); open(last,'w').write(json.dumps(base)); sys.exit(0)
    event = json.dumps({'type':'session','session_id':'session-from-event'}) + '\n'
    for piece in [event[:5], event[5:]]: sys.stdout.write(piece); sys.stdout.flush()
    open(last,'w').write(json.dumps(base))
    """
  end
end
