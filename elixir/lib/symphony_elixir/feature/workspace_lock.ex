defmodule SymphonyElixir.Feature.WorkspaceLock do
  @moduledoc """
  Host-local durable ownership fence for a canonical developer workspace.

  SQLite protects one journal. This lock file protects the same workspace when
  separate journals run on the same host. It is deliberately persistent: a
  coordinator restart may reacquire its own fence, while another journal fails
  closed until the owner explicitly releases it.
  """

  @lock_root Path.join(System.tmp_dir!(), "symphony-feature-runner-workspace-locks")

  @spec acquire(Path.t(), Path.t(), String.t()) :: :ok | {:blocked, term()}
  def acquire(workspace, runtime, feature_id) when is_binary(workspace) and is_binary(runtime) and is_binary(feature_id) do
    with {:ok, owner} <- owner(workspace, runtime, feature_id),
         :ok <- File.mkdir_p(@lock_root) do
      case File.open(lock_path(owner["workspace"]), [:write, :exclusive]) do
        {:ok, io} ->
          try do
            :ok = IO.binwrite(io, Jason.encode!(owner))
            :ok
          after
            File.close(io)
          end

        {:error, :eexist} ->
          acquire_existing(lock_path(owner["workspace"]), owner)

        {:error, reason} ->
          {:blocked, {:workspace_lock_unavailable, reason}}
      end
    else
      {:error, reason} -> {:blocked, {:workspace_lock_unavailable, reason}}
    end
  end

  def acquire(_, _, _), do: {:blocked, :invalid_workspace_lock_owner}

  @doc "Confirms that the persistent host lock is still owned by this feature."
  @spec owned?(Path.t(), Path.t(), String.t()) :: :ok | {:blocked, term()}
  def owned?(workspace, runtime, feature_id) when is_binary(workspace) and is_binary(runtime) and is_binary(feature_id) do
    case owner(workspace, runtime, feature_id) do
      {:ok, expected} -> existing_owner(lock_path(expected["workspace"]), expected)
      {:error, reason} -> {:blocked, {:workspace_lock_unconfirmed, reason}}
    end
  end

  def owned?(_, _, _), do: {:blocked, :invalid_workspace_lock_owner}

  @spec release(Path.t(), Path.t(), String.t()) :: :ok | {:blocked, term()}
  def release(workspace, runtime, feature_id) when is_binary(workspace) and is_binary(runtime) and is_binary(feature_id) do
    case owner(workspace, runtime, feature_id) do
      {:ok, owner} -> release_owned_lock(lock_path(owner["workspace"]), owner)
      {:error, reason} -> {:blocked, {:workspace_lock_release_unconfirmed, reason}}
    end
  end

  def release(_, _, _), do: {:blocked, :invalid_workspace_lock_owner}

  defp owner(workspace, runtime, feature_id) do
    with {:ok, canonical_workspace} <- canonical_path(workspace),
         {:ok, canonical_runtime} <- canonical_path(runtime),
         {:ok, runtime_inode} <- runtime_inode(runtime) do
      {:ok, %{"workspace" => canonical_workspace, "runtime" => canonical_runtime, "runtime_inode" => runtime_inode, "feature_id" => feature_id}}
    end
  end

  defp runtime_inode(runtime) do
    case File.stat(runtime) do
      {:ok, %{inode: inode}} -> {:ok, inode}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_path(path) do
    if File.exists?(path) do
      case System.cmd("realpath", [Path.expand(path)], stderr_to_stdout: true) do
        {resolved, 0} -> {:ok, String.trim(resolved)}
        {_output, status} -> {:error, {:realpath_failed, status}}
      end
    else
      {:error, :enoent}
    end
  rescue
    _ -> {:error, :realpath_unavailable}
  end

  defp lock_path(workspace) do
    key = :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower)
    Path.join(@lock_root, key <> ".lock")
  end

  defp existing_owner(path, owner) do
    with {:ok, encoded} <- File.read(path),
         {:ok, existing} <- Jason.decode(encoded),
         true <- existing == owner do
      :ok
    else
      false -> {:blocked, :workspace_owned_by_another_journal}
      {:error, :enoent} -> {:blocked, :workspace_lock_unconfirmed}
      _ -> {:blocked, :workspace_lock_unconfirmed}
    end
  end

  defp release_owned_lock(path, owner) do
    with :ok <- existing_owner(path, owner) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:blocked, {:workspace_lock_release_unconfirmed, reason}}
      end
    end
  end

  defp acquire_existing(path, owner) do
    with {:ok, encoded} <- File.read(path),
         {:ok, existing} <- Jason.decode(encoded) do
      acquire_decoded_lock(path, owner, existing)
    else
      {:error, :enoent} -> acquire_owner_lock(owner)
      _ -> {:blocked, :workspace_lock_unconfirmed}
    end
  end

  defp acquire_decoded_lock(_path, owner, owner), do: :ok

  defp acquire_decoded_lock(path, owner, %{"runtime" => runtime, "runtime_inode" => inode}) do
    if File.exists?(runtime) do
      if owner["runtime"] == runtime and owner["runtime_inode"] != inode,
        do: replace_stale_lock(path, owner),
        else: {:blocked, :workspace_owned_by_another_journal}
    else
      replace_stale_lock(path, owner)
    end
  end

  defp acquire_decoded_lock(_path, _owner, _existing), do: {:blocked, :workspace_lock_unconfirmed}

  defp replace_stale_lock(path, owner) do
    case File.rm(path) do
      :ok -> acquire_owner_lock(owner)
      {:error, :enoent} -> acquire_owner_lock(owner)
      {:error, reason} -> {:blocked, {:workspace_lock_unavailable, reason}}
    end
  end

  defp acquire_owner_lock(owner), do: acquire(owner["workspace"], owner["runtime"], owner["feature_id"])
end
