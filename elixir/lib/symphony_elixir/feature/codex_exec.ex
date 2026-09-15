defmodule SymphonyElixir.Feature.CodexExec do
  @moduledoc """
  Narrow, standalone transport adapter for one `codex exec` role invocation.

  A caller supplies a prepared FeatureRunner execution and Sandbox profile.
  The fixture CLI is started exclusively through ProcessOwner, which places it
  behind the sandbox and its systemd-owned cgroup. This module owns argv
  construction, stdin delivery, JSONL decoding and validation of the role's
  final structured message.
  """

  @max_capture 64 * 1024
  @roles ["mastermind", "developer", "reviewer", "test"]

  alias SymphonyElixir.Feature.{ProcessOwner, Sandbox}

  @sandbox_codex_binary "/opt/codex/bin/codex"

  @type request :: %{
          required(:attempt_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:role) => String.t() | atom(),
          required(:task_id) => String.t(),
          required(:model) => String.t(),
          required(:reasoning_effort) => String.t(),
          required(:prompt) => String.t(),
          required(:output_dir) => Path.t(),
          required(:runtime) => Path.t(),
          required(:execution) => map(),
          required(:sandbox) => Sandbox.profile(),
          optional(:executable) => Path.t(),
          optional(:fixture_args) => [String.t()]
        }

  @spec run(request()) :: {:ok, map()} | {:error, map()}
  def run(request) do
    with {:ok, request} <- validate_request(request),
         {:ok, paths} <- prepare_artifacts(request),
         {:ok, transport} <- run_process(request, paths),
         result <- finish(request, paths, transport) do
      result
    else
      {:error, kind, detail} -> {:error, failure(kind, detail)}
    end
  end

  @doc "Runs one authenticated Codex runtime preflight through ProcessOwner."
  @spec preflight(map(), :version | :login_status) :: {:ok, map()} | {:error, map()}
  def preflight(request, check) when check in [:version, :login_status] do
    with {:ok, request} <- validate_preflight_request(request),
         {:ok, result} <- run_preflight(request, check) do
      {:ok, result}
    else
      {:error, kind, detail} -> {:error, failure(kind, detail)}
    end
  end

  @spec argv(request(), map()) :: [String.t()]
  def argv(request, paths) do
    [
      "exec",
      "--json",
      "--ephemeral",
      "--ignore-user-config",
      "--ignore-rules",
      "--sandbox",
      "workspace-write",
      "-c",
      "sandbox_workspace_write.network_access=false",
      "--model",
      request.model,
      "-c",
      "model_reasoning_effort=\"#{request.reasoning_effort}\"",
      "--output-schema",
      paths.sandbox_schema,
      "--output-last-message",
      paths.sandbox_last_message,
      "-"
    ] ++ Map.get(request, :fixture_args, [])
  end

  @spec output_schema() :: map()
  def output_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["status", "role", "task_id", "attempt_id", "execution_id", "reason"],
      "properties" => %{
        "status" => %{"enum" => ["completed", "failed"]},
        "role" => %{"type" => "string"},
        "task_id" => %{"type" => "string", "minLength" => 1},
        "attempt_id" => %{"type" => "string", "minLength" => 1},
        "execution_id" => %{"type" => "string", "minLength" => 1},
        "reason" => %{"type" => ["string", "null"], "minLength" => 1}
      }
    }
  end

  defp validate_request(%{} = request) do
    role = request |> Map.get(:role) |> to_string()

    required = [:attempt_id, :execution_id, :task_id, :model, :reasoning_effort, :prompt, :output_dir, :runtime]

    if role in @roles and Enum.all?(required, &(is_binary(request[&1]) and byte_size(request[&1]) > 0)) and
         File.dir?(request.output_dir) and valid_execution?(request) and valid_sandbox?(request) and valid_executable?(request) do
      {:ok, Map.put(request, :role, role)}
    else
      {:error, :invalid_request, :missing_or_invalid_field}
    end
  end

  defp validate_request(_), do: {:error, :invalid_request, :not_a_map}

  defp valid_execution?(%{execution: execution} = request) when is_map(execution) do
    execution.execution_id == request.execution_id and execution.attempt_id == request.attempt_id and
      is_binary(execution.feature_id) and is_integer(execution.revision) and is_binary(execution.owner_token)
  end

  defp valid_execution?(_), do: false

  defp valid_sandbox?(%{sandbox: %Sandbox.Profile{output: output}, output_dir: output}), do: true
  defp valid_sandbox?(_), do: false

  defp valid_executable?(%{sandbox: sandbox} = request) do
    not Sandbox.codex?(sandbox) or not Map.has_key?(request, :executable)
  end

  defp validate_preflight_request(%{} = request) do
    if is_binary(request[:runtime]) and is_binary(request[:output_dir]) and File.dir?(request[:output_dir]) and valid_execution?(request) and
         valid_sandbox?(request) and
         match?(%Sandbox.Profile{}, request[:sandbox]) and Sandbox.codex?(request.sandbox) do
      {:ok, request}
    else
      {:error, :invalid_preflight_request, :missing_or_invalid_field}
    end
  end

  defp validate_preflight_request(_), do: {:error, :invalid_preflight_request, :not_a_map}

  defp prepare_artifacts(request) do
    paths = %{
      schema: Path.join(request.output_dir, "codex-result-schema.json"),
      last_message: Path.join(request.output_dir, "codex-last-message.json"),
      sandbox_schema: "/output/codex-result-schema.json",
      sandbox_last_message: "/output/codex-last-message.json"
    }

    case Jason.encode(output_schema()) do
      {:ok, schema} ->
        case File.write(paths.schema, schema) do
          :ok -> {:ok, paths}
          {:error, reason} -> {:error, :artifact_write, reason}
        end

      {:error, reason} ->
        {:error, :artifact_encode, reason}
    end
  end

  defp run_process(request, paths) do
    executable = if Sandbox.codex?(request.sandbox), do: @sandbox_codex_binary, else: Map.get(request, :executable, System.find_executable("codex") || "codex")
    command = %{executable: executable, args: argv(request, paths)}
    io_options = [max_buffer_bytes: @max_capture]

    case ProcessOwner.start_io(request.runtime, request.execution, command, request.sandbox, io_options) do
      {:ok, started} ->
        try do
          with :ok <- ProcessOwner.subscribe(started.io),
               :ok <- ProcessOwner.write_stdin(started.io, [request.prompt, "\n"]),
               :ok <- ProcessOwner.close_stdin(started.io),
               {:ok, exit_status, jsonl} <- await_exit_status(started.io, empty_transport()),
               {:ok, output, jsonl} <- await_output(started.io, jsonl) do
            decode_transport(output, exit_status, jsonl)
          else
            {:blocked, reason} -> {:error, :transport, reason}
          end
        catch
          {:malformed_jsonl, line} -> {:error, :malformed_jsonl, line}
        after
          ProcessOwner.cancel(request.runtime, request.execution.execution_id)
        end

      {:blocked, reason} ->
        {:error, :transport, reason}
    end
  end

  defp run_preflight(request, check) do
    command = %{executable: @sandbox_codex_binary, args: preflight_argv(check)}
    io_options = [max_buffer_bytes: @max_capture]

    case ProcessOwner.start_io(request.runtime, request.execution, command, request.sandbox, io_options) do
      {:ok, started} ->
        try do
          with :ok <- ProcessOwner.close_stdin(started.io),
               {:ok, exit_status} <- await_preflight_exit(started.io),
               {:ok, output} <- await_preflight_output(started.io) do
            if exit_status == 0,
              do: {:ok, %{check: check, output: bound(output.stdout, output.stderr), exit_status: exit_status}},
              else: {:error, :preflight_process, %{check: check, output: bound(output.stdout, output.stderr), exit_status: exit_status}}
          else
            {:blocked, reason} -> {:error, :preflight_transport, reason}
          end
        after
          ProcessOwner.cancel(request.runtime, request.execution.execution_id)
        end

      {:blocked, reason} ->
        {:error, :preflight_transport, reason}
    end
  end

  defp preflight_argv(:version), do: ["--version"]
  defp preflight_argv(:login_status), do: ["login", "status"]

  defp await_preflight_exit(handle) do
    case ProcessOwner.exit_status(handle) do
      {:ok, :running} ->
        Process.sleep(20)
        await_preflight_exit(handle)

      {:ok, status} ->
        {:ok, status}

      {:blocked, reason} ->
        {:blocked, reason}
    end
  end

  defp await_preflight_output(handle) do
    Process.sleep(30)
    ProcessOwner.output(handle)
  end

  defp await_exit_status(handle, transport) do
    receive do
      {:process_owner_io, ^handle, :stdout, chunk} ->
        await_exit_status(handle, consume(transport, chunk))

      {:process_owner_io, ^handle, :stderr, _chunk} ->
        await_exit_status(handle, transport)
    after
      20 ->
        await_exit_status_now(handle, transport)
    end
  end

  defp await_exit_status_now(handle, transport) do
    case ProcessOwner.exit_status(handle) do
      {:ok, :running} ->
        await_exit_status(handle, transport)

      {:ok, status} ->
        {:ok, status, transport}

      {:blocked, reason} ->
        {:blocked, reason}
    end
  end

  defp await_output(handle, transport) do
    # ProcessOwner polls the redirected files asynchronously. Give its final
    # poll a chance to observe bytes written immediately before unit exit.
    Process.sleep(30)

    with {:ok, output} <- ProcessOwner.output(handle) do
      {:ok, output, drain_stdout(handle, transport)}
    end
  end

  defp drain_stdout(handle, transport) do
    receive do
      {:process_owner_io, ^handle, :stdout, chunk} -> drain_stdout(handle, consume(transport, chunk))
      {:process_owner_io, ^handle, :stderr, _chunk} -> drain_stdout(handle, transport)
    after
      0 -> transport
    end
  end

  defp decode_transport(output, exit_status, transport) do
    transport =
      Map.merge(transport, %{
        output: bound(output.stdout, output.stderr),
        truncated?: output.stdout_truncated? or output.stderr_truncated? or byte_size(output.stdout <> output.stderr) > @max_capture,
        exit_status: exit_status
      })

    try do
      if transport.buffer == "" do
        {:ok, transport}
      else
        {:error, :partial_jsonl, bounded(transport)}
      end
    catch
      {:malformed_jsonl, line} -> {:error, :malformed_jsonl, line}
    end
  end

  defp empty_transport, do: %{buffer: "", events: [], session_id: nil}

  defp consume(state, chunk) do
    {tail, lines} = String.split(state.buffer <> chunk, "\n") |> List.pop_at(-1)
    next = Enum.reduce(lines, %{state | buffer: ""}, fn line, acc -> parse_line(acc, line) end)
    %{next | buffer: tail}
  end

  defp parse_line(state, ""), do: state

  defp parse_line(state, line) do
    case Jason.decode(line) do
      {:ok, event} when is_map(event) ->
        %{state | events: [event | state.events], session_id: state.session_id || session_id(event)}

      _ ->
        throw({:malformed_jsonl, line})
    end
  end

  defp finish(_request, _paths, %{exit_status: status} = transport) when status != 0 do
    detail = Map.merge(bounded(transport), %{exit_status: status, codex_session_id: transport.session_id})
    {:error, failure(:process, detail)}
  end

  defp finish(_request, _paths, %{kind: kind, detail: detail}), do: {:error, failure(kind, detail)}

  defp finish(request, paths, transport) do
    with {:ok, result} <- final_result(paths, transport.events),
         :ok <- schema_valid(result),
         :ok <- allowed_for_request(result, request) do
      response = Map.merge(bounded(transport), %{result: result, codex_session_id: transport.session_id, exit_status: 0})
      if result["status"] == "failed", do: {:error, failure(:role_failed, response)}, else: {:ok, response}
    else
      {:error, kind, detail} -> {:error, failure(kind, Map.merge(bounded(transport), %{detail: detail, codex_session_id: transport.session_id}))}
    end
  end

  defp final_result(paths, events) do
    case File.read(paths.last_message) do
      {:ok, json} ->
        decode_final(json)

      {:error, :enoent} ->
        events
        |> Enum.reverse()
        |> Enum.find_value(fn event -> Map.get(event, "result") end)
        |> case do
          nil -> {:error, :missing_final_result, :no_result_event}
          result -> {:ok, result}
        end

      {:error, reason} ->
        {:error, :artifact_read, reason}
    end
  end

  defp decode_final(json) do
    case Jason.decode(json) do
      {:ok, result} when is_map(result) -> {:ok, result}
      _ -> {:error, :invalid_final_json, :not_an_object}
    end
  end

  defp schema_valid(result) do
    required = ["status", "role", "task_id", "attempt_id", "execution_id"]

    if Enum.all?(required, &(is_binary(result[&1]) and byte_size(result[&1]) > 0)) and result["status"] in ["completed", "failed"] and
         (result["status"] != "failed" or (is_binary(result["reason"]) and byte_size(result["reason"]) > 0)) do
      :ok
    else
      {:error, :schema, :required_fields_or_failed_reason}
    end
  end

  defp allowed_for_request(result, request) do
    if result["role"] == request.role and result["task_id"] == request.task_id and result["attempt_id"] == request.attempt_id and
         result["execution_id"] == request.execution_id and not (request.role == "developer" and Map.has_key?(result, "sha")) do
      :ok
    else
      {:error, :not_allowed, :identity_or_role_policy}
    end
  end

  defp session_id(value) when is_map(value) do
    Map.get(value, "codex_session_id") || Map.get(value, "session_id") || Map.get(value, "thread_id") ||
      Enum.find_value(value, fn {_key, child} -> session_id(child) end)
  end

  defp session_id(value) when is_list(value), do: Enum.find_value(value, &session_id/1)
  defp session_id(_), do: nil

  defp bound(existing, addition) do
    binary = existing <> addition

    if byte_size(binary) > @max_capture do
      binary_part(binary, byte_size(binary) - @max_capture, @max_capture)
    else
      binary
    end
  end

  defp bounded(transport), do: Map.take(transport, [:output, :truncated?, :exit_status])
  defp failure(kind, detail), do: %{kind: kind, detail: detail}
end
