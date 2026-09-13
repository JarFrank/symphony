defmodule SymphonyElixir.FeatureRunnerRecoveryTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Feature.Store
  alias SymphonyElixir.FeatureRunner, as: Runner
  @timeout 5_000

  setup do
    dir = Path.join(System.tmp_dir!(), "feature-recovery-#{System.unique_integer([:positive])}")
    db = Path.join(dir, "state.sqlite3")
    Store.init(db)
    Runner.create(db, "feature", "Approved specification")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{db: db, dir: dir}
  end

  test "recorded developer output is applied after a BEAM VM is terminated", %{db: db} do
    stall(
      """
      alias SymphonyElixir.Feature.Fake
      alias SymphonyElixir.FeatureRunner, as: R
      [db, ready] = System.argv()
      R.step(db, "feature", Fake.executor("mastermind", Fake.plan()))
      R.capture(db, "feature", Fake.executor("developer", %{"status" => "completed", "sha" => "sha1"}))
      wait.(ready)
      """,
      [db]
    )

    {state, output} =
      fresh(
        """
        alias SymphonyElixir.FeatureRunner, as: R
        [db] = System.argv()
        emit.(R.step(db, "feature", forbidden))
        """,
        [db]
      )

    refute output =~ "EXECUTED:"
    assert state["phase"] == "Reviewing"
    assert state["head"] == "sha1"
    assert attempts(db) == [[0, "applied"], [1, "applied"]]
  end

  test "WaitingForHuman remains idle after a BEAM VM is terminated", %{db: db} do
    stall(
      """
      alias SymphonyElixir.Feature.Fake
      alias SymphonyElixir.FeatureRunner, as: R
      [db, ready] = System.argv()
      R.step(db, "feature", Fake.executor("mastermind", Fake.plan()))
      R.step(db, "feature", Fake.executor("developer", %{"status" => "technical_question", "question" => "Contract?"}))
      R.step(db, "feature", Fake.executor("mastermind", %{"status" => "human_decision_required", "question" => "Choose contract"}))
      wait.(ready)
      """,
      [db]
    )

    {state, output} =
      fresh(
        """
        alias SymphonyElixir.FeatureRunner, as: R
        [db] = System.argv()
        emit.(R.step(db, "feature", forbidden))
        """,
        [db]
      )

    refute output =~ "EXECUTED:"
    assert state["phase"] == "WaitingForHuman"
  end

  test "external fake effect is reconciled after confirmation is lost", %{db: db, dir: dir} do
    external = Path.join(dir, "external-effect")

    stall(
      """
      alias SymphonyElixir.Feature.Effects
      [db, external, ready] = System.argv()
      Effects.intent(db, "feature", "create-pr", %{"kind" => "create_pr"})
      Effects.run(db, "feature", "create-pr", fn _, _ -> :missing end, fn _, _ ->
        File.write!(external, "created-once")
        wait.(ready)
      end)
      """,
      [db, external]
    )

    assert File.read!(external) == "created-once"

    {value, output} =
      fresh(
        """
        alias SymphonyElixir.Feature.Effects
        [db, external] = System.argv()
        emit.(Effects.run(db, "feature", "create-pr", fn _, _ ->
          {:found, %{"pr" => File.read!(external)}}
        end, forbidden))
        """,
        [db, external]
      )

    refute output =~ "EXECUTED:"
    assert value == %{"pr" => "created-once"}
    assert File.read!(external) == "created-once"
    assert effect_status(db) == "completed"
  end

  test "restart after prepare fences the dead VM and records a new execution", %{db: db} do
    stall(
      """
      alias SymphonyElixir.FeatureRunner, as: R
      [db, ready] = System.argv()
      R.prepare(db, "feature")
      wait.(ready)
      """,
      [db]
    )

    {state, output} =
      fresh(
        """
        alias SymphonyElixir.Feature.Fake
        alias SymphonyElixir.FeatureRunner, as: R
        [db] = System.argv()
        emit.(R.step(db, "feature", Fake.executor("mastermind", Fake.plan())))
        """,
        [db]
      )

    refute output =~ "EXECUTED:"
    assert state["phase"] == "Implementing"
    assert attempts(db) == [[0, "applied"]]
  end

  defp stall(code, args) do
    ready = "READY:#{System.unique_integer([:positive])}"
    port = open_vm(code, args ++ [ready])
    await(port, ready)
    {:os_pid, pid} = Port.info(port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-TERM", Integer.to_string(pid)])
    await_exit(port)
  end

  defp fresh(code, args) do
    port = open_vm(code, args)
    {status, output} = read_all(port)
    assert status == 0, output
    [_, encoded] = Regex.run(~r/RESULT:([A-Za-z0-9+\/=]+)/, output)
    {:erlang.binary_to_term(Base.decode64!(encoded)), output}
  end

  defp open_vm(code, args) do
    exe = System.find_executable("elixir") || raise "elixir executable not found"

    prelude =
      "wait = fn ready -> IO.puts(ready); Process.sleep(:infinity) end; forbidden = fn role, _ -> IO.puts(\"EXECUTED:\#{role}\"); raise \"must not execute\" end; emit = fn value -> IO.puts(\"RESULT:\" <> Base.encode64(:erlang.term_to_binary(value))) end; "

    paths = :code.get_path() |> Enum.map(&List.to_string/1) |> Enum.flat_map(&["-pa", &1])
    Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: paths ++ ["-e", prelude <> code, "--" | args]])
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

  defp read_all(port, output \\ "") do
    receive do
      {^port, {:data, data}} -> read_all(port, output <> data)
      {^port, {:exit_status, status}} -> {status, output}
    after
      @timeout -> flunk("timed out waiting for VM: #{output}")
    end
  end

  defp attempts(db), do: Store.transaction(db, &Store.execute(&1, "SELECT revision, status FROM attempts ORDER BY revision"))

  defp effect_status(db),
    do: Store.transaction(db, &Store.execute(&1, "SELECT status FROM effects WHERE feature_id = ? AND operation_key = ?", ["feature", "create-pr"])) |> then(fn [[status]] -> status end)
end
