defmodule SymphonyElixir.Feature.SandboxTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.{ProcessOwner, Sandbox, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "feature-sandbox-#{System.unique_integer([:positive])}")
    runtime_dir = Path.join(root, "coordinator-runtime")
    runtime = Path.join(runtime_dir, "state.sqlite3")
    developer = Path.join(root, "developer")
    developer_output = Path.join(root, "developer-output")
    reviewer = Path.join(root, "reviewer")
    reviewer_output = Path.join(root, "reviewer-output")

    File.mkdir_p!(runtime_dir)
    File.mkdir_p!(developer)
    File.mkdir_p!(developer_output)
    File.mkdir_p!(reviewer)
    File.mkdir_p!(reviewer_output)
    File.mkdir_p!(Path.join(developer, ".git"))
    File.mkdir_p!(Path.join(reviewer, ".git"))
    File.write!(runtime, "coordinator-secret")
    File.write!(Path.join(developer, "developer.txt"), "developer-original")
    File.write!(Path.join(reviewer, "reviewer.txt"), "reviewer-input")

    {:ok, developer_profile} =
      Sandbox.profile(role: :developer, workspace: developer, output: developer_output, runtime: runtime)

    {:ok, reviewer_profile} =
      Sandbox.profile(
        role: :reviewer,
        workspace: reviewer,
        output: reviewer_output,
        runtime: runtime,
        developer_workspace: developer
      )

    on_exit(fn -> File.rm_rf!(root) end)

    %{
      developer: developer,
      developer_output: developer_output,
      developer_profile: developer_profile,
      reviewer: reviewer,
      reviewer_profile: reviewer_profile,
      root: root,
      runtime: runtime
    }
  end

  test "developer sees neither coordinator data nor host publication credentials and can write only allowed directories", context do
    previous = host_secrets()

    try do
      System.put_env("GITHUB_TOKEN", "host-github-token")
      System.put_env("LINEAR_API_TOKEN", "host-linear-token")
      System.put_env("SSH_AUTH_SOCK", "/run/user/1000/ssh-agent.sock")

      {output, 0} =
        run(
          context.developer_profile,
          context.runtime,
          security_program(),
          [context.runtime, context.developer]
        )

      assert output == "isolated\n"
      assert File.read!(Path.join(context.developer, "workspace-write")) == "ok"
      assert File.read!(Path.join(context.developer_output, "output-write")) == "ok"
    after
      restore_host_secrets(previous)
    end
  end

  test "reviewer runs in its own prepared checkout and cannot modify developer workspace", context do
    {output, 0} =
      run(
        context.reviewer_profile,
        context.runtime,
        reviewer_program(),
        [context.developer]
      )

    assert output == "reviewed\n"
    assert File.read!(Path.join(context.reviewer, "reviewer-write")) == "ok"
    assert File.read!(Path.join(context.developer, "developer.txt")) == "developer-original"
  end

  test "only the explicit Codex profile shares network and mounts the approved runtime inputs", context do
    codex_output = Path.join(context.root, "codex-output")
    File.mkdir_p!(codex_output)

    assert {:ok, codex} =
             Sandbox.profile(role: :codex, workspace: context.developer, output: codex_output, runtime: context.runtime)

    assert {:ok, ordinary} = Sandbox.wrap(context.developer_profile, context.runtime, %{executable: "/bin/true", args: []})
    assert {:ok, codex_command} = Sandbox.wrap(codex, context.runtime, %{executable: "/opt/codex/bin/codex", args: ["--version"]})

    refute "--share-net" in ordinary.args
    assert "--unshare-net" in ordinary.args
    assert "--share-net" in codex_command.args
    refute "--unshare-net" in codex_command.args

    assert [
             "--ro-bind",
             "/home/jarek/.local/share/mise/installs/node/22.23.2/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex",
             "/opt/codex/bin/codex"
           ] in Enum.chunk_every(codex_command.args, 3, 1, :discard)

    assert ["--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf"] in Enum.chunk_every(codex_command.args, 3, 1, :discard)
    assert ["--ro-bind", "/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/certs/ca-certificates.crt"] in Enum.chunk_every(codex_command.args, 3, 1, :discard)
    refute "/home/jarek" in codex_command.args
    refute "/home/jarek/.codex/auth.json" in codex_command.args
    assert ["--setenv", "HOME", "/output/home"] in Enum.chunk_every(codex_command.args, 3, 1, :discard)
    assert ["--setenv", "CODEX_HOME", "/output/home/.codex"] in Enum.chunk_every(codex_command.args, 3, 1, :discard)

    assert {:error, :invalid_codex_command} =
             Sandbox.wrap(codex, context.runtime, %{executable: "/bin/true", args: []})

    assert {:error, :sandbox_profile_changed} =
             Sandbox.provision_codex_auth(%{codex | codex_binary: "/not-an-approved-codex"})

    assert {:error, :not_codex_profile} = Sandbox.codex_auth_dir(context.developer_profile)
  end

  test "profiles reject overlapping coordinator paths and reviewer requires a distinct prepared checkout", context do
    File.mkdir_p!(Path.join(context.root, "another-output"))

    assert {:error, :sandbox_paths_overlap} =
             Sandbox.profile(
               role: :developer,
               workspace: Path.dirname(context.runtime),
               output: context.developer_output,
               runtime: context.runtime
             )

    assert {:error, {:sandbox_directory_missing, :output}} =
             Sandbox.profile(
               role: :reviewer,
               workspace: context.reviewer,
               output: Path.join(context.root, "other-output"),
               runtime: context.runtime
             )

    assert {:error, :sandbox_paths_overlap} =
             Sandbox.profile(
               role: :reviewer,
               workspace: context.developer,
               output: context.reviewer |> Path.dirname() |> Path.join("another-output"),
               runtime: context.runtime,
               developer_workspace: context.developer
             )
  end

  test "raw ProcessOwner launch paths and mismatched runtime profiles fail closed", context do
    execution = %{attempt_id: "attempt", execution_id: "execution", feature_id: "feature", revision: 1}

    assert {:blocked, :sandbox_required} =
             ProcessOwner.start(context.runtime, execution, %{executable: "/bin/true", args: []})

    assert {:blocked, :sandbox_required} =
             ProcessOwner.launch(context.runtime, execution.execution_id, %{executable: "/bin/true", args: []})

    other_runtime = Path.join(context.root, "other.sqlite3")
    File.write!(other_runtime, "other")

    assert {:error, :coordinator_runtime_mismatch} =
             Sandbox.wrap(context.developer_profile, other_runtime, %{executable: "/bin/true", args: []})
  end

  test "missing bwrap fails closed before a ProcessOwner intent is recorded", context do
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", "/missing-bwrap")

    try do
      assert {:error, :bwrap_unavailable} =
               Sandbox.wrap(context.developer_profile, context.runtime, %{executable: "/bin/true", args: []})
    after
      System.put_env("PATH", previous_path)
    end

    db = Path.join(context.root, "state.sqlite3")
    Store.init(db)

    assert {:ok, profile} =
             Sandbox.profile(
               role: :test,
               workspace: context.developer,
               output: context.developer_output,
               runtime: db
             )

    System.put_env("PATH", "/missing-bwrap")

    try do
      assert {:blocked, :bwrap_unavailable} =
               ProcessOwner.start(
                 db,
                 %{attempt_id: "attempt", execution_id: "execution", feature_id: "feature", revision: 1},
                 %{executable: "/bin/true", args: []},
                 profile
               )

      assert ProcessOwner.current(db) == []
    after
      System.put_env("PATH", previous_path)
    end
  end

  test "missing systemd fails closed before a ProcessOwner intent is recorded", context do
    tools = Path.join(context.root, "bwrap-only")
    File.mkdir_p!(tools)
    File.ln_s!(System.find_executable("bwrap"), Path.join(tools, "bwrap"))
    File.ln_s!(System.find_executable("readlink"), Path.join(tools, "readlink"))
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", tools)

    try do
      assert {:blocked, :systemd_unavailable} =
               ProcessOwner.start(
                 context.runtime,
                 %{attempt_id: "attempt", execution_id: "execution", feature_id: "feature", revision: 1},
                 %{executable: "/bin/true", args: []},
                 context.developer_profile
               )
    after
      System.put_env("PATH", previous_path)
    end
  end

  defp run(profile, runtime, program, args) do
    {:ok, command} =
      Sandbox.wrap(profile, runtime, %{
        executable: System.find_executable("python3") || raise("python3 is required for sandbox smoke tests"),
        args: ["-c", program | args]
      })

    System.cmd(command.executable, command.args, stderr_to_stdout: true)
  end

  defp security_program do
    """
    import os
    import pathlib
    import subprocess
    import sys

    runtime, developer = sys.argv[1:]
    assert not pathlib.Path(runtime).exists()
    assert os.environ.get("GITHUB_TOKEN") is None
    assert os.environ.get("LINEAR_API_TOKEN") is None
    assert os.environ.get("SSH_AUTH_SOCK") is None
    assert not pathlib.Path("/run/user/1000/ssh-agent.sock").exists()
    assert not pathlib.Path("/home/jarek/.ssh/id_ed25519").exists()
    assert os.environ["GIT_CONFIG_GLOBAL"] == "/dev/null"
    assert os.environ["GIT_CONFIG_NOSYSTEM"] == "1"
    assert os.environ["GIT_SSH_COMMAND"] == "/bin/false"
    assert subprocess.run(["git", "config", "--show-origin", "--get", "credential.helper"]).returncode == 1

    for blocked in ("/outside", "/tmp/outside", developer + "/developer-escape"):
        try:
            pathlib.Path(blocked).write_text("no")
            raise AssertionError(blocked + " unexpectedly writable")
        except OSError:
            pass

    pathlib.Path("/workspace/workspace-write").write_text("ok")
    pathlib.Path("/output/output-write").write_text("ok")
    print("isolated")
    """
  end

  defp reviewer_program do
    """
    import pathlib
    import sys

    developer = sys.argv[1]
    assert pathlib.Path("/workspace/reviewer.txt").read_text() == "reviewer-input"

    try:
        pathlib.Path(developer + "/developer.txt").write_text("changed")
        raise AssertionError("developer workspace unexpectedly writable")
    except OSError:
        pass

    pathlib.Path("/workspace/reviewer-write").write_text("ok")
    print("reviewed")
    """
  end

  defp host_secrets do
    for key <- ["GITHUB_TOKEN", "LINEAR_API_TOKEN", "SSH_AUTH_SOCK"], into: %{} do
      {key, System.get_env(key)}
    end
  end

  defp restore_host_secrets(secrets) do
    Enum.each(secrets, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  test "invalid profiles and commands are rejected before execution", context do
    assert {:error, :invalid_sandbox_profile} = Sandbox.profile(:invalid)
    assert {:error, :invalid_sandbox_profile} = Sandbox.wrap(%{}, context.runtime, %{executable: "/bin/true", args: []})

    assert {:error, :invalid_role} =
             Sandbox.profile(
               role: :publisher,
               workspace: context.developer,
               output: context.developer_output,
               runtime: context.runtime
             )

    assert {:error, :developer_workspace_not_allowed} =
             Sandbox.profile(
               role: :developer,
               workspace: context.developer,
               output: context.developer_output,
               runtime: context.runtime,
               developer_workspace: context.reviewer
             )

    assert {:error, :invalid_sandbox_path} =
             Sandbox.profile(
               role: :developer,
               workspace: :not_a_path,
               output: context.developer_output,
               runtime: context.runtime
             )

    workspace_file = Path.join(context.root, "workspace-file")
    File.write!(workspace_file, "not a directory")

    assert {:error, {:sandbox_directory_missing, :workspace}} =
             Sandbox.profile(
               role: :developer,
               workspace: workspace_file,
               output: context.developer_output,
               runtime: context.runtime
             )

    missing_runtime = Path.join(context.root, "missing.sqlite3")

    assert {:error, {:sandbox_path_missing, :runtime}} =
             Sandbox.profile(
               role: :developer,
               workspace: context.developer,
               output: context.developer_output,
               runtime: missing_runtime
             )

    no_checkout = Path.join(context.root, "no-checkout")
    File.mkdir_p!(no_checkout)

    assert {:error, :reviewer_requires_prepared_checkout} =
             Sandbox.profile(role: :reviewer, workspace: context.reviewer, output: Path.join(context.root, "reviewer-output"), runtime: context.runtime, developer_workspace: no_checkout)

    assert {:error, :invalid_sandbox_command} =
             Sandbox.wrap(context.developer_profile, context.runtime, %{executable: "/bin/true", args: [1]})

    assert {:error, :sandbox_profile_changed} =
             Sandbox.wrap(%{context.developer_profile | root: context.reviewer}, context.runtime, %{executable: "/bin/true", args: []})
  end
end
