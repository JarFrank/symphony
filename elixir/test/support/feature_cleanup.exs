defmodule SymphonyElixir.FeatureTestCleanup do
  @moduledoc false
  import ExUnit.Assertions

  alias SymphonyElixir.Feature.ProcessOwner.IO, as: ProcessIO
  alias SymphonyElixir.Feature.{Store, WorkspaceLock}

  # Called before removing each fixture's private root. Never enumerate or stop
  # unrelated host units: the fixture's journal supplies their exact identities.
  def cleanup(root) do
    for runtime <- Path.wildcard(Path.join(root, "**/*.sqlite3")), Store.ensure_compatible(runtime) == :ok do
      records = Store.read(runtime, &Store.execute(&1, "SELECT execution_id, unit_name, control_group FROM process_executions"))
      Enum.each(records, &cleanup_execution(runtime, &1))

      for [workspace, feature_id] <- Store.read(runtime, &Store.execute(&1, "SELECT workspace, feature_id FROM workspace_ownership")) do
        WorkspaceLock.release(workspace, runtime, feature_id)
      end
    end

    # Some adversarial tests deliberately corrupt/delete the claim or journal.
    # The private mktemp root still proves which lock files the fixture owns.
    for lock <- Path.wildcard(Path.join(System.tmp_dir!(), "symphony-feature-runner-workspace-locks/*.lock")) do
      with {:ok, json} <- File.read(lock),
           {:ok, %{"runtime" => runtime}} <- Jason.decode(json),
           true <- String.starts_with?(runtime, Path.expand(root) <> "/") do
        File.rm!(lock)
      end
    end
  end

  defp cleanup_execution(runtime, [id, unit, group]) do
    ProcessIO.stop(runtime, id)

    if unit == "symphony-feature-#{id}.service" do
      System.cmd("systemctl", ["--user", "stop", unit], stderr_to_stdout: true)
      System.cmd("systemctl", ["--user", "reset-failed", unit], stderr_to_stdout: true)
      {state, _} = System.cmd("systemctl", ["--user", "show", unit, "-p", "LoadState", "--value"], stderr_to_stdout: true)
      assert String.trim(state) == "not-found"

      if is_binary(group) and String.starts_with?(group, "/") and not String.contains?(group, <<0>>) and group != "/" do
        assert File.read(Path.join(["/sys/fs/cgroup", group, "cgroup.procs"])) in [{:ok, ""}, {:error, :enoent}]
      end
    end
  end
end
