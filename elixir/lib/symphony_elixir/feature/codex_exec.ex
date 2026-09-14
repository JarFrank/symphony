defmodule SymphonyElixir.Feature.CodexExec do
  @moduledoc """
  Narrow, standalone transport adapter for one `codex exec` role invocation.

  It deliberately does not update FeatureRunner or start a ProcessOwner unit:
  those lifecycle concerns remain at the Task 1--3 boundary.  A caller supplies
  the already-isolated role output directory and owns any ProcessOwner launch.
  This module owns only argv construction, stdin delivery, JSONL decoding and
  validation of the role's final structured message.
  """

  @max_capture 64 * 1024
  @roles ["mastermind", "developer", "reviewer", "test"]

  @type request :: %{
          required(:attempt_id) => String.t(),
          required(:execution_id) => String.t(),
          required(:role) => String.t() | atom(),
          required(:task_id) => String.t(),
          required(:model) => String.t(),
          required(:reasoning_effort) => String.t(),
          required(:prompt) => String.t(),
          required(:output_dir) => Path.t(),
          optional(:executable) => Path.t(),
          optional(:fixture_args) => [String.t()]
        }

  @spec run(request()) :: {:ok, map()} | {:error, map()}
  def run(request) do
    with {:ok, request} <- validate_request(request),
         {:ok, paths} <- prepare_artifacts(request),
         {:ok, transport} <- run_port(request, paths),
         result <- finish(request, paths, transport) do
      result
    else
      {:error, kind, detail} -> {:error, failure(kind, detail)}
    end
  end

  @spec argv(request(), map()) :: [String.t()]
  def argv(request, paths) do
    [
      "exec",
      "--json",
      "--model",
      request.model,
      "-c",
      "model_reasoning_effort=\"#{request.reasoning_effort}\"",
      "--output-schema",
      paths.schema,
      "--output-last-message",
      paths.last_message,
      "-"
    ] ++ Map.get(request, :fixture_args, [])
  end

  @spec output_schema() :: map()
  def output_schema do
    %{
      "type" => "object",
      "required" => ["status", "role", "task_id", "attempt_id", "execution_id"],
      "properties" => %{
        "status" => %{"enum" => ["completed", "failed"]},
        "role" => %{"type" => "string"},
        "task_id" => %{"type" => "string", "minLength" => 1},
        "attempt_id" => %{"type" => "string", "minLength" => 1},
        "execution_id" => %{"type" => "string", "minLength" => 1},
        "reason" => %{"type" => "string", "minLength" => 1}
      }
    }
  end

  defp validate_request(%{} = request) do
    role = request |> Map.get(:role) |> to_string()

    required = [:attempt_id, :execution_id, :task_id, :model, :reasoning_effort, :prompt, :output_dir]

    if role in @roles and Enum.all?(required, &(is_binary(request[&1]) and byte_size(request[&1]) > 0)) and
         File.dir?(request.output_dir) do
      {:ok, Map.put(request, :role, role)}
    else
      {:error, :invalid_request, :missing_or_invalid_field}
    end
  end

  defp validate_request(_), do: {:error, :invalid_request, :not_a_map}

  defp prepare_artifacts(request) do
    paths = %{
      schema: Path.join(request.output_dir, "codex-result-schema.json"),
      last_message: Path.join(request.output_dir, "codex-last-message.json")
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

  defp run_port(request, paths) do
    executable = Map.get(request, :executable, System.find_executable("codex") || "codex")
    port = Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(argv(request, paths), &String.to_charlist/1)])
    Port.command(port, request.prompt)
    Port.command(port, "\n")
    collect(port, %{buffer: "", events: [], session_id: nil, output: "", truncated?: false})
  rescue
    error -> {:error, :transport, Exception.message(error)}
  catch
    {:malformed_jsonl, line} -> {:error, :malformed_jsonl, line}
  end

  defp collect(port, state) do
    receive do
      {^port, {:data, chunk}} ->
        collect(port, consume(state, chunk))

      {^port, {:exit_status, status}} ->
        if state.buffer == "" do
          {:ok, Map.put(state, :exit_status, status)}
        else
          {:error, :partial_jsonl, bounded(state)}
        end
    end
  end

  defp consume(state, chunk) do
    {tail, lines} = String.split(state.buffer <> chunk, "\n") |> List.pop_at(-1)

    next = Enum.reduce(lines, %{state | buffer: ""}, fn line, acc -> parse_line(acc, line) end)
    %{next | buffer: tail, output: bound(next.output, chunk), truncated?: next.truncated? or byte_size(next.output) + byte_size(chunk) > @max_capture}
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

  defp finish(_request, _paths, %{exit_status: status} = transport) when status != 0,
    do: {:error, failure(:process, Map.merge(bounded(transport), %{exit_status: status}))}

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
