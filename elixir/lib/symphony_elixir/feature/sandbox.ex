defmodule SymphonyElixir.Feature.Sandbox do
  @moduledoc """
  Builds the fail-closed bubblewrap boundary used by controlled feature roles.

  The coordinator keeps its journal and every host credential outside the
  sandbox. A role sees only a read-only runtime, its own workspace and its
  explicitly assigned output directory.
  """

  defmodule Profile do
    @moduledoc false

    @enforce_keys [:role, :workspace, :output, :runtime, :root, :developer_workspace, :kind]
    defstruct [:role, :workspace, :output, :runtime, :root, :developer_workspace, :kind, :codex_binary, :auth_source]

    @type t :: %__MODULE__{
            role: term(),
            workspace: Path.t(),
            output: Path.t(),
            runtime: Path.t(),
            root: Path.t(),
            developer_workspace: Path.t() | nil,
            kind: :standard | :codex,
            codex_binary: Path.t() | nil,
            auth_source: Path.t() | nil
          }
  end

  @type role :: :developer | :reviewer | :test | :codex
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

  @codex_binary "/home/jarek/.local/share/mise/installs/node/22.23.2/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
  @codex_auth "/home/jarek/.codex/auth.json"
  @sandbox_codex_binary "/opt/codex/bin/codex"
  @resolver "/etc/resolv.conf"
  @ca_bundle "/etc/ssl/certs/ca-certificates.crt"
  @root_directories ~w(bin dev etc lib lib64 opt output proc usr workspace)

  @spec profile(keyword()) :: {:ok, profile()} | {:error, term()}
  def profile(options) when is_list(options) do
    with {:ok, role} <- role(Keyword.get(options, :role)),
         {:ok, workspace} <- directory(:workspace, Keyword.get(options, :workspace)),
         {:ok, output} <- directory(:output, Keyword.get(options, :output)),
         {:ok, runtime} <- path(:runtime, Keyword.get(options, :runtime)),
         {:ok, root} <- sandbox_root(runtime),
         {:ok, developer_workspace} <- developer_workspace(role, Keyword.get(options, :developer_workspace)),
         {:ok, kind, codex_binary, auth_source} <- codex_inputs(role),
         :ok <- isolated_paths(workspace, output, runtime, root, developer_workspace),
         :ok <- prepare_output(output) do
      {:ok,
       %Profile{
         role: role,
         workspace: workspace,
         output: output,
         runtime: runtime,
         root: root,
         developer_workspace: developer_workspace,
         kind: kind,
         codex_binary: codex_binary,
         auth_source: auth_source
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
         :ok <- command(profile, command) do
      {:ok, %{executable: bwrap, args: bwrap_args(profile, command)}}
    end
  end

  def wrap(_, _, _), do: {:error, :invalid_sandbox_profile}

  @spec codex?(profile()) :: boolean()
  def codex?(%Profile{kind: :codex}), do: true
  def codex?(%Profile{}), do: false

  @spec codex_auth_dir(profile()) :: {:ok, Path.t()} | {:error, term()}
  def codex_auth_dir(%Profile{kind: :codex, output: output}), do: {:ok, Path.join([output, "home", ".codex"])}
  def codex_auth_dir(%Profile{}), do: {:error, :not_codex_profile}

  @spec cleanup(profile()) :: {:ok, nil | %{sandbox_output: Path.t(), auth_dir: Path.t()}}
  def cleanup(%Profile{kind: :codex, output: output} = profile) do
    with {:ok, auth_dir} <- codex_auth_dir(profile) do
      {:ok, %{sandbox_output: output, auth_dir: auth_dir}}
    end
  end

  def cleanup(%Profile{}), do: {:ok, nil}

  @spec provision_codex_auth(profile()) :: :ok | {:error, term()}
  def provision_codex_auth(%Profile{kind: :codex, auth_source: source} = profile) do
    with {:ok, auth_dir} <- codex_auth_dir(profile),
         :ok <- empty_codex_home(profile.output),
         :ok <- File.mkdir_p(auth_dir),
         {:ok, _bytes} <- File.copy(source, Path.join(auth_dir, "auth.json")),
         :ok <- File.chmod(Path.join(auth_dir, "auth.json"), 0o600) do
      :ok
    else
      {:error, _} = error -> error
      false -> {:error, :codex_auth_copy_failed}
    end
  end

  def provision_codex_auth(%Profile{}), do: :ok

  defp bwrap do
    case System.find_executable("bwrap") do
      nil -> {:error, :bwrap_unavailable}
      executable -> {:ok, executable}
    end
  end

  defp bwrap_args(profile, command) do
    [
      "--new-session",
      "--unshare-all"
    ] ++
      network_args(profile) ++
      [
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
      ] ++ codex_mount_args(profile) ++ environment_args(profile) ++ ["--", command.executable | command.args]
  end

  defp network_args(%Profile{kind: :codex}), do: ["--share-net"]
  defp network_args(%Profile{}), do: ["--unshare-net"]

  defp codex_mount_args(%Profile{kind: :codex, codex_binary: binary}) do
    [
      "--tmpfs",
      "/opt",
      "--dir",
      "/opt/codex",
      "--dir",
      "/opt/codex/bin",
      "--ro-bind",
      binary,
      @sandbox_codex_binary,
      "--tmpfs",
      "/etc",
      "--dir",
      "/etc/ssl",
      "--dir",
      "/etc/ssl/certs",
      "--ro-bind",
      @resolver,
      @resolver,
      "--ro-bind",
      @ca_bundle,
      @ca_bundle
    ]
  end

  defp codex_mount_args(%Profile{}), do: []

  defp environment_args(%Profile{kind: :codex}) do
    Map.put(@base_environment, "CODEX_HOME", "/output/home/.codex")
    |> environment_args()
  end

  defp environment_args(%Profile{}), do: environment_args(@base_environment)

  defp environment_args(environment) do
    environment
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, value} -> ["--setenv", key, value] end)
  end

  defp valid_profile(%Profile{} = profile) do
    with {:ok, workspace} <- directory(:workspace, profile.workspace),
         {:ok, output} <- directory(:output, profile.output),
         {:ok, runtime} <- path(:runtime, profile.runtime),
         {:ok, root} <- sandbox_root(runtime),
         {:ok, developer_workspace} <- developer_workspace(profile.role, profile.developer_workspace),
         {:ok, kind, codex_binary, auth_source} <- codex_inputs(profile.role),
         :ok <- isolated_paths(workspace, output, runtime, root, developer_workspace),
         true <-
           workspace == profile.workspace and output == profile.output and runtime == profile.runtime and root == profile.root and
             developer_workspace == profile.developer_workspace and kind == profile.kind and codex_binary == profile.codex_binary and
             auth_source == profile.auth_source do
      :ok
    else
      false -> {:error, :sandbox_profile_changed}
      {:error, _} = error -> error
    end
  end

  defp role(role) when role in [:developer, :reviewer, :test, :codex], do: {:ok, role}
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

  defp codex_inputs(:codex) do
    with {:ok, binary} <- regular_canonical(:codex_binary, @codex_binary),
         {:ok, auth} <- regular_canonical(:codex_auth, @codex_auth),
         :ok <- regular_file(:resolver, @resolver),
         :ok <- regular_file(:ca_bundle, @ca_bundle) do
      {:ok, :codex, binary, auth}
    end
  end

  defp codex_inputs(_role), do: {:ok, :standard, nil, nil}

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

  defp regular_canonical(name, value) do
    with {:ok, resolved} <- resolve(value),
         true <- resolved == value,
         {:ok, %File.Stat{type: :regular}} <- File.stat(resolved) do
      {:ok, resolved}
    else
      false -> {:error, {:sandbox_path_not_canonical_or_regular, name}}
      {:ok, _} -> {:error, {:sandbox_path_not_canonical_or_regular, name}}
      {:error, _} = error -> error
    end
  end

  defp regular_file(name, value) do
    case File.stat(value) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _ -> {:error, {:sandbox_path_not_regular, name}}
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
    (@root_directories ++ ["etc/ssl/certs", "opt/codex/bin"])
    |> Enum.reduce_while(:ok, fn directory, :ok ->
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
    ["home", "tmp", "cache", "config", "state"]
    |> Enum.reduce_while(:ok, fn directory, :ok ->
      case File.mkdir_p(Path.join(output, directory)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:sandbox_output_unavailable, reason}}}
      end
    end)
  end

  defp empty_codex_home(output) do
    home = Path.join(output, "home")

    case File.ls(home) do
      {:ok, []} -> :ok
      {:ok, _entries} -> {:error, :codex_home_reused}
      {:error, reason} -> {:error, {:codex_home_unavailable, reason}}
    end
  end

  defp same_runtime(runtime, runtime), do: :ok
  defp same_runtime(_, _), do: {:error, :coordinator_runtime_mismatch}

  defp command(%Profile{kind: :codex}, %{executable: @sandbox_codex_binary, args: args}) when is_list(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_sandbox_command}
  end

  defp command(%Profile{kind: :codex}, _), do: {:error, :invalid_codex_command}

  defp command(%Profile{}, %{executable: executable, args: args}) when is_binary(executable) and is_list(args) do
    if Enum.all?(args, &is_binary/1), do: :ok, else: {:error, :invalid_sandbox_command}
  end

  defp command(%Profile{}, _), do: {:error, :invalid_sandbox_command}
end
