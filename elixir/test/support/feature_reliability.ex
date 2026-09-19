defmodule SymphonyElixir.FeatureReliabilitySupport do
  @moduledoc false
  import ExUnit.Assertions

  alias SymphonyElixir.Feature.ProcessOwner.IO, as: ProcessIO
  alias SymphonyElixir.Feature.{Store, WorkspaceLock}
  alias SymphonyElixir.FeatureRunner, as: Runner

  @support __ENV__.file
  @wrapper Path.expand("../fixtures/feature_reliability_command.py", __DIR__)
  @git_environment %{"GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_SYSTEM" => "/dev/null"}

  def fixture do
    {root, 0} = System.cmd("mktemp", ["-d", Path.join(System.tmp_dir!(), "feature-reliability-XXXXXX")])
    root = String.trim(root)
    old_env = Map.new(@git_environment, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(@git_environment)

    ExUnit.Callbacks.on_exit(fn ->
      try do
        cleanup(root)
      after
        Enum.each(old_env, &restore_environment/1)
      end
    end)

    config = config(root)
    File.mkdir_p!(config.workspace)
    File.mkdir_p!(Path.join(root, "wrappers"))
    git(config.workspace, ["-c", "init.templateDir=", "init", "-b", config.expected_branch])
    git(config.workspace, ["config", "--local", "user.name", "Reliability Fixture"])
    git(config.workspace, ["config", "--local", "user.email", "fixture@example.test"])
    File.write!(Path.join(config.workspace, "source.txt"), "baseline\n")
    git(config.workspace, ["add", "."])
    git(config.workspace, ["commit", "-m", "baseline"])
    git(config.workspace, ["commit", "--allow-empty", "-m", "baseline parent"])
    :ok = Store.init(runtime(root))
    Runner.create(runtime(root), "feature", "Approved two-task fixture")
    %{root: root, runtime: runtime(root), workspace: config.workspace, config: config}
  end

  def runtime(root), do: Path.join(root, "runtime/state.sqlite3")

  def config(root) do
    workspace = Path.join(root, "workspace")

    %{
      workspace: workspace,
      expected_branch: "feature/reliability",
      reviewer_root: Path.join(root, "reviewers"),
      output_root: Path.join(root, "outputs"),
      validator: fn _ -> :ok end,
      executor: fn assignment ->
        result =
          case assignment.role do
            "mastermind" ->
              %{"status" => "planned", "tasks" => Enum.map(["first", "second"], &%{"id" => &1, "scope" => "Implement #{&1}", "acceptance" => "Validation passes"})}

            "developer" ->
              File.write!(Path.join(workspace, "source.txt"), assignment.execution_id <> "\n")
              %{"status" => "completed"}

            "reviewer" ->
              %{"status" => "approved"}
          end

        envelope(assignment, result)
      end
    }
  end

  def envelope(assignment, result) do
    result = %{"attempt_id" => assignment.attempt_id, "execution_id" => assignment.execution_id, "role" => assignment.role, "task_id" => assignment.task_id, "result" => result}
    if assignment.role == "reviewer", do: Map.put(result, "reviewed_sha", assignment.reviewed_sha), else: result
  end

  def rows(context, sql, params \\ []), do: Store.read(context.runtime, &Store.execute(&1, sql, params))

  def git(workspace, args) do
    {output, status} = command("git", ["-C", workspace | args])
    assert status == 0, output
    String.trim(output)
  end

  def command(executable, args) do
    System.cmd("timeout", ["--signal=KILL", "8s", executable | args], stderr_to_stdout: true)
  end

  # Only the child coordinator receives the wrapper PATH. Other tests and
  # recovery in this VM continue to use real host commands.
  def start_coordinator(context, mode, body) do
    names =
      case mode do
        mode when mode in [:before_launch, :after_validator_exit] -> ["systemd-run"]
        :before_release -> ["realpath"]
        _ -> ["git"]
      end

    commands = Map.new(names, &{&1, System.find_executable(&1)})
    settings = %{mode: mode, commands: commands, systemctl: System.find_executable("systemctl")}
    File.write!(Path.join(context.root, "command-boundary.json"), Jason.encode!(settings))

    Enum.each(names, fn name ->
      path = Path.join([context.root, "wrappers", name])
      File.cp!(@wrapper, path)
      File.chmod!(path, 0o700)
    end)

    code = """
    Code.require_file(#{inspect(@support)})
    alias SymphonyElixir.FeatureReliabilitySupport, as: Fixture
    alias SymphonyElixir.Feature.{LocalRunner, ProcessOwner, Sandbox, Store, Validation}
    alias SymphonyElixir.FeatureRunner, as: Runner
    root = #{inspect(context.root)}
    runtime = Fixture.runtime(root)
    config = Fixture.config(root)
    #{body}
    """

    paths = :code.get_path() |> Enum.flat_map(&["-pa", List.to_string(&1)])
    env = [{~c"PATH", String.to_charlist(Path.join(context.root, "wrappers") <> ":" <> System.fetch_env!("PATH"))}, {~c"FEATURE_ACCEPTANCE_ROOT", String.to_charlist(context.root)}]
    port = Port.open({:spawn_executable, System.find_executable("elixir")}, [:binary, :exit_status, :stderr_to_stdout, args: paths ++ ["--erl", "+S 2:2", "-e", code], env: env])
    {:os_pid, pid} = Port.info(port, :os_pid)
    save_owner(Path.join(context.root, "coordinator.owner"), pid)
    port
  end

  def await_boundary(context) do
    path = Path.join(context.root, "boundary.json")
    eventually(fn -> match?({:ok, _}, read_json(path)) end)
    {:ok, value} = read_json(path)
    value
  end

  def proceed(context), do: File.write!(Path.join(context.root, "proceed"), "continue")

  def kill_coordinator(context, port) do
    kill_owner(Path.join(context.root, "coordinator.owner"), false)
    await_exit(port, false)
  end

  def stop_wrappers(context), do: Enum.each(Path.wildcard(Path.join(context.root, "wrappers/*.owner")), &kill_owner(&1, true))

  def await_exit(port, success? \\ true, output \\ "") do
    receive do
      {^port, {:data, chunk}} -> await_exit(port, success?, output <> chunk)
      {^port, {:exit_status, status}} -> if success?, do: assert(status == 0, output)
    after
      6_000 -> flunk("coordinator did not exit: #{output}")
    end
  end

  def emit_result(root, {outcome, value}) do
    File.write!(Path.join(root, "result.json"), Jason.encode!(%{outcome: outcome, value: if(is_map(value), do: value, else: inspect(value))}))
  end

  def result(context), do: context.root |> Path.join("result.json") |> File.read!() |> Jason.decode!()

  def eventually(fun, timeout \\ 5_000), do: poll(fun, System.monotonic_time(:millisecond) + timeout)

  defp poll(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "fixture synchronization timed out"
      Process.sleep(10)
      poll(fun, deadline)
    end
  end

  defp read_json(path) do
    with {:ok, content} <- File.read(path), do: Jason.decode(content)
  end

  defp save_owner(path, pid) do
    File.write!(path, "#{pid} #{start_token(pid)}")
  end

  defp start_token(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ", parts: 2) |> List.last() |> String.split() |> Enum.at(19)
      _ -> nil
    end
  end

  defp kill_owner(path, group?) do
    if File.exists?(path) do
      [pid, token] = path |> File.read!() |> String.split()

      kill_matching_owner(pid, token, group?)
    end
  end

  defp kill_matching_owner(pid, token, group?) do
    if start_token(pid) == token do
      command("kill", ["-KILL", "--", if(group?, do: "-" <> pid, else: pid)])
      eventually(fn -> start_token(pid) != token or zombie?(pid) end)
    end
  end

  defp restore_environment({key, nil}), do: System.delete_env(key)
  defp restore_environment({key, value}), do: System.put_env(key, value)

  defp zombie?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> String.contains?(stat, ") Z ")
      _ -> false
    end
  end

  defp cleanup(root) do
    kill_owner(Path.join(root, "coordinator.owner"), false)
    stop_wrappers(%{root: root})
    runtime = runtime(root)
    records = if File.exists?(runtime), do: Store.read(runtime, &Store.execute(&1, "SELECT execution_id, unit_name FROM process_executions")), else: []
    units = Enum.map(records, &List.last/1) ++ Enum.map(Path.wildcard(Path.join(root, "wrappers/*.unit")), &File.read!/1)

    units
    |> Enum.uniq()
    |> Enum.reject(&String.ends_with?(&1, ".callback"))
    |> Enum.each(fn unit ->
      {group, _} = command("systemctl", ["--user", "show", unit, "-p", "ControlGroup", "--value"])
      group = String.trim(group)
      command("systemctl", ["--user", "stop", unit])
      command("systemctl", ["--user", "reset-failed", unit])

      eventually(fn ->
        {state, _} = command("systemctl", ["--user", "show", unit, "-p", "ActiveState", "--value"])
        String.trim(state) == "inactive"
      end)

      if String.starts_with?(group, "/") do
        eventually(fn -> File.read(Path.join(["/sys/fs/cgroup", group, "cgroup.procs"])) in [{:ok, ""}, {:error, :enoent}] end)
      end
    end)

    Enum.each(records, fn [id, _] -> ProcessIO.stop(runtime, id) end)
    workspace = Path.join(root, "workspace")
    if File.exists?(runtime), do: WorkspaceLock.release(workspace, runtime, "feature")
    # All worktrees and their Git admin directory are under this mktemp root.
    File.rm_rf!(root)
    refute File.exists?(root)
  end
end
