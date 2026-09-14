defmodule SymphonyElixir.Feature.Sandbox do
  @moduledoc """
  Builds the fail-closed bubblewrap boundary used by controlled feature roles.

  The coordinator keeps its journal and every host credential outside the
  sandbox. A role sees only a read-only runtime, its own workspace and its
  explicitly assigned output directory.
  """

  defmodule Profile do
    @moduledoc false

    @enforce_keys [:role, :workspace, :output, :runtime, :root, :developer_workspace]
    defstruct [:role, :workspace, :output, :runtime, :root, :developer_workspace]
  end

  @type role :: :developer | :reviewer | :test
  @type command :: %{executable: String.t(), args: [String.t()]}
  @type profile :: Profile.t()

  @base_environment %{
    "GIT_ASKPASS" => "/bin/false",
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_SYSTEM" => "/dev/null",
    "GIT_SSH_COMMAND" => "/bin/false",
    "GIT_TERMINAL_PROMPT" => "0",
    "HOME" => "/output/home",
    "LANG" => "C.UTF-8",
    "LC_ALL" => "C.UTF-8",
    "PATH" => "/usr/local/bin:/usr/bin:/bin",
    "SSH_ASKPASS" => "/bin/false",
    "TEMP" => "/output/tmp",
    "TMP" => "/output/tmp",
    "TMPDIR" => "/output/tmp",
    "XDG_CACHE_HOME" => "/output/cache",
    "XDG_CONFIG_HOME" => "/output/config",
    "XDG_STATE_HOME" => "/output/state"
  }

  @root_directories ~w(bin dev lib lib64 output proc usr workspace)

  @spec profile(keyword()) :: {:ok, profile()} | {:error, term()}
  def profile(options) when is_list(options) do
    with {:ok, role} <- role(Keyword.get(options, :role)),
         {:ok, workspace} <- directory(:workspace, Keyword.get(options, :workspace)),
         {:ok, output} <- directory(:output, Keyword.get(options, :output)),
         {:ok, runtime} <- path(:runtime, Keyword.get(options, :runtime)),
         {:ok, root} <- sandbox_root(runtime),
         {:ok, developer_workspace} <- developer_workspace(role, Keyword.get(options, :developer_workspace)),
         :ok <- isolated_paths(workspace, output, runtime, root, developer_workspace),
         :ok <- prepare_output(output) do
      {:ok,
       %Profile{
         role: role,
         workspace: workspace,
         output: output,
         runtime: runtime,
         root: root,
         developer_workspace: developer_workspace
       }}
    end
  end

  def profile(_), do: {:error, :invalid_sandbox_profile}

  @spec wrap(profile(), Path.t(), command()) :: {:ok, command()} | {:error, term()}
  def wrap(%Profile{} = profile, coordinator_runtime, command) do
    with {:ok, bwrap} <- bwrap(),
         :ok <- valid_profile(profile),
         {:ok, runtime} <- path(:runtime, coordinator_runtime),
         :ok <- same_runtime(profile.runtime, runtime),
         :ok <- command(command) do
      {:ok, %{executable: bwrap, args: bwrap_args(profile, command)}}
    end
  end

  def wrap(_, _, _), do: {:error, :invalid_sandbox_profile}

  defp bwrap do
    case System.find_executable("bwrap") do
      nil -> {:error, :bwrap_unavailable}
      executable -> {:ok, executable}
    end
  end

  defp bwrap_args(profile, command) do
    [
      "--new-session",
      "--unshare-all",
      "--clearenv",
      "--cap-drop",
      "ALL",
      "--ro-bind",
      profile.root,
      "/",
      "--ro-bind",
      "/usr",
      "/usr",
      "--ro-bind",
      "/usr/bin",
      "/bin",
      "--ro-bind",
      "/usr/lib",
      "/lib",
      "--ro-bind",
      "/usr/lib64",
      "/lib64",
      "--dev",
      "/dev",
      "--proc",
      "/proc",
      "--bind",
      profile.workspace,
      "/workspace",
      "--bind",
      profile.output,
      "/output",
      "--chdir",
      "/workspace"
    ] ++ environment_args() ++ ["--", command.executable | command.args]
  end

  defp environment_args do
    @base_environment
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} -> ["--setenv", key, value] end)
  end

  defp valid_profile(%Profile{} = profile) do
    with {:ok, workspace} <- directory(:workspace, profile.workspace),
         {:ok, output} <- directory(:output, profile.output),
         {:ok, runtime} <- path(:runtime, profile.runtime),
         {:ok, root} <- sandbox_root(runtime),
         {:ok, developer_workspace} <- developer_workspace(profile.role, profile.developer_workspace),
         :ok <- isolated_paths(workspace, output, runtime, root, developer_workspace),
         true <-
           workspace == profile.workspace and output == profile.output and runtime == profile.runtime and root == profile.root and
             developer_workspace == profile.developer_workspace do
      :ok
    else
      false -> {:error, :sandbox_profile_changed}
      {:error, _} = error -> error
    end
  end

  defp role(role) when role in [:developer, :reviewer, :test], do: {:ok, role}
  defp role(_), do: {:error, :invalid_role}

  defp developer_workspace(:reviewer, value) do
    with {:ok, workspace} <- directory(:developer_workspace, value),
         true <- File.exists?(Path.join(workspace, ".git")) do
      {:ok, workspace}
    else
      false -> {:error, :reviewer_requires_prepared_checkout}
      {:error, _} = error -> error
    end
  end

  defp developer_workspace(_role, nil), do: {:ok, nil}
  defp developer_workspace(_role, _value), do: {:error, :developer_workspace_not_allowed}

  defp directory(_name, value) when not is_binary(value), do: {:error, :invalid_sandbox_path}

  defp directory(name, value) do
    with {:ok, resolved} <- resolve(value),
         true <- File.dir?(resolved) do
      {:ok, resolved}
    else
      false -> {:error, {:sandbox_directory_missing, name}}
      {:error, _} = error -> error
    end
  end

  defp path(_name, value) when not is_binary(value), do: {:error, :invalid_sandbox_path}

  defp path(name, value) do
    with {:ok, resolved} <- resolve(value),
         true <- File.exists?(resolved) do
      {:ok, resolved}
    else
      false -> {:error, {:sandbox_path_missing, name}}
      {:error, _} = error -> error
    end
  end

  defp resolve(value) do
    case System.cmd("readlink", ["-f", "--", Path.expand(value)], stderr_to_stdout: true) do
      {resolved, 0} -> {:ok, String.trim(resolved)}
      {_output, _status} -> {:error, :sandbox_path_unresolved}
    end
  rescue
    _error -> {:error, :sandbox_path_unresolved}
  end

  defp sandbox_root(runtime) do
    root = Path.join(Path.dirname(runtime), "sandbox-root")

    with :ok <- File.mkdir_p(root),
         :ok <- prepare_root_directories(root),
         {:ok, entries} <- File.ls(root),
         true <- Enum.sort(entries) == @root_directories do
      {:ok, root}
    else
      false -> {:error, :sandbox_root_not_empty}
      {:error, reason} -> {:error, {:sandbox_root_unavailable, reason}}
    end
  end

  defp prepare_root_directories(root) do
    Enum.reduce_while(@root_directories, :ok, fn directory, :ok ->
      case File.mkdir_p(Path.join(root, directory)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:sandbox_root_unavailable, reason}}}
      end
    end)
  end

  defp isolated_paths(workspace, output, runtime, root, developer_workspace) do
    paths = [workspace, output, developer_workspace] |> Enum.reject(&is_nil/1)

    if Enum.uniq(paths) == paths and
         Enum.all?(paths, fn allowed -> not contains?(allowed, runtime) and not contains?(allowed, root) end) and
         (is_nil(developer_workspace) or not contains?(workspace, developer_workspace)) do
      :ok
    else
      {:error, :sandbox_paths_overlap}
    end
  end

  defp contains?(parent, child), do: child == parent or String.starts_with?(child, parent <> "/")

  defp prepare_output(output) do
    output
    |> Path.join(["home", "tmp", "cache", "config", "state"])
    |> File.mkdir_p()
  end

  defp same_runtime(runtime, runtime), do: :ok
  defp same_runtime(_, _), do: {:error, :coordinator_runtime_mismatch}

  defp command(%{executable: executable, args: args}) when is_binary(executable) and is_list(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_sandbox_command}
  end

  defp command(_), do: {:error, :invalid_sandbox_command}
end
