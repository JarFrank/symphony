defmodule SymphonyElixir.Feature.ProcessOwner do
  @moduledoc """
  Owns one controlled executor subprocess through a transient `systemd --user`
  service. The journaled unit name is durable before start; `InvocationID` and
  the cgroup path fence a live service from stale journal data.
  """
  alias SymphonyElixir.Feature.{Sandbox, Store}

  @stop_timeout "1s"

  @type command :: %{executable: String.t(), args: [String.t()]}

  @spec start(Path.t(), map(), command()) :: {:blocked, :sandbox_required}
  def start(_path, _execution, _command), do: {:blocked, :sandbox_required}

  @spec start(Path.t(), map(), command(), Sandbox.profile()) :: {:ok, map()} | {:blocked, term()} | {:error, term()}
  def start(path, execution, command, sandbox) do
    with {:ok, wrapped} <- Sandbox.wrap(sandbox, path, command),
         {:ok, record} <- intent(path, execution) do
      launch_wrapped(path, record.execution_id, wrapped)
    else
      {:error, reason} -> {:blocked, reason}
      {:blocked, _} = blocked -> blocked
    end
  end

  @spec intent(Path.t(), map()) :: {:ok, map()} | {:blocked, term()}
  def intent(path, execution) do
    with :ok <- recover(path), :ok <- valid_execution(execution), do: reserve_intent(path, execution)
  end

  defp reserve_intent(path, execution) do
    Store.transaction(path, fn db ->
      case active_records_in(db) do
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
            main_pid: nil
          }

          Store.execute(
            db,
            "INSERT INTO process_executions (execution_id, attempt_id, feature_id, attempt_revision, unit_name, status) VALUES (?, ?, ?, ?, ?, 'intended')",
            [record.execution_id, record.attempt_id, record.feature_id, record.attempt_revision, record.unit_name]
          )

          {:ok, record}

        [record | _] ->
          {:blocked, {:unconfirmed_execution, record.execution_id, record.status}}
      end
    end)
  end

  @spec launch(Path.t(), String.t(), command()) :: {:blocked, :sandbox_required}
  def launch(_path, _execution_id, _command), do: {:blocked, :sandbox_required}

  @spec launch(Path.t(), String.t(), command(), Sandbox.profile()) ::
          {:ok, map()} | {:blocked, term()} | {:error, term()}
  def launch(path, execution_id, command, sandbox) do
    case Sandbox.wrap(sandbox, path, command) do
      {:ok, wrapped} -> launch_wrapped(path, execution_id, wrapped)
      {:error, reason} -> {:blocked, reason}
    end
  end

  defp launch_wrapped(path, execution_id, %{executable: executable, args: args}) do
    case intended_record(path, execution_id) do
      {:ok, record} ->
        case run_unit(record.unit_name, executable, args) do
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
      nil -> :ok
      %{status: "terminated"} -> :ok
      execution -> reconcile_record(path, execution)
    end
  end

  @spec recover(Path.t()) :: :ok | {:blocked, term()}
  def recover(path) do
    path
    |> active_records_for_path()
    |> Enum.reduce_while(:ok, fn execution, :ok ->
      case reconcile_record(path, execution) do
        :ok -> {:cont, :ok}
        {:blocked, _} = blocked -> {:halt, blocked}
      end
    end)
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
      "SELECT execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, invocation_id, control_group, main_pid FROM process_executions WHERE status != 'terminated' ORDER BY rowid"
    )
    |> Enum.map(&row_to_execution/1)
  end

  defp record(path, execution_id) do
    Store.transaction(path, fn db ->
      case Store.execute(
             db,
             "SELECT execution_id, attempt_id, feature_id, attempt_revision, unit_name, status, invocation_id, control_group, main_pid FROM process_executions WHERE execution_id = ?",
             [execution_id]
           ) do
        [row] -> row_to_execution(row)
        [] -> nil
      end
    end)
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
         main_pid
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
      main_pid: main_pid
    }
  end

  defp mark_terminated(path, execution_id) do
    Store.transaction(path, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'terminated' WHERE execution_id = ?", [execution_id])
      :ok
    end)
  end

  defp mark_ambiguous(path, execution_id) do
    Store.transaction(path, fn db ->
      Store.execute(db, "UPDATE process_executions SET status = 'ambiguous' WHERE execution_id = ? AND status != 'terminated'", [execution_id])
      :ok
    end)
  end

  defp run_unit(unit_name, executable, args) do
    systemd_run([
      "--user",
      "--unit",
      unit_name,
      "--service-type=exec",
      "--collect",
      "--property=KillMode=control-group",
      "--property=KillSignal=SIGTERM",
      "--property=TimeoutStopSec=#{@stop_timeout}",
      "--property=SendSIGKILL=yes",
      "--quiet",
      "--",
      executable | args
    ])
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
           "--property=ExecMainPID"
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
      main_pid: properties |> Map.get("ExecMainPID", "0") |> parse_pid()
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
