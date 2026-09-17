defmodule SymphonyElixir.Feature.WorkspaceLockTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Feature.WorkspaceLock

  setup do
    root = Path.join(System.tmp_dir!(), "workspace-lock-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    runtime_a = Path.join(root, "runtime-a.sqlite3")
    runtime_b = Path.join(root, "runtime-b.sqlite3")
    File.mkdir_p!(workspace)
    File.write!(runtime_a, "a")
    File.write!(runtime_b, "b")

    on_exit(fn ->
      File.rm_rf!(lock_path(workspace))
      File.rm_rf!(root)
    end)

    %{workspace: workspace, runtime_a: runtime_a, runtime_b: runtime_b}
  end

  test "only the journal-feature owner can retain and release a host workspace lock", context do
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")

    assert {:blocked, :workspace_owned_by_another_journal} =
             WorkspaceLock.acquire(context.workspace, context.runtime_b, "feature-b")

    assert {:blocked, :workspace_owned_by_another_journal} =
             WorkspaceLock.release(context.workspace, context.runtime_b, "feature-b")

    assert :ok = WorkspaceLock.release(context.workspace, context.runtime_a, "feature-a")
  end

  test "a lock whose durable journal disappeared is reclaimed by a new owner", context do
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    File.rm!(context.runtime_a)
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_b, "feature-b")
    assert :ok = WorkspaceLock.release(context.workspace, context.runtime_b, "feature-b")
  end

  test "a recreated journal at the same path does not inherit an old inode", context do
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    File.rm!(context.runtime_a)
    File.write!(context.runtime_a, "replacement journal")
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-b")
    assert :ok = WorkspaceLock.release(context.workspace, context.runtime_a, "feature-b")
  end

  test "invalid or unreadable lock ownership fails closed", context do
    assert {:blocked, :invalid_workspace_lock_owner} =
             WorkspaceLock.acquire(:invalid, context.runtime_a, "feature-a")

    assert {:blocked, :invalid_workspace_lock_owner} =
             WorkspaceLock.release(context.workspace, context.runtime_a, :invalid)

    assert {:blocked, {:workspace_lock_unavailable, _}} =
             WorkspaceLock.acquire(Path.join(context.workspace, "missing"), context.runtime_a, "feature-a")

    assert {:blocked, {:workspace_lock_release_unconfirmed, _}} =
             WorkspaceLock.release(Path.join(context.workspace, "missing"), context.runtime_a, "feature-a")

    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.release(context.workspace, context.runtime_a, "feature-a")

    lock = lock_path(context.workspace)

    File.mkdir_p!(Path.dirname(lock))
    File.write!(lock, "not-json")
    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.release(context.workspace, context.runtime_a, "feature-a")

    File.write!(lock, Jason.encode!(%{"unknown" => true}))
    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
  end

  test "lock filesystem and canonicalization failures fail closed", context do
    lock = lock_path(context.workspace)
    File.mkdir_p!(lock)
    assert {:blocked, :workspace_lock_unconfirmed} = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    File.rmdir!(lock)

    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", "/missing-workspace-lock-test-path")

    try do
      assert {:blocked, {:workspace_lock_unavailable, :realpath_unavailable}} =
               WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    after
      System.put_env("PATH", previous_path)
    end
  end

  test "a release that cannot remove its lock stays blocked", context do
    assert :ok = WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    root = lock_path(context.workspace) |> Path.dirname()
    File.chmod!(root, 0o500)

    try do
      assert {:blocked, {:workspace_lock_release_unconfirmed, _}} =
               WorkspaceLock.release(context.workspace, context.runtime_a, "feature-a")
    after
      File.chmod!(root, 0o700)
    end
  end

  test "an unavailable lock directory prevents acquisition", context do
    root = lock_path(context.workspace) |> Path.dirname()
    File.mkdir_p!(root)
    File.chmod!(root, 0o500)

    try do
      assert {:blocked, {:workspace_lock_unavailable, _}} =
               WorkspaceLock.acquire(context.workspace, context.runtime_a, "feature-a")
    after
      File.chmod!(root, 0o700)
    end
  end

  defp lock_path(workspace) do
    key = :crypto.hash(:sha256, Path.expand(workspace)) |> Base.encode16(case: :lower)
    Path.join([System.tmp_dir!(), "symphony-feature-runner-workspace-locks", key <> ".lock"])
  end
end
