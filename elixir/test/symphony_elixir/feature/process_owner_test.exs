defmodule SymphonyElixir.Feature.ProcessOwnerTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias SymphonyElixir.Feature.{ProcessOwner, Sandbox, Store}
  alias SymphonyElixir.Feature.ProcessOwner.IO, as: ProcessOwnerIO
  alias SymphonyElixir.FeatureRunner, as: Runner

  @timeout 5_000

  setup do
    dir = Path.join(System.tmp_dir!(), "process-owner-#{System.unique_integer([:positive])}")
    runtime_dir = Path.join(dir, "coordinator-runtime")
    db = Path.join(runtime_dir, "state.sqlite3")
    workspace = Path.join(dir, "workspace")
    output = Path.join(dir, "output")
    File.mkdir_p!(workspace)
    File.mkdir_p!(output)
    Store.init(db)
    Runner.create(db, "feature", "Approved specification")
    {:ok, sandbox} = Sandbox.profile(role: :test, workspace: workspace, output: output, runtime: db)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: db, output: output, sandbox: sandbox, workspace: workspace}
  end

  test "cancellation terminates a subprocess and its child", %{db: db, output: output, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, execution, program(false))
    _processes = await_processes(output)

    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    assert status(db, execution.execution_id) == "terminated"
    assert started.invocation_id != ""
    assert started.control_group != ""
  end

  test "TERM-ignoring subprocess tree is force terminated within the unit bound", %{db: db, output: output, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _started} = start(db, sandbox, execution, program(true))
    _processes = await_processes(output)

    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    assert status(db, execution.execution_id) == "terminated"
  end

  test "a new VM recovers a live execution before starting the next writer", %{db: db, sandbox: sandbox} do
    port = active_owner_vm(db)
    await(port, "READY")
    {:os_pid, vm_pid} = Port.info(port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(vm_pid)])
    await_exit(port)

    [old] = ProcessOwner.current(db)
    assert :ok = ProcessOwner.recover(db)
    assert status(db, old.execution_id) == "terminated"

    {:execute, next_execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, next_execution, sleep_program())
    assert :ok = ProcessOwner.cancel(db, started.execution_id)
  end

  test "an intent left by a dead VM before start metadata is reconciled safely", %{db: db, sandbox: sandbox} do
    port = intent_only_vm(db)
    await(port, "INTENDED")
    {:os_pid, vm_pid} = Port.info(port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(vm_pid)])
    await_exit(port)

    [old] = ProcessOwner.current(db)
    assert old.status == "intended"
    assert :ok = ProcessOwner.recover(db)
    assert status(db, old.execution_id) == "terminated"

    {:execute, next_execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, next_execution, sleep_program())
    assert :ok = ProcessOwner.cancel(db, started.execution_id)
  end

  test "mismatched invocation identity is never treated as the current writer", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, execution, sleep_program())

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET invocation_id = 'stale-invocation' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:process_identity_mismatch, ^execution_id, _}} = ProcessOwner.recover(db)
    assert status(db, execution.execution_id) == "ambiguous"

    Runner.create(db, "second", "Approved specification")
    {:execute, next_execution} = Runner.prepare(db, "second")
    assert {:blocked, {:ambiguous_execution, ^execution_id}} = start(db, sandbox, next_execution, sleep_program())

    assert {_, 0} = System.cmd("systemctl", ["--user", "stop", started.unit_name])
  end

  test "an ambiguous prior liveness record blocks another writer", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET status = 'ambiguous' WHERE execution_id = ?", [execution.execution_id])
    end)

    Runner.create(db, "second", "Approved specification")
    {:execute, next_execution} = Runner.prepare(db, "second")
    execution_id = execution.execution_id
    assert {:blocked, {:ambiguous_execution, ^execution_id}} = start(db, sandbox, next_execution, sleep_program())
  end

  test "raw or invalid launch requests fail closed", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")

    assert {:blocked, :sandbox_required} = ProcessOwner.launch(db, "missing", sleep_program())
    assert {:blocked, {:unknown_execution, "missing"}} = ProcessOwner.launch(db, "missing", sleep_program(), sandbox)
    assert :ok = ProcessOwner.cancel(db, "missing")

    assert {:ok, _intent} = ProcessOwner.intent(db, execution)
    assert {:blocked, :invalid_sandbox_command} = ProcessOwner.launch(db, execution.execution_id, %{}, sandbox)
    assert :ok = ProcessOwner.recover(db)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
  end

  test "unobservable liveness blocks another writer", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, execution, sleep_program())
    execution_id = execution.execution_id
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", "/missing-process-owner-test-path")

    try do
      assert {:blocked, {:liveness_unknown, ^execution_id, _}} = ProcessOwner.recover(db)
    after
      System.put_env("PATH", previous_path)
    end

    assert status(db, execution_id) == "ambiguous"
    assert {_, 0} = System.cmd("systemctl", ["--user", "stop", started.unit_name])
  end

  test "mismatched unit name is never treated as the current writer", %{db: db, sandbox: _sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET unit_name = 'other.service' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:process_identity_mismatch, ^execution_id, :unit_name}} = ProcessOwner.recover(db)
  end

  test "a nonempty recorded cgroup cannot be considered terminated", %{db: db, sandbox: _sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET control_group = '/' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:cgroup_not_empty, ^execution_id}} = ProcessOwner.recover(db)
  end

  test "a cgroup lookup error never confirms a missing unit as terminated", %{db: db, sandbox: _sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET control_group = ? WHERE execution_id = ?", [<<0>>, execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:cgroup_not_empty, ^execution_id}} = ProcessOwner.recover(db)
    assert status(db, execution_id) == "ambiguous"
  end

  test "a systemd stop failure leaves the execution ambiguous instead of releasing ownership", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, execution, sleep_program())

    shim_dir = Path.join(System.tmp_dir!(), "process-owner-stop-shim-#{System.unique_integer([:positive])}")
    shim = Path.join(shim_dir, "systemctl")
    File.mkdir_p!(shim_dir)
    File.write!(shim, "#!/bin/sh\nif [ \"$2\" = stop ]; then echo stop-refused; exit 1; fi\nexec #{System.find_executable("systemctl")} \"$@\"\n")
    File.chmod!(shim, 0o755)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", "#{shim_dir}:#{previous_path}")

    try do
      execution_id = execution.execution_id
      assert {:blocked, {:termination_unconfirmed, ^execution_id, "stop-refused\n"}} = ProcessOwner.cancel(db, execution_id)
      assert status(db, execution_id) == "ambiguous"
    after
      System.put_env("PATH", previous_path)
      File.rm_rf!(shim_dir)
      assert {_, 0} = System.cmd("systemctl", ["--user", "stop", started.unit_name])
    end
  end

  test "active unit with only durable intent is stopped during recovery", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = start(db, sandbox, execution, sleep_program())

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET status = 'intended', invocation_id = NULL, control_group = NULL, main_pid = NULL WHERE execution_id = ?", [execution.execution_id])
    end)

    assert :ok = ProcessOwner.recover(db)
    assert status(db, execution.execution_id) == "terminated"
    refute alive?(started.main_pid)
  end

  test "ProcessOwner streams sandboxed CLI I/O with bounded independent buffers and exit status", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")

    assert {:ok, started} =
             ProcessOwner.start_io(db, execution, cli_program(), sandbox, max_buffer_bytes: 1_024)

    assert :ok = ProcessOwner.subscribe(started.io)
    assert :ok = ProcessOwner.write_stdin(started.io, "first ")
    assert :ok = ProcessOwner.write_stdin(started.io, "second\\n")
    assert {:blocked, :invalid_stdin} = ProcessOwner.write_stdin(started.io, :not_iodata)
    assert :ok = ProcessOwner.close_stdin(started.io)
    assert {:blocked, :stdin_closed} = ProcessOwner.write_stdin(started.io, "after close")
    assert :ok = ProcessOwner.close_stdin(started.io)
    assert {:blocked, :invalid_subscriber} = ProcessOwner.subscribe(started.io, :not_a_pid)

    assert_receive {:process_owner_io, _handle, :stdout, _chunk}, @timeout
    assert_receive {:process_owner_io, _handle, :stderr, _chunk}, @timeout
    assert {:ok, output} = await_io_output(started.io, fn value -> String.contains?(value.stdout, "first second") end)
    assert output.stderr == "diagnostic\n"

    assert {:ok, 23} = await_exit_status(started.io)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
  end

  test "I/O owner survives a writer lock, starter exit, and final stream drain", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    parent = self()
    ref = make_ref()

    starter =
      spawn(fn ->
        result = ProcessOwner.start_io(db, execution, delayed_cli_program(), sandbox, max_buffer_bytes: 1_024)
        send(parent, {ref, result})
      end)

    monitor = Process.monitor(starter)
    assert_receive {^ref, {:ok, started}}, @timeout
    assert_receive {:DOWN, ^monitor, :process, ^starter, :normal}, @timeout

    # A quick systemd child can write before start_io/5 returns. The explicit
    # subscription still works after the starter has exited, and the initial
    # subscriber is not needed for ProcessOwner-level final output collection.
    assert :ok = ProcessOwner.subscribe(started.io)
    assert :ok = ProcessOwner.write_stdin(started.io, "release\n")
    assert :ok = ProcessOwner.close_stdin(started.io)

    locker =
      spawn(fn ->
        Store.transaction(db, fn _conn ->
          send(parent, {ref, :writer_lock_held})

          receive do
            {^ref, :release_writer_lock} -> :ok
          end
        end)
      end)

    assert_receive {^ref, :writer_lock_held}, @timeout
    # Previously the poller called Store.transaction/2 here. Its BEGIN
    # IMMEDIATE collided with this lock, raised "SQLite writer busy", and the
    # GenServer removed its stream files before CodexExec could finalize.
    Process.sleep(100)
    assert Process.alive?(started.io.pid)
    send(locker, {ref, :release_writer_lock})

    assert_receive {:process_owner_io, _handle, :stdout, _chunk}, @timeout
    assert_receive {:process_owner_io, _handle, :stderr, _chunk}, @timeout
    assert {:ok, output} = await_io_output(started.io, &String.contains?(&1.stdout, "first\nsecond\n"))
    assert output.stderr == "diagnostic\n"
    assert {:ok, 17} = await_exit_status(started.io)

    # output/1 synchronously drains files after the unit is inactive; the
    # owner remains usable until explicit ProcessOwner cleanup.
    assert {:ok, final} = ProcessOwner.output(started.io)
    assert final.stdout == "first\nsecond\n"
    assert final.stderr == "diagnostic\n"
    assert {:ok, 17} = ProcessOwner.exit_status(started.io)
    assert Process.alive?(started.io.pid)

    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    refute Process.alive?(started.io.pid)
  end

  test "ProcessOwner rejects malformed I/O ownership and buffer requests", %{db: db, sandbox: sandbox} do
    assert {:blocked, :execution_owner_required} =
             ProcessOwner.start_io(db, %{execution_id: "bad"}, sleep_program(), sandbox)

    {:execute, execution} = Runner.prepare(db, "feature")

    assert {:blocked, :invalid_io_buffer_limit} =
             ProcessOwner.start_io(db, execution, sleep_program(), sandbox, max_buffer_bytes: 0)

    assert status(db, execution.execution_id) == "terminated"
    assert {:blocked, :invalid_io_handle} = ProcessOwner.output(%{})

    invalid_id = %{execution | execution_id: "contains/a-slash"}

    assert {:blocked, :invalid_execution_id} =
             ProcessOwner.start_io(db, invalid_id, sleep_program(), sandbox)
  end

  test "a lost VM-local I/O owner reports unavailable and cleans only its own resources", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start_io(db, execution, sleep_program(), sandbox)

    assert {:blocked, :execution_owner_required} = ProcessOwnerIO.valid_execution_owner(:not_an_execution)
    assert {:blocked, :io_owner_unavailable} = ProcessOwner.output(%{started.io | pid: :not_a_pid})

    GenServer.stop(started.io.pid, :normal)
    refute Process.alive?(started.io.pid)
    assert {:blocked, :io_owner_unavailable} = ProcessOwner.output(started.io)

    # Losing an in-VM stream reader never adopts or releases the unit. The
    # regular ProcessOwner cgroup cancellation path remains authoritative.
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
  end

  test "ProcessOwner I/O does not publish a replaced execution", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")

    assert {:ok, started} =
             ProcessOwner.start_io(db, execution, delayed_unowned_output_program(), sandbox, subscriber: self())

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE attempts SET execution_id = 'replacement', execution_owner = 'replacement-owner' WHERE feature_id = ? AND revision = ?", [execution.feature_id, execution.revision])
    end)

    assert {:blocked, {:stale_execution, _}} = ProcessOwner.write_stdin(started.io, "must not reach old execution")
    assert {:blocked, {:stale_execution, _}} = ProcessOwner.output(started.io)
    handle = started.io
    refute_receive {:process_owner_io, ^handle, :stdout, _chunk}, 500
    assert {:ok, "stale-output\n"} = File.read(started.io.paths.stdout)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
  end

  test "ProcessOwner bounds large CLI stdout without retaining an unbounded capture", %{db: db, sandbox: sandbox} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start_io(db, execution, large_cli_program(), sandbox, max_buffer_bytes: 256)
    assert :ok = ProcessOwner.close_stdin(started.io)

    assert {:ok, output} = await_io_output(started.io, fn value -> value.stdout_truncated? end)
    assert byte_size(output.stdout) <= 256
    assert output.stdout_truncated?
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
  end

  test "Codex auth is disposable, private, and removed only by ProcessOwner termination", %{db: db, output: output, workspace: workspace} do
    codex_output = Path.join(output, "codex-success")
    File.mkdir_p!(codex_output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: codex_output, runtime: db)
    {:execute, execution} = prepare_execution(db, "codex-success")

    assert {:ok, started} =
             ProcessOwner.start_io(
               db,
               execution,
               %{executable: "/opt/codex/bin/codex", args: ["--version"]},
               sandbox
             )

    auth = Path.join(codex_output, "home/.codex/auth.json")
    assert File.regular?(auth)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(auth)
    assert band(mode, 0o777) == 0o600
    assert {:ok, 0} = await_exit_status(started.io)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    refute File.exists?(auth)
    refute File.exists?(Path.dirname(auth))
  end

  test "Codex auth is cleaned after a non-zero exit and recovery", %{db: db, output: output, workspace: workspace} do
    nonzero_output = Path.join(output, "codex-nonzero")
    File.mkdir_p!(nonzero_output)
    {:ok, nonzero_sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: nonzero_output, runtime: db)
    {:execute, nonzero_execution} = prepare_execution(db, "codex-nonzero")

    assert {:ok, nonzero} =
             ProcessOwner.start_io(
               db,
               nonzero_execution,
               %{executable: "/opt/codex/bin/codex", args: ["not-a-codex-command"]},
               nonzero_sandbox
             )

    auth = Path.join(nonzero_output, "home/.codex/auth.json")
    assert File.regular?(auth)
    assert {:ok, status} = await_exit_status(nonzero.io)
    assert status != 0
    assert :ok = ProcessOwner.cancel(db, nonzero_execution.execution_id)
    refute File.exists?(auth)

    recovery_output = Path.join(output, "codex-recovery")
    File.mkdir_p!(recovery_output)
    {:ok, recovery_sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: recovery_output, runtime: db)
    {:execute, recovery_execution} = prepare_execution(db, "codex-recovery")

    assert {:ok, _started} =
             ProcessOwner.start_io(
               db,
               recovery_execution,
               %{executable: "/opt/codex/bin/codex", args: ["exec", "--json", "-"]},
               recovery_sandbox
             )

    recovery_auth = Path.join(recovery_output, "home/.codex/auth.json")
    assert File.regular?(recovery_auth)
    assert :ok = ProcessOwner.recover(db)
    refute File.exists?(recovery_auth)
  end

  test "Codex homes are single-execution directories", %{db: db, output: output, workspace: workspace} do
    codex_output = Path.join(output, "codex-one")
    second_output = Path.join(output, "codex-two")
    File.mkdir_p!(codex_output)
    File.mkdir_p!(second_output)
    {:ok, first_sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: codex_output, runtime: db)
    {:ok, second_sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: second_output, runtime: db)
    {:ok, first_home} = Sandbox.codex_auth_dir(first_sandbox)
    {:ok, second_home} = Sandbox.codex_auth_dir(second_sandbox)
    refute first_home == second_home

    {:execute, first_execution} = prepare_execution(db, "codex-home-one")

    assert {:ok, _started} =
             ProcessOwner.start_io(
               db,
               first_execution,
               %{executable: "/opt/codex/bin/codex", args: ["--version"]},
               first_sandbox
             )

    assert :ok = ProcessOwner.cancel(db, first_execution.execution_id)
    {:execute, second_execution} = prepare_execution(db, "codex-home-two")
    first_execution_id = first_execution.execution_id

    assert {:blocked, {:codex_output_reused, ^first_execution_id}} =
             ProcessOwner.start_io(
               db,
               second_execution,
               %{executable: "/opt/codex/bin/codex", args: ["--version"]},
               first_sandbox
             )
  end

  test "auth provisioning failure after durable intent is cleaned through ProcessOwner", %{db: db, output: output, workspace: workspace} do
    codex_output = Path.join(output, "codex-home-not-empty")
    File.mkdir_p!(codex_output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: codex_output, runtime: db)
    File.write!(Path.join(codex_output, "home/stale"), "must not be reused")
    {:execute, execution} = prepare_execution(db, "codex-home-not-empty")

    assert {:blocked, :codex_home_reused} =
             ProcessOwner.start_io(
               db,
               execution,
               %{executable: "/opt/codex/bin/codex", args: ["--version"]},
               sandbox
             )

    assert status(db, execution.execution_id) == "terminated"
    refute File.exists?(Path.join(codex_output, "home/.codex/auth.json"))
  end

  test "Codex ProcessOwner start also provisions and cleans auth", %{db: db, output: output, workspace: workspace} do
    codex_output = Path.join(output, "codex-start")
    File.mkdir_p!(codex_output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: codex_output, runtime: db)
    {:execute, execution} = prepare_execution(db, "codex-start")

    assert {:ok, _started} =
             ProcessOwner.start(
               db,
               execution,
               %{executable: "/opt/codex/bin/codex", args: ["--version"]},
               sandbox
             )

    auth = Path.join(codex_output, "home/.codex/auth.json")
    assert File.regular?(auth)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    refute File.exists?(auth)
  end

  test "corrupt persisted auth cleanup metadata fails closed", %{db: db, output: output} do
    {:execute, execution} = prepare_execution(db, "codex-invalid-cleanup")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(
        conn,
        "UPDATE process_executions SET sandbox_output = ?, auth_dir = ? WHERE execution_id = ?",
        [output, Path.join(output, "not-codex"), execution.execution_id]
      )
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:auth_cleanup_failed, ^execution_id, :invalid_auth_cleanup_path}} = ProcessOwner.recover(db)
    assert status(db, execution.execution_id) == "ambiguous"
  end

  test "Codex auth remains until an explicit cancellation confirms termination", %{db: db, output: output, workspace: workspace} do
    codex_output = Path.join(output, "codex-cancel")
    File.mkdir_p!(codex_output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: codex_output, runtime: db)
    {:execute, execution} = prepare_execution(db, "codex-cancel")

    assert {:ok, _started} =
             ProcessOwner.start_io(
               db,
               execution,
               %{executable: "/opt/codex/bin/codex", args: ["exec", "--json", "-"]},
               sandbox
             )

    auth = Path.join(codex_output, "home/.codex/auth.json")
    assert File.regular?(auth)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    refute File.exists?(auth)
  end

  test "Codex auth is not removed when cgroup termination cannot be confirmed", %{db: db, output: output, workspace: workspace} do
    codex_output = Path.join(output, "codex-unconfirmed")
    File.mkdir_p!(codex_output)
    {:ok, sandbox} = Sandbox.profile(role: :codex, workspace: workspace, output: codex_output, runtime: db)
    {:execute, execution} = prepare_execution(db, "codex-unconfirmed")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)
    assert :ok = Sandbox.provision_codex_auth(sandbox)
    auth = Path.join(codex_output, "home/.codex/auth.json")
    assert File.regular?(auth)

    Store.transaction(db, fn conn ->
      Store.execute(
        conn,
        "UPDATE process_executions SET sandbox_output = ?, auth_dir = ?, control_group = '/' WHERE execution_id = ?",
        [codex_output, Path.join(codex_output, "home/.codex"), execution.execution_id]
      )
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:cgroup_not_empty, ^execution_id}} = ProcessOwner.recover(db)
    assert File.regular?(auth)
    File.rm_rf!(Path.dirname(auth))
  end

  defp large_cli_program do
    %{
      executable: System.find_executable("python3") || raise("python3 is required for controlled test subprocesses"),
      args: ["-c", "import sys; sys.stdin.read(); sys.stdout.write('x' * 4096); sys.stdout.flush()"]
    }
  end

  defp cli_program do
    %{
      executable: System.find_executable("python3") || raise("python3 is required for controlled test subprocesses"),
      args: [
        "-c",
        """
        import sys
        prompt = sys.stdin.read()
        sys.stdout.write(prompt[:5])
        sys.stdout.flush()
        sys.stdout.write(prompt[5:])
        sys.stdout.flush()
        sys.stderr.write('diagnostic\\n')
        sys.stderr.flush()
        sys.exit(23)
        """
      ]
    }
  end

  defp delayed_cli_program do
    %{
      executable: System.find_executable("python3") || raise("python3 is required for controlled test subprocesses"),
      args: [
        "-c",
        """
        import sys, time
        sys.stdin.read()
        sys.stdout.write('first\\n')
        sys.stdout.flush()
        time.sleep(0.15)
        sys.stderr.write('diagnostic\\n')
        sys.stderr.flush()
        time.sleep(0.15)
        sys.stdout.write('second\\n')
        sys.stdout.flush()
        time.sleep(0.15)
        sys.exit(17)
        """
      ]
    }
  end

  defp delayed_unowned_output_program do
    %{
      executable: System.find_executable("python3") || raise("python3 is required for controlled test subprocesses"),
      args: ["-c", "import sys, time; time.sleep(0.15); sys.stdout.write('stale-output\\n'); sys.stdout.flush(); time.sleep(0.3)"]
    }
  end

  defp await_io_output(handle, predicate), do: await_io_output(handle, predicate, 100)

  defp await_io_output(_handle, _predicate, 0), do: flunk("timed out waiting for ProcessOwner output")

  defp await_io_output(handle, predicate, attempts) do
    case ProcessOwner.output(handle) do
      {:ok, output} ->
        if predicate.(output) do
          {:ok, output}
        else
          Process.sleep(50)
          await_io_output(handle, predicate, attempts - 1)
        end

      _ ->
        Process.sleep(50)
        await_io_output(handle, predicate, attempts - 1)
    end
  end

  defp await_exit_status(handle), do: await_exit_status(handle, 100)

  defp await_exit_status(_handle, 0), do: flunk("timed out waiting for ProcessOwner exit status")

  defp await_exit_status(handle, attempts) do
    case ProcessOwner.exit_status(handle) do
      {:ok, :running} ->
        Process.sleep(50)
        await_exit_status(handle, attempts - 1)

      result ->
        result
    end
  end

  defp program(ignore_term?) do
    %{
      executable: System.find_executable("python3") || raise("python3 is required for controlled test subprocesses"),
      args: ["-c", python_program(), if(ignore_term?, do: "ignore", else: "default")]
    }
  end

  defp sleep_program, do: %{executable: "/bin/sleep", args: ["infinity"]}

  defp start(db, sandbox, execution, command), do: ProcessOwner.start(db, execution, command, sandbox)

  defp python_program do
    """
    import os, signal, sys
    if sys.argv[1] == 'ignore':
        signal.signal(signal.SIGTERM, lambda *_: None)
    child = os.fork()
    role = 'child' if child == 0 else 'parent'
    with open('/output/pids', 'a') as pids:
        pids.write(role + ':' + str(os.getpid()))
        pids.write(chr(10))
    while True:
        signal.pause()
    """
  end

  defp await_processes(output), do: await_processes(output, 100)

  defp await_processes(output, attempts) do
    case File.read(Path.join(output, "pids")) do
      {:ok, contents} ->
        processes =
          contents
          |> String.split("\n", trim: true)
          |> Enum.map(fn line ->
            [_role, pid] = String.split(line, ":", parts: 2)
            String.to_integer(pid)
          end)

        if length(processes) == 2, do: processes, else: retry_processes(output, attempts)

      {:error, :enoent} ->
        retry_processes(output, attempts)
    end
  end

  defp retry_processes(_output, 0), do: flunk("timed out waiting for sandbox subprocesses")

  defp retry_processes(output, attempts) do
    Process.sleep(50)
    await_processes(output, attempts - 1)
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

  defp status(db, execution_id) do
    Store.transaction(db, fn conn ->
      [[status]] = Store.execute(conn, "SELECT status FROM process_executions WHERE execution_id = ?", [execution_id])
      status
    end)
  end

  defp prepare_execution(db, feature_id) do
    Runner.create(db, feature_id, "Approved specification")
    Runner.prepare(db, feature_id)
  end

  defp active_owner_vm(db) do
    root = db |> Path.dirname() |> Path.dirname()
    workspace = Path.join(root, "workspace")
    output = Path.join(root, "output")

    open_vm(
      """
      alias SymphonyElixir.Feature.{ProcessOwner, Sandbox}
      alias SymphonyElixir.FeatureRunner, as: R
      [db, workspace, output, ready] = System.argv()
      {:execute, execution} = R.prepare(db, "feature")
      {:ok, sandbox} = Sandbox.profile(role: :test, workspace: workspace, output: output, runtime: db)
      {:ok, _} = ProcessOwner.start(db, execution, %{executable: "/bin/sleep", args: ["infinity"]}, sandbox)
      IO.puts(ready)
      Process.sleep(:infinity)
      """,
      [db, workspace, output, "READY"]
    )
  end

  defp intent_only_vm(db) do
    open_vm(
      """
      alias SymphonyElixir.Feature.ProcessOwner
      alias SymphonyElixir.FeatureRunner, as: R
      [db, ready] = System.argv()
      {:execute, execution} = R.prepare(db, "feature")
      {:ok, _} = ProcessOwner.intent(db, execution)
      IO.puts(ready)
      Process.sleep(:infinity)
      """,
      [db, "INTENDED"]
    )
  end

  defp open_vm(code, args) do
    exe = System.find_executable("elixir") || raise "elixir executable not found"
    paths = :code.get_path() |> Enum.map(&List.to_string/1) |> Enum.flat_map(&["-pa", &1])
    Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: paths ++ ["-e", code, "--" | args]])
  end

  defp await(port, marker, output \\ "") do
    receive do
      {^port, {:data, data}} ->
        output = output <> data
        if String.contains?(output, marker), do: :ok, else: await(port, marker, output)

      {^port, {:exit_status, status}} ->
        flunk("VM exited before marker #{status}: #{output}")
    after
      @timeout -> flunk("timed out waiting for VM marker: #{output}")
    end
  end

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
    after
      @timeout -> flunk("timed out stopping VM")
    end
  end
end
