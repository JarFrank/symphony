defmodule SymphonyElixir.Feature.ProcessOwnerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{ProcessOwner, Store}
  alias SymphonyElixir.FeatureRunner, as: Runner

  @timeout 5_000

  setup do
    dir = Path.join(System.tmp_dir!(), "process-owner-#{System.unique_integer([:positive])}")
    db = Path.join(dir, "state.sqlite3")
    Store.init(db)
    Runner.create(db, "feature", "Approved specification")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: db}
  end

  test "cancellation terminates a subprocess and its child", %{db: db} do
    listener = listen()
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start(db, execution, program(listener, false))
    processes = await_processes(listener)

    assert Enum.all?(processes, &alive?/1)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    refute Enum.any?(processes, &alive?/1)
    assert status(db, execution.execution_id) == "terminated"
    assert started.invocation_id != ""
    assert started.control_group != ""
  end

  test "TERM-ignoring subprocess tree is force terminated within the unit bound", %{db: db} do
    listener = listen()
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _started} = ProcessOwner.start(db, execution, program(listener, true))
    processes = await_processes(listener)

    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
    refute Enum.any?(processes, &alive?/1)
    assert status(db, execution.execution_id) == "terminated"
  end

  test "a new VM recovers a live execution before starting the next writer", %{db: db} do
    port = active_owner_vm(db)
    await(port, "READY")
    {:os_pid, vm_pid} = Port.info(port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(vm_pid)])
    await_exit(port)

    [old] = ProcessOwner.current(db)
    assert :ok = ProcessOwner.recover(db)
    assert status(db, old.execution_id) == "terminated"

    {:execute, next_execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start(db, next_execution, sleep_program())
    assert :ok = ProcessOwner.cancel(db, started.execution_id)
  end

  test "an intent left by a dead VM before start metadata is reconciled safely", %{db: db} do
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
    assert {:ok, started} = ProcessOwner.start(db, next_execution, sleep_program())
    assert :ok = ProcessOwner.cancel(db, started.execution_id)
  end

  test "mismatched invocation identity is never treated as the current writer", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start(db, execution, sleep_program())

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET invocation_id = 'stale-invocation' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:process_identity_mismatch, ^execution_id, _}} = ProcessOwner.recover(db)
    assert status(db, execution.execution_id) == "ambiguous"

    Runner.create(db, "second", "Approved specification")
    {:execute, next_execution} = Runner.prepare(db, "second")
    assert {:blocked, {:ambiguous_execution, ^execution_id}} = ProcessOwner.start(db, next_execution, sleep_program())

    assert {_, 0} = System.cmd("systemctl", ["--user", "stop", started.unit_name])
  end

  test "an ambiguous prior liveness record blocks another writer", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET status = 'ambiguous' WHERE execution_id = ?", [execution.execution_id])
    end)

    Runner.create(db, "second", "Approved specification")
    {:execute, next_execution} = Runner.prepare(db, "second")
    execution_id = execution.execution_id
    assert {:blocked, {:ambiguous_execution, ^execution_id}} = ProcessOwner.start(db, next_execution, sleep_program())
  end

  test "invalid, vanished and unidentifiable units fail closed", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")

    assert {:blocked, {:unknown_execution, "missing"}} = ProcessOwner.launch(db, "missing", sleep_program())
    assert_raise ArgumentError, "invalid controlled subprocess command", fn -> ProcessOwner.launch(db, execution.execution_id, %{}) end
    assert :ok = ProcessOwner.cancel(db, "missing")

    assert {:ok, _intent} = ProcessOwner.intent(db, execution)
    assert {:error, {:systemd_run_failed, _}} = ProcessOwner.launch(db, execution.execution_id, %{executable: "/not-a-program", args: []})
    assert :ok = ProcessOwner.recover(db)
    assert :ok = ProcessOwner.cancel(db, execution.execution_id)
  end

  test "unobservable liveness blocks another writer", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start(db, execution, sleep_program())
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

  test "mismatched unit name is never treated as the current writer", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET unit_name = 'other.service' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:process_identity_mismatch, ^execution_id, :unit_name}} = ProcessOwner.recover(db)
  end

  test "a nonempty recorded cgroup cannot be considered terminated", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, _intent} = ProcessOwner.intent(db, execution)

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET control_group = '/' WHERE execution_id = ?", [execution.execution_id])
    end)

    execution_id = execution.execution_id
    assert {:blocked, {:cgroup_not_empty, ^execution_id}} = ProcessOwner.recover(db)
  end

  test "active unit with only durable intent is stopped during recovery", %{db: db} do
    {:execute, execution} = Runner.prepare(db, "feature")
    assert {:ok, started} = ProcessOwner.start(db, execution, sleep_program())

    Store.transaction(db, fn conn ->
      Store.execute(conn, "UPDATE process_executions SET status = 'intended', invocation_id = NULL, control_group = NULL, main_pid = NULL WHERE execution_id = ?", [execution.execution_id])
    end)

    assert :ok = ProcessOwner.recover(db)
    assert status(db, execution.execution_id) == "terminated"
    refute alive?(started.main_pid)
  end

  defp listen do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    listener
  end

  defp program(listener, ignore_term?) do
    {:ok, {_address, port}} = :inet.sockname(listener)

    %{
      executable: System.find_executable("python3") || raise("python3 is required for controlled test subprocesses"),
      args: ["-c", python_program(), Integer.to_string(port), if(ignore_term?, do: "ignore", else: "default")]
    }
  end

  defp sleep_program, do: %{executable: "/bin/sleep", args: ["infinity"]}

  defp python_program do
    """
    import os, signal, socket, sys
    if sys.argv[2] == 'ignore':
        signal.signal(signal.SIGTERM, lambda *_: None)
    child = os.fork()
    role = 'child' if child == 0 else 'parent'
    sock = socket.socket()
    sock.connect(('127.0.0.1', int(sys.argv[1])))
    sock.sendall((role + ':' + str(os.getpid())).encode())
    sock.close()
    while True:
        signal.pause()
    """
  end

  defp await_processes(listener), do: [await_process(listener), await_process(listener)]

  defp await_process(listener) do
    assert {:ok, socket} = :gen_tcp.accept(listener, @timeout)
    assert {:ok, message} = :gen_tcp.recv(socket, 0, @timeout)
    :gen_tcp.close(socket)
    [_role, pid] = String.split(message, ":", parts: 2)
    String.to_integer(pid)
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true))

  defp status(db, execution_id) do
    Store.transaction(db, fn conn ->
      [[status]] = Store.execute(conn, "SELECT status FROM process_executions WHERE execution_id = ?", [execution_id])
      status
    end)
  end

  defp active_owner_vm(db) do
    open_vm(
      """
      alias SymphonyElixir.Feature.{ProcessOwner, Store}
      alias SymphonyElixir.FeatureRunner, as: R
      [db, ready] = System.argv()
      {:execute, execution} = R.prepare(db, "feature")
      {:ok, _} = ProcessOwner.start(db, execution, %{executable: "/bin/sleep", args: ["infinity"]})
      IO.puts(ready)
      Process.sleep(:infinity)
      """,
      [db, "READY"]
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
