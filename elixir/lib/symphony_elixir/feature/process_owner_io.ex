defmodule SymphonyElixir.Feature.ProcessOwner.IO do
  @moduledoc false
  use GenServer

  alias SymphonyElixir.Feature.Store

  @default_max_buffer 64 * 1024

  @spec valid_execution_owner(map()) :: :ok | {:blocked, term()}
  def valid_execution_owner(execution) do
    if valid_owner_fields?(execution) do
      execution_id = Map.fetch!(execution, :execution_id)
      if Regex.match?(~r/^[A-Za-z0-9_-]+$/, execution_id), do: :ok, else: {:blocked, :invalid_execution_id}
    else
      {:blocked, :execution_owner_required}
    end
  end

  @spec start(Path.t(), map(), keyword()) :: {:ok, map()} | {:blocked, term()}
  def start(path, execution, options) do
    max_buffer = Keyword.get(options, :max_buffer_bytes, @default_max_buffer)

    with true <- is_integer(max_buffer) and max_buffer > 0,
         :ok <- prepare_directory(path, execution.execution_id),
         {:ok, paths} <- io_paths(path, execution.execution_id),
         :ok <- create_channels(paths),
         {:ok, pid} <- GenServer.start(__MODULE__, %{path: path, execution: execution, paths: paths, max_buffer: max_buffer}) do
      {:ok, handle(pid, path, execution, paths)}
    else
      false -> {:blocked, :invalid_io_buffer_limit}
      {:error, reason} -> {:blocked, reason}
    end
  end

  @spec paths(map()) :: map()
  def paths(%{paths: paths}), do: paths

  @spec write(map(), iodata()) :: :ok | {:blocked, term()}
  def write(handle, data) do
    binary = IO.iodata_to_binary(data)

    with :ok <- owned?(handle), true <- live?(handle) do
      GenServer.call(handle.pid, {:write, binary})
    else
      false -> {:blocked, :io_owner_unavailable}
      {:blocked, _} = blocked -> blocked
    end
  rescue
    ArgumentError -> {:blocked, :invalid_stdin}
  end

  @spec close_stdin(map()) :: :ok | {:blocked, term()}
  def close_stdin(handle), do: call_owned(handle, :close_stdin)
  @spec subscribe(map(), pid()) :: :ok | {:blocked, term()}
  def subscribe(handle, subscriber) when is_pid(subscriber), do: call_owned(handle, {:subscribe, subscriber})
  def subscribe(_, _), do: {:blocked, :invalid_subscriber}
  @spec output(map()) :: {:ok, map()} | {:blocked, term()}
  def output(handle), do: call_owned(handle, :output)

  @spec owned?(map()) :: :ok | {:blocked, term()}
  def owned?(%{path: path, execution_id: id, attempt_id: attempt_id, feature_id: feature_id, revision: revision, owner_token: owner}) do
    Store.transaction(path, fn db ->
      case Store.execute(
             db,
             "SELECT attempt_id, execution_owner FROM attempts WHERE feature_id = ? AND revision = ? AND execution_id = ? AND status = 'running'",
             [feature_id, revision, id]
           ) do
        [[^attempt_id, ^owner]] -> :ok
        _ -> {:blocked, {:stale_execution, id}}
      end
    end)
  end

  def owned?(_), do: {:blocked, :invalid_io_handle}

  @spec stop(Path.t(), String.t()) :: :ok
  def stop(path, execution_id) do
    case :persistent_term.get({__MODULE__, path, execution_id}, nil) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        :persistent_term.erase({__MODULE__, path, execution_id})
        File.rm_rf(io_directory(path, execution_id))
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def init(%{path: path, execution: execution, paths: paths} = state) do
    with {:ok, stdin} <- File.open(paths.stdin, [:read, :write, :binary]) do
      :persistent_term.put({__MODULE__, path, execution.execution_id}, self())
      Process.send_after(self(), :poll, 10)

      {:ok,
       Map.merge(state, %{
         stdin: stdin,
         stdout: "",
         stderr: "",
         stdout_offset: 0,
         stderr_offset: 0,
         stdout_truncated?: false,
         stderr_truncated?: false,
         stdin_closed?: false,
         subscribers: []
       })}
    end
  end

  @impl true
  def handle_call({:write, _binary}, _from, %{stdin_closed?: true} = state), do: {:reply, {:blocked, :stdin_closed}, state}

  def handle_call({:write, binary}, _from, state) do
    :ok = IO.binwrite(state.stdin, binary)
    {:reply, :ok, state}
  rescue
    error -> {:reply, {:blocked, {:stdin_unavailable, Exception.message(error)}}, state}
  end

  def handle_call(:close_stdin, _from, %{stdin_closed?: true} = state), do: {:reply, :ok, state}

  def handle_call(:close_stdin, _from, state) do
    :ok = File.close(state.stdin)
    {:reply, :ok, %{state | stdin_closed?: true}}
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    {:reply, :ok, %{state | subscribers: Enum.uniq([subscriber | state.subscribers])}}
  end

  def handle_call(:output, _from, state) do
    {:reply,
     {:ok,
      %{
        stdout: state.stdout,
        stderr: state.stderr,
        stdout_truncated?: state.stdout_truncated?,
        stderr_truncated?: state.stderr_truncated?
      }}, state}
  end

  @impl true
  def handle_info(:poll, state) do
    handle = handle(self(), state.path, state.execution, state.paths)

    case owned?(handle) do
      :ok ->
        next = poll_streams(state, handle)
        Process.send_after(self(), :poll, 20)
        {:noreply, next}

      {:blocked, _} ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close(state[:stdin])
    :persistent_term.erase({__MODULE__, state.path, state.execution.execution_id})
    File.rm_rf(Path.dirname(state.paths.stdin))
    :ok
  end

  defp call_owned(handle, message) do
    with :ok <- owned?(handle), true <- live?(handle) do
      GenServer.call(handle.pid, message)
    else
      false -> {:blocked, :io_owner_unavailable}
      {:blocked, _} = blocked -> blocked
    end
  end

  defp live?(%{pid: pid}), do: is_pid(pid) and Process.alive?(pid)
  defp live?(_), do: false

  defp handle(pid, path, execution, paths) do
    %{
      pid: pid,
      path: path,
      paths: paths,
      execution_id: execution.execution_id,
      attempt_id: execution.attempt_id,
      feature_id: execution.feature_id,
      revision: execution.revision,
      owner_token: execution.owner_token
    }
  end

  defp poll_streams(state, handle) do
    Enum.reduce([:stdout, :stderr], state, &poll_stream(&2, &1, handle))
  end

  defp poll_stream(state, stream, handle) do
    offset_key = if stream == :stdout, do: :stdout_offset, else: :stderr_offset

    case unread_chunk(Map.fetch!(state.paths, stream), Map.fetch!(state, offset_key)) do
      {:ok, chunk, next_offset} -> append_stream(state, stream, offset_key, chunk, next_offset, handle)
      :none -> state
    end
  end

  defp unread_chunk(path, offset) do
    case File.read(path) do
      {:ok, contents} when byte_size(contents) > offset ->
        {:ok, binary_part(contents, offset, byte_size(contents) - offset), byte_size(contents)}

      _ ->
        :none
    end
  end

  defp append_stream(state, stream, offset_key, chunk, next_offset, handle) do
    truncated_key = if stream == :stdout, do: :stdout_truncated?, else: :stderr_truncated?
    {buffer, truncated?} = bounded(Map.fetch!(state, stream), chunk, state.max_buffer)
    Enum.each(state.subscribers, &send(&1, {:process_owner_io, handle, stream, chunk}))

    state
    |> Map.put(stream, buffer)
    |> Map.put(offset_key, next_offset)
    |> Map.put(truncated_key, truncated? or Map.fetch!(state, truncated_key))
  end

  defp prepare_directory(path, execution_id) do
    directory = io_directory(path, execution_id)
    File.mkdir_p!(directory)
    File.chmod(directory, 0o700)
  end

  defp io_paths(path, execution_id) do
    directory = io_directory(path, execution_id)

    {:ok,
     %{
       stdin: Path.join(directory, "stdin"),
       stdout: Path.join(directory, "stdout"),
       stderr: Path.join(directory, "stderr")
     }}
  end

  defp io_directory(path, execution_id), do: Path.join([Path.dirname(path), "process-io", execution_id])

  defp create_channels(paths) do
    case System.cmd("mkfifo", ["--mode=600", paths.stdin], stderr_to_stdout: true) do
      {_output, 0} ->
        with :ok <- File.write(paths.stdout, ""),
             :ok <- File.chmod(paths.stdout, 0o600),
             :ok <- File.write(paths.stderr, "") do
          File.chmod(paths.stderr, 0o600)
        end

      {output, _} ->
        {:error, {:fifo_unavailable, output}}
    end
  end

  defp valid_owner_fields?(%{} = execution) do
    values = Map.values(Map.take(execution, [:execution_id, :attempt_id, :feature_id, :owner_token]))
    Enum.all?(values, &(is_binary(&1) and byte_size(&1) > 0)) and length(values) == 4 and is_integer(Map.get(execution, :revision))
  end

  defp valid_owner_fields?(_), do: false

  defp bounded(existing, addition, limit) do
    combined = existing <> addition
    truncated? = byte_size(combined) > limit
    buffer = if truncated?, do: binary_part(combined, byte_size(combined) - limit, limit), else: combined
    {buffer, truncated?}
  end

  defp close(nil), do: :ok
  defp close(device) when is_pid(device) or is_port(device), do: File.close(device)
end
