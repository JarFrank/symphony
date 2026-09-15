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
    on_exit(fn -> File.rm_rf!(root) end)
    %{db: db, fixture: "/workspace/fixture.py", output: output, sandbox: sandbox}
  end

  test "passes argv and stdin, decodes chunked JSONL and reads event session id", context do
    assert {:ok, response} = run(context, "ok")
    assert response.codex_session_id == "session-from-event"
    assert is_binary(response.result["execution_id"])
    assert response.result["role"] == "reviewer"
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

  test "rejects wrong role/task/execution and developer SHA", context do
    assert {:error, %{kind: :not_allowed}} = run(context, "wrong")
    assert {:error, %{kind: :not_allowed}} = run(context, "sha", role: "developer")
  end

  test "keeps diagnostic output bounded and preserves role failures", context do
    assert {:error, %{kind: :role_failed, detail: %{result: %{"reason" => "fixture failure"}}}} = run(context, "failed")
    assert {:ok, %{output: output, truncated?: true}} = run(context, "large")
    assert byte_size(output) <= 64 * 1024
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
    if scenario == 'schema': base.pop('task_id'); open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'wrong': base['execution_id']='other'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'sha': base['role']='developer'; base['sha']='not-authoritative'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'failed': base['status']='failed'; base['reason']='fixture failure'; open(last,'w').write(json.dumps(base)); print(json.dumps({'type':'session','session_id':'session-from-event'})); sys.exit(0)
    if scenario == 'large': print(json.dumps({'type':'session','session_id':'session-from-event'})); print(json.dumps({'noise':'x'*70000})); open(last,'w').write(json.dumps(base)); sys.exit(0)
    event = json.dumps({'type':'session','session_id':'session-from-event'}) + '\n'
    for piece in [event[:5], event[5:]]: sys.stdout.write(piece); sys.stdout.flush()
    open(last,'w').write(json.dumps(base))
    """
  end
end
