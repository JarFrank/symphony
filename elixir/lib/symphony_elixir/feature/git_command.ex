defmodule SymphonyElixir.Feature.GitCommand do
  @moduledoc "Host Git boundary: sanitized environment and an explicit repository configuration allowlist."

  # None of these keys can run a program or redirect the worktree/object store.
  # Unknown keys (including includes, filters, signing, helpers and fsmonitor)
  # fail closed before any repository operation. Do not expand this list with
  # executable configuration; the developer repository is untrusted input.
  @safe_keys ~w(core.repositoryformatversion core.filemode core.bare core.logallrefupdates core.ignorecase core.symlinks user.name user.email)
  @policy ~w(core.hooksPath=/dev/null core.fsmonitor=false commit.gpgSign=false gc.auto=0 maintenance.auto=false protocol.allow=never)

  @spec run(Path.t(), [String.t()]) :: {:ok, String.t()} | {:blocked, term()}
  def run(directory, args) do
    environment = environment()

    case safe_config(directory, environment) do
      :ok -> invoke(directory, args, environment)
      # Report the requested operation when its repository preflight fails.
      {:blocked, {:git_command_failed, _preflight, status}} -> {:blocked, {:git_command_failed, args, status}}
      {:blocked, _} = blocked -> blocked
    end
  rescue
    _ -> {:blocked, :git_unavailable}
  end

  defp safe_config(directory, environment) do
    with {:ok, config} <- invoke(directory, ["config", "--local", "--no-includes", "--null", "--list"], environment) do
      keys = config |> String.split(<<0>>, trim: true) |> Enum.map(&(String.split(&1, "\n", parts: 2) |> hd()))
      unsafe = Enum.reject(keys, &safe_key?/1)
      if unsafe == [], do: :ok, else: {:blocked, {:unsafe_git_config, Enum.uniq(unsafe)}}
    end
  end

  defp safe_key?(key) do
    key in @safe_keys or Regex.match?(~r/^(remote\..+\.(url|fetch)|branch\..+\.(remote|merge))$/, key)
  end

  defp environment do
    cleared = for {key, _} <- System.get_env(), String.starts_with?(key, "GIT_"), do: {key, nil}

    Map.new(cleared)
    |> Map.merge(%{
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_NO_REPLACE_OBJECTS" => "1",
      "GIT_ATTR_NOSYSTEM" => "1",
      "LC_ALL" => "C"
    })
    |> Map.to_list()
  end

  defp invoke(directory, args, environment) do
    policy = Enum.flat_map(@policy, &["-c", &1])

    case System.cmd("git", ["-C", directory] ++ policy ++ args, env: environment, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output)}
      {_output, status} -> {:blocked, {:git_command_failed, args, status}}
    end
  end
end
