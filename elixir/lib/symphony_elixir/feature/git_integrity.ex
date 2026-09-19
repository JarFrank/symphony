defmodule SymphonyElixir.Feature.GitIntegrity do
  @moduledoc "Compares live tracked bytes and modes with an immutable Git tree, without consulting the index."

  alias SymphonyElixir.Feature.GitCommand

  @spec verify(Path.t(), String.t()) :: :ok | {:blocked, term()}
  def verify(repository, sha) do
    with {:ok, entries} <- GitCommand.run(repository, ["ls-tree", "-r", "-z", sha]),
         {:ok, format} <- GitCommand.run(repository, ["rev-parse", "--show-object-format"]),
         {:ok, algorithm} <- algorithm(format) do
      verify_entries(repository, entries, algorithm)
    end
  rescue
    _ -> {:blocked, :workspace_integrity_unconfirmed}
  end

  defp verify_entries(repository, entries, algorithm) do
    entries
    |> String.split(<<0>>, trim: true)
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case verify_entry(repository, entry, algorithm) do
        :ok -> {:cont, :ok}
        blocked -> {:halt, blocked}
      end
    end)
  end

  defp algorithm("sha1"), do: {:ok, :sha}
  defp algorithm("sha256"), do: {:ok, :sha256}
  defp algorithm(_), do: {:blocked, :unsupported_git_object_format}

  defp verify_entry(repository, entry, algorithm) do
    [metadata, relative] = String.split(entry, "\t", parts: 2)
    [mode, type, expected] = String.split(metadata, " ")
    path = Path.join(repository, relative)

    with true <- type == "blob" and safe_parents?(repository, Path.split(relative)),
         {:ok, stat} <- File.lstat(path),
         {:ok, actual} <- blob(path, stat, mode, algorithm),
         true <- actual == expected do
      :ok
    else
      _ -> {:blocked, {:tracked_file_integrity_mismatch, relative}}
    end
  end

  # A parent symlink must not redirect a tracked read outside the tree.
  defp safe_parents?(_root, [_file]), do: true

  defp safe_parents?(root, [part | rest]) when part not in [".", ".."] do
    next = Path.join(root, part)
    match?({:ok, %{type: :directory}}, File.lstat(next)) and safe_parents?(next, rest)
  end

  defp safe_parents?(_, _), do: false

  defp blob(path, %{type: :regular, size: size, mode: actual_mode}, mode, algorithm) when mode in ["100644", "100755"] do
    executable = Bitwise.band(actual_mode, 0o111) != 0

    if executable == (mode == "100755") do
      initial = :crypto.hash_init(algorithm) |> :crypto.hash_update("blob #{size}\0")
      hash = path |> File.stream!(64 * 1024) |> Enum.reduce(initial, &:crypto.hash_update(&2, &1))
      {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}
    else
      {:error, :mode_mismatch}
    end
  end

  defp blob(path, %{type: :symlink}, "120000", algorithm) do
    with {:ok, target} <- File.read_link(path) do
      {:ok, :crypto.hash(algorithm, ["blob #{byte_size(target)}\0", target]) |> Base.encode16(case: :lower)}
    end
  end

  defp blob(_, _, _, _), do: {:error, :type_mismatch}
end
