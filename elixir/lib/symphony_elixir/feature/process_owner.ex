defmodule SymphonyElixir.Feature.ProcessOwner do
  @moduledoc """
  Owns one controlled executor subprocess through a transient `systemd --user`
  service. The journaled unit name is durable before start; `InvocationID` and
  the cgroup path fence a live service from stale journal data.
  """
  alias SymphonyElixir.Feature.ProcessOwner.IO
  alias SymphonyElixir.Feature.{Sandbox, Store}

  @stop_timeout "1s"

  @type io_handle :: map()
  @type command :: %{executable: String.t(), args: [String.t()]}

  @spec start(Path.t(), map(), command()) :: {:blocked, :sandbox_required}
  def start(_path, _execution, _command), do: {:blocked, :sandbox_required}

  @spec start(Path.t(), map(), command(), Sandbox.profile()) :: {:ok, map()} | {:blocked, term()} | {:error, term()}
  def start(path, execution, command, sandbox) do
    with {:ok, wrapped} <- Sandbox.wrap(sandbox, path, command),
         :ok <- systemd_available(),
         {:ok, cleanup} <- Sandbox.cleanup(sandbox),
         {:ok, record} <- intent(path, execution, cleanup) do
      start_reserved(path, record, wrapped, sandbox, nil)
    else
      {:error, reason} -> {:blocked, reason}
      {:blocked, _} = blocked -> blocked
    end
  end

  @doc """
  Starts a sandboxed CLI execution with ProcessOwner-owned stdin, stdout and
  stderr channels. The returned handle is deliberately VM-local: a coordinator
  restart cannot attach to an old stream and must use `recover/1` instead.
  """
  @spec start_io(Path.t(), map(), command(), Sandbox.profile(), keyword()) ::
          {:ok, map()} | {:blocked, term()} | {:error, term()}
  def start_io(path, execution, command, sandbox, options \\ []) do
    with :ok <- IO.valid_execution_owner(execution),
         {:ok, wrapped} <- Sandbox.wrap(sandbox, path, command),
         :ok <- systemd_available(),
         {:ok, cleanup} <- Sandbox.cleanup(sandbox),
         {:ok, record} <- intent(path, execution, cleanup) do
      start_io_reserved(path, record, wrapped, sandbox, execution, options)
    else
      {:error, reason} -> {:blocked, reason}
      {:blocked, _} = blocked -> blocked
    end
  end

  @spec write_stdin(io_handle(), iodata()) :: :ok | {:blocked, term()}
  def write_stdin(handle, data), do: IO.write(handle, data)

  @spec close_stdin(io_handle()) :: :ok | {:blocked, term()}
  def close_stdin(handle), do: IO.close_stdin(handle)

  @spec subscribe(io_handle(), pid()) :: :ok | {:blocked, term()}
  def subscribe(handle, subscriber \\ self()), do: IO.subscribe(handle, subscriber)

  @spec output(io_handle()) :: {:ok, map()} | {:blocked, term()}
  def output(handle), do: IO.output(handle)

  @doc "Returns the observed unit exit status without trusting old output."
  @spec exit_status(io_handle()) :: {:ok, :running | non_neg_integer()} | {:blocked, term()}
  def exit_status(handle) do
    with :ok <- IO.owned?(handle),
         {:ok, execution} <- running_record(handle),
         {:ok, unit} <- inspect_unit(execution.unit_name),
         :ok <- same_execution?(execution, unit) do
      if unit.active_state in ["active", "activating"], do: {:ok, :running}, else: {:ok, unit.exit_status}
    else
      {:error, reason} -> {:blocked, {:liveness_unknown, handle.execution_id, reason}}
      {:blocked, _} = blocked -> blocked
    end
  end

  @spec intent(Path.t(), map()) :: {:ok, map()} | {:blocked, term()}
  def intent(path, execution) do
    intent(path, execution, nil)
  end

  defp intent(path, execution, cleanup) do
    with :ok <- recover(path), :ok <- valid_execution(execution), do: reserve_intent(path, execution, cleanup)
  end

  defp reserve_intent(path, execution, cleanup) do
    Store.transaction(path, fn db ->
      case active_records_in(db) do
        [] ->
          reserve_clean_intent(db, execution, cleanup)

        [record | _] ->
          {:blocked, {:unconfirmed_execution, record.execution_id, record.status}}
      end
    end)
  end

  defp reserve_clean_intent(db, execution, cleanup) do
    sandbox_output = cleanup_value(cleanup, :sandbox_output)

    case Store.execute(db, "SELECT execution_id FROM process_executions WHERE sandbox_output = ? LIMIT 1", [sandbox_output]) do
      [] ->
        record = %{
          execution_id: execution.execution_id,
          attempt_id: execution.attempt_id,
          feature_id: execution.feature_id,
          attempt_revision: execution.revision,
          unit_name: unit_name(execution.execution_id),
          status: "intended",
          invocation_id: nil,
          control_group: nil,
          main_pid: nil,
          sandbox_output: sandbox_output,
          auth_dir: cleanup_value(cleanup, :auth_dir)
        }

        Store.execute(
          db,
          "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, sandbox_output, auth_dir) VALUES (?, ?, ?, ?, ?, 'intended', ?, ?)",
          [
            record.execution_id,
            record.attempt_id,
            record.feature_id,
            record.attempt_revision,
            record.unit_name,
            record.sandbox_output,
            record.auth_dir
          ]
        )

        {:ok, record}

      [[existing_execution_id]] when is_binary(sandbox_output) ->
        {:blocked, {:codex_output_reused, existing_execution_id}}
    end
  end

  @spec launch(Path.t(), String.t(), command()) :: {:blocked, :sandbox_required}
  def launch(_path, _execution_id, _command), do: {:blocked, :sandbox_required}

  @spec launch(Path.t(), String.t(), command(), Sandbox.profile()) ::
          {:ok, map()} | {:blocked, term()} | {:error, term()}
  def launch(path, execution_id, command, sandbox) do
    case Sandbox.wrap(sandbox, path, command) do
      {:ok, wrapped} ->
        case systemd_available() do
          :ok -> launch_wrapped(path, execution_id, wrapped)
          blocked -> blocked
        end

      {:error, reason} ->
        {:blocked, reason}
    end
  end

  defp start_reserved(path, record, wrapped, sandbox, io_paths) do
    with :ok <- Sandbox.provision_codex_auth(sandbox),
         {:ok, started} <- launch_wrapped(path, record.execution_id, wrapped, io_paths) do
      {:ok, started}
    else
      {:error, reason} -> cleanup_failed_start(path, record.execution_id, {:blocked, reason})
      {:blocked, _} = blocked -> cleanup_failed_start(path, record.execution_id, blocked)
    end
  end

  defp start_io_reserved(path, record, wrapped, sandbox, execution, options) do
    with :ok <- Sandbox.provision_codex_auth(sandbox),
         {:ok, handle} <- IO.start(path, execution, options),
         {:ok, started} <- launch_wrapped(path, record.execution_id, wrapped, IO.paths(handle)) do
      {:ok, Map.put(started, :io, handle)}
    else
      {:error, reason} -> cleanup_failed_start(path, record.execution_id, {:blocked, reason})
      {:blocked, _} = blocked -> cleanup_failed_start(path, record.execution_id, blocked)
    end
  end

  defp cleanup_failed_start(path, execution_id, result) do
    case cancel(path, execution_id) do
      :ok -> result
      {:blocked, reason} -> {:blocked, {:start_cleanup_unconfirmed, execution_id, reason}}
    end
  end

  defp launch_wrapped(path, execution_id, %{executable: executable, args: args}) do
    launch_wrapped(path, execution_id, %{executable: executable, args: args}, nil)
  end

  defp launch_wrapped(path, execution_id, %{executable: executable, args: args}, io_paths) do
    case intended_record(path, execution_id) do
      {:ok, record} ->
        case run_unit(record.unit_name, executable, args, io_paths) do
          {:ok, _} -> persist_started(path, record)
          {:error, output} -> {:error, {:systemd_run_failed, output}}
        end

      other ->
        other
    end
  end

  @spec cancel(Path.t(), String.t()) :: :ok | {:blocked, term()}
  def cancel(path, execution_id) do
    case record(path, execution_id) do
      nil ->
        :ok

      %{status: "terminated"} ->
        :ok

      execution ->
        result = reconcile_record(path, execution)
        if result == :ok, do: IO.stop(path, execution_id)
        result
    end
  end

  @spec recover(Path.t()) :: :ok | {:blocked, term()}
  def recover(path) do
    path
    |> active_records_for_path()
    |> Enum.reduce_while(:ok, fn execution, :ok ->
      case reconcile_record(path, execution) do
        :ok ->
          IO.stop(path, execution.execution_id)
          {:cont, :ok}

        {:blocked, _} = blocked ->
          {:halt, blocked}
      end
    end)
  end

  @doc "Reconciles exactly one prior execution before its attempt is replaced."
  @spec recover_execution(Path.t(), String.t()) :: :ok | {:blocked, term()}
  def recover_execution(path, execution_id) do
    case record(path, execution_id) do
      nil ->
        :ok

      %{status: "terminated"} ->
        :ok

      execution ->
        case reconcile_record(path, execution) do
          :ok ->
            IO.stop(path, execution_id)
            :ok

          {:blocked, _} = blocked ->
            blocked
        end
    end
  end

  @spec current(Path.t()) :: [map()]
  def current(path), do: active_records_for_path(path)

  defp persist_started(path, execution) do
    case inspect_unit(execution.unit_name) do
      {:ok, unit} -> persist_running_identity(path, execution, unit)
      {:error, reason} -> block(path, execution, {:unidentified_started_execution, execution.execution_id, reason})
    end
  end

  defp persist_running_identity(path, execution, unit) do
    case running_identity(unit) do
      :ok -> persist_running_metadata(path, execution, unit)
      {:error, reason} -> block(path, execution, {:unidentified_started_execution, execution.execution_id, reason})
    end
  end

  defp persist_running_metadata(path, execution, unit) do
    Store.transaction(path, fn db ->
      Store.execute(
        db,
        "UPDATE process_executions SET status = 'running', invocation_id = ?, control_group = ?, main_pid = ? WHERE execution_id = ? AND status = 'intended'",
        [unit.invocation_id, unit.control_group, unit.main_pid, execution.execution_id]
      )

      case Store.execute(db, "SELECT changes()") do
        [[1]] ->
          {:ok,
           Map.merge(execution, %{
             status: "running",
             invocation_id: unit.invocation_id,
             control_group: unit.control_group,
             main_pid: unit.main_pid
           })}

        _ ->
          {:blocked, {:execution_lost_before_metadata, execution.execution_id}}
      end
    end)
  end

  defp reconcile_record(_path, %{status: "ambiguous"} = execution),
    do: {:blocked, {:ambiguous_execution, execution.execution_id}}

  defp reconcile_record(path, execution) do
    if execution.unit_name == unit_name(execution.execution_id) do
      reconcile_unit(path, execution)
    else
      block(path, execution, {:process_identity_mismatch, execution.execution_id, :unit_name})
    end
  end

  defp reconcile_unit(path, execution) do
    case inspect_unit(execution.unit_name) do
      {:ok, unit} ->
        case same_execution?(execution, unit) do
          :ok -> stop_and_confirm(path, execution, unit)
          {:error, reason} -> block(path, execution, {:process_identity_mismatch, execution.execution_id, reason})
        end

      {:error, reason} ->
        block(path, execution, {:liveness_unknown, execution.execution_id, reason})
    end
  end

  defp stop_and_confirm(path, execution, %{load_state: "not-found"} = unit),
    do: confirm_cgroup(path, execution, execution.control_group || unit.control_group)

  defp stop_and_confirm(path, execution, unit) do
    with :ok <- stop_unit(execution.unit_name), {:ok, stopped} <- inspect_unit(execution.unit_name) do
      confirm_stopped(path, execution, unit, stopped)
    else
      {:error, output} -> block(path, execution, {:termination_unconfirmed, execution.execution_id, output})
    end
  end

  defp confirm_stopped(path, execution, unit, stopped) do
    if stopped.load_state == "not-found" or stopped.active_state in ["inactive", "failed"] do
      confirm_cgroup(path, execution, stopped.control_group || unit.control_group || execution.control_group)
    else
      block(path, execution, {:termination_unconfirmed, execution.execution_id})
    end
  end

  defp confirm_cgroup(path, execution, control_group) do
    if cgroup_empty?(control_group) do
      mark_terminated(path, execution.execution_id)
    else
      block(path, execution, {:cgroup_not_empty, execution.execution_id})
    end
  end

  defp block(path, execution, reason) do
    mark_ambiguous(path, execution.execution_id)
    {:blocked, reason}
  end

  defp same_execution?(_execution, %{active_state: state}) when state in ["inactive", "failed"], do: :ok

  defp same_execution?(%{invocation_id: nil}, _unit), do: :ok
  defp same_execution?(%{invocation_id: invocation_id}, %{invocation_id: invocation_id}), do: :ok

  defp same_execution?(%{invocation_id: expected}, %{invocation_id: actual}),
    do: {:error, {:invocation_id, expected, actual}}

  defp running_identity(%{
         load_state: load_state,
         active_state: active_state,
         invocation_id: invocation_id,
         control_group: control_group
       })
       when load_state != "not-found" and active_state in ["active", "activating"] and invocation_id != "" and
              control_group != "",
       do: :ok

  defp running_identity(unit), do: {:error, {:unit_not_running, unit}}

  defp intended_record(path, execution_id) do
    case record(path, execution_id) do
      %{status: "intended"} = execution -> {:ok, execution}
      %{status: status} -> {:blocked, {:execution_not_intended, execution_id, status}}
      nil -> {:blocked, {:unknown_execution, execution_id}}
    end
  end

  defp active_records_for_path(path), do: Store.transaction(path, &active_records_in/1)

  defp active_records_in(db) do
    Store.execute(
      db,
      "SELECT execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, invocation_id, control_group, main_pid, sandbox_output, auth_dir FROM process_executions WHERE status != 'terminated' ORDER BY rowid"
    )
    |> Enum.map(&row_to_execution/1)
  end

  defp record(path, execution_id) do
    Store.read(path, fn db ->
      case Store.execute(
             db,
             "SELECT execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, invocation_id, control_group, main_pid, sandbox_output, auth_dir FROM process_executions WHERE execution_id = ?",
             [execution_id]
           ) do
        [row] -> row_to_execution(row)
        [] -> nil
      end
    end)
  end

  defp running_record(%{path: path, execution_id: execution_id}) do
    case record(path, execution_id) do
      %{status: "running"} = execution -> {:ok, execution}
      %{status: status} -> {:blocked, {:execution_not_running, execution_id, status}}
      nil -> {:blocked, {:unknown_execution, execution_id}}
    end
  end

  defp row_to_execution([
         execution_id,
         attempt_id,
         feature_id,
         attempt_revision,
         unit_name,
         status,
         invocation_id,
         control_group,
         main_pid,
         sandbox_output,
         auth_dir
       ]) do
    %{
      execution_id: execution_id,
      attempt_id: attempt_id,
      feature_id: feature_id,
      attempt_revision: attempt_revision,
      unit_name: unit_name,
      status: status,
      invocation_id: invocation_id,
      control_group: control_group,
      main_pid: main_pid,
      sandbox_output: sandbox_output,
      auth_dir: auth_dir
    }
  end

  defp mark_terminated(path, execution_id) do
    case record(path, execution_id) do
      nil ->
        {:blocked, {:unknown_execution, execution_id}}

      execution ->
        case remove_auth(execution) do
          :ok ->
            mark_terminated_record(path, execution_id)

          {:error, reason} ->
            mark_ambiguous(path, execution_id)
            {:blocked, {:auth_cleanup_failed, execution_id, reason}}
        end
    end
  end

  defp mark_terminated_record(path, execution_id) do
    Store.transaction(path, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'terminated' WHERE execution_id = ?", [execution_id])
      :ok
    end)
  end

  defp remove_auth(%{sandbox_output: nil, auth_dir: nil}), do: :ok

  defp remove_auth(%{sandbox_output: output, auth_dir: auth_dir}) when is_binary(output) and is_binary(auth_dir) do
    expected = Path.join([output, "home", ".codex"])

    if auth_dir == expected do
      case File.rm_rf(auth_dir) do
        {:ok, _removed} -> :ok
        {:error, reason, _file} -> {:error, reason}
      end
    else
      {:error, :invalid_auth_cleanup_path}
    end
  end

  defp remove_auth(_execution), do: {:error, :invalid_auth_cleanup_path}

  defp cleanup_value(nil, _key), do: nil
  defp cleanup_value(cleanup, key), do: Map.fetch!(cleanup, key)

  defp mark_ambiguous(path, execution_id) do
    Store.transaction(path, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'ambiguous' WHERE execution_id = ? AND status != 'terminated'", [execution_id])
      :ok
    end)
  end

  defp run_unit(unit_name, executable, args, io_paths) do
    systemd_run(
      [
        "--user",
        "--unit",
        unit_name,
        "--service-type=exec",
        "--property=KillMode=control-group",
        "--property=KillSignal=SIGTERM",
        "--property=TimeoutStopSec=#{@stop_timeout}",
        "--property=SendSIGKILL=yes",
        "--quiet"
      ] ++ io_properties(io_paths) ++ ["--", executable | args]
    )
  end

  defp io_properties(nil), do: []

  defp io_properties(%{stdin: stdin, stdout: stdout, stderr: stderr}) do
    [
      "--property=StandardInput=file:#{stdin}",
      "--property=StandardOutput=file:#{stdout}",
      "--property=StandardError=file:#{stderr}"
    ]
  end

  defp stop_unit(unit_name) do
    case systemd(["--user", "stop", unit_name]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp inspect_unit(unit_name) do
    case systemd([
           "--user",
           "show",
           unit_name,
           "--property=LoadState",
           "--property=ActiveState",
           "--property=InvocationID",
           "--property=ControlGroup",
           "--property=ExecMainPID",
           "--property=ExecMainStatus"
         ]) do
      {:ok, output} ->
        {:ok, unit_properties(output)}

      {:error, output} ->
        if is_binary(output) and String.contains?(output, "could not be found") do
          {:ok, unit_properties("LoadState=not-found")}
        else
          {:error, output}
        end
    end
  end

  defp unit_properties(output) do
    properties =
      output
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> {line, ""}
        end
      end)

    %{
      load_state: Map.get(properties, "LoadState", ""),
      active_state: Map.get(properties, "ActiveState", ""),
      invocation_id: Map.get(properties, "InvocationID", ""),
      control_group: Map.get(properties, "ControlGroup", ""),
      main_pid: properties |> Map.get("ExecMainPID", "0") |> parse_pid(),
      exit_status: properties |> Map.get("ExecMainStatus", "0") |> parse_pid()
    }
  end

  defp parse_pid(value) do
    case Integer.parse(value) do
      {pid, ""} -> pid
      _ -> 0
    end
  end

  defp cgroup_empty?(nil), do: true
  defp cgroup_empty?(""), do: true

  defp cgroup_empty?(control_group) do
    case File.read(Path.join(["/sys/fs/cgroup", control_group, "cgroup.procs"])) do
      {:ok, ""} -> true
      {:ok, _} -> false
      {:error, :enoent} -> true
      {:error, _} -> false
    end
  end

  defp systemd(args), do: command("systemctl", args)
  defp systemd_run(args), do: command("systemd-run", args)

  defp systemd_available do
    if System.find_executable("systemd-run") && System.find_executable("systemctl"),
      do: :ok,
      else: {:blocked, :systemd_unavailable}
  end

  defp command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _} -> {:error, output}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp valid_execution(%{
         execution_id: execution_id,
         attempt_id: attempt_id,
         feature_id: feature_id,
         revision: revision
       })
       when is_binary(execution_id) and byte_size(execution_id) > 0 and is_binary(attempt_id) and
              byte_size(attempt_id) > 0 and is_binary(feature_id) and byte_size(feature_id) > 0 and
              is_integer(revision),
       do: :ok

  defp valid_execution(_), do: raise(ArgumentError, "invalid Task 1 execution")

  defp unit_name(execution_id), do: "symphony-feature-#{execution_id}.service"
end
