Code.require_file("../../support/feature_reliability.ex", __DIR__)

defmodule SymphonyElixir.Feature.AcceptanceProcessTest do
  @moduledoc "Real systemd/cgroup contracts; requires user systemd, bwrap and Python 3. No model execution."
  use ExUnit.Case, async: false
  @moduletag :acceptance_reliability
  @moduletag timeout: 30_000

  alias SymphonyElixir.Feature.{Git, ProcessOwner, Sandbox}
  alias SymphonyElixir.FeatureRunner, as: Runner
  alias SymphonyElixir.FeatureReliabilitySupport, as: Fixture

  setup do
    Fixture.fixture()
  end

  for kind <- ["role", "validation"] do
    @tag execution_kind: kind
    test "#{kind} replacement cannot start while an earlier launch may still materialize", c do
      kind = c.execution_kind
      function = if kind == "role", do: :start_io, else: :start
      {:ok, identity} = Git.candidate_identity(c.workspace, Fixture.git(c.workspace, ["rev-parse", "HEAD"]))
      metadata = %{execution_kind: kind, operation_key: "validation:fixture", candidate_sha: identity.sha, candidate_tree: identity.tree}
      # The external program stays alive until teardown. No timing sleep is
      # needed to keep the process observable during recovery/replacement.
      command = %{executable: "/bin/sleep", args: ["infinity"]}

      body = """
      {:execute, execution} = Runner.prepare(runtime, "feature")
      output = Path.join(root, "first-output")
      File.mkdir_p!(output)
      {:ok, sandbox} = Sandbox.profile(role: :test, workspace: config.workspace, output: output, runtime: runtime)
      ProcessOwner.#{function}(runtime, Map.merge(execution, #{inspect(metadata)}), #{inspect(command)}, sandbox)
      """

      port = Fixture.start_coordinator(c, :before_launch, body)
      Fixture.await_boundary(c)
      [[first_id, first_unit]] = Fixture.rows(c, "SELECT execution_id, unit_name FROM process_executions")
      Fixture.kill_coordinator(c, port)

      recovery = ProcessOwner.recover_execution(c.runtime, first_id)
      [[previous_status]] = Fixture.rows(c, "SELECT status FROM process_executions WHERE execution_id = ?", [first_id])

      replacement =
        case Runner.prepare_recovery(c.runtime, "feature") do
          {:execute, execution} ->
            output = Path.join(c.root, "second-output")
            File.mkdir_p!(output)
            {:ok, sandbox} = Sandbox.profile(role: :test, workspace: c.workspace, output: output, runtime: c.runtime)
            apply(ProcessOwner, function, [c.runtime, Map.merge(execution, metadata), command, sandbox])

          other ->
            other
        end

      Fixture.proceed(c)
      # Observe either a late unit or termination of the delayed launcher.
      # A fixed owner may safely kill that launcher instead of starting a unit.
      Fixture.eventually(fn -> active?(first_unit) or not wrappers_alive?(c) end)
      late? = active?(first_unit)

      refute previous_status == "terminated" and late?,
             "confirmed termination before late #{kind} unit materialized; recovery=#{inspect(recovery)}, replacement=#{elem(replacement, 0)}"

      refute match?({:ok, _}, replacement) and late?, "both executions were admitted concurrently"
    end
  end

  test "a successful validator exiting before identity inspection remains recoverable", c do
    sha = Fixture.git(c.workspace, ["rev-parse", "HEAD"])

    body = """
    result = Validation.run(runtime, "feature",
      %{key: "fast", purpose: "review", repository: config.workspace, sha: #{inspect(sha)}},
      %{executable: "/bin/true", args: []}, Path.join(root, "validation-checkout"), 2_000,
      %{operation_key: "validation:fast", revision: 0, output_root: config.output_root})
    Fixture.emit_result(root, result)
    """

    port = Fixture.start_coordinator(c, :after_validator_exit, body)
    # The wrapper observes the real validator exit before releasing metadata
    # inspection. It neither stubs systemctl nor guesses a scheduling delay.
    Fixture.await_boundary(c)
    Fixture.proceed(c)
    Fixture.await_exit(port)
    result = Fixture.result(c)
    assert result["outcome"] == "ok"
    assert result["value"]["status"] == "passed", inspect(result)
    assert Fixture.rows(c, "SELECT status FROM process_executions") == [["terminated"]]
  end

  defp active?(unit) do
    {state, _} = Fixture.command("systemctl", ["--user", "show", unit, "-p", "ActiveState", "--value"])
    String.trim(state) in ["active", "activating", "deactivating"]
  end

  defp wrappers_alive?(c) do
    Path.wildcard(Path.join(c.root, "wrappers/*.owner"))
    |> Enum.any?(fn path ->
      [pid, _token] = path |> File.read!() |> String.split()

      case File.read("/proc/#{pid}/stat") do
        {:ok, stat} -> not String.contains?(stat, ") Z ")
        _ -> false
      end
    end)
  end
end
