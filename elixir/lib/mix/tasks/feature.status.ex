defmodule Mix.Tasks.Feature.Status do
  use Mix.Task

  @shortdoc "Print a read-only LocalRunner feature status projection"

  @moduledoc """
  Prints standalone LocalRunner journal status without starting, reconciling, or
  retrying a feature.

      mix feature.status /path/to/state.sqlite3 feature-id
      mix feature.status /path/to/state.sqlite3 feature-id --watch
  """

  alias SymphonyElixir.Feature.LocalRunner

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [watch: :boolean])

    case {invalid, argv} do
      {[], [runtime, feature_id]} -> print_loop(Path.expand(runtime), feature_id, opts[:watch] || false)
      _ -> Mix.raise("Usage: mix feature.status <runtime> <feature-id> [--watch]")
    end
  end

  defp print_loop(runtime, feature_id, false), do: print_status(runtime, feature_id)

  defp print_loop(runtime, feature_id, true) do
    Stream.repeatedly(fn ->
      print_status(runtime, feature_id)
      Process.sleep(1_000)
    end)
    |> Stream.run()
  end

  defp print_status(runtime, feature_id) do
    case LocalRunner.status(runtime, feature_id) do
      {:ok, status} -> Mix.shell().info(render(status))
      {:blocked, reason} -> Mix.raise("Feature status unavailable: #{inspect(reason)}")
    end
  end

  defp render(status) do
    (basic_lines(status) ++ detail_lines(status))
    |> Enum.map_join("\n", &format_line/1)
  end

  defp basic_lines(status),
    do: [
      {"Feature", status.feature_id},
      {"Revision", status.revision},
      {"Phase", status.phase},
      {"Operation", default(status.operation)},
      {"Role", default(status.role)},
      {"Task", default(status.task_id)},
      {"Attempt", default(status.attempt_id)},
      {"Execution", default(status.execution_id)},
      {"Session", default(status.session_id)},
      {"SHA", default(status.sha)}
    ]

  defp detail_lines(status),
    do: [
      {"Elapsed", elapsed(status.started_at)},
      {"Latest event", default(status.latest_event)},
      {"Blocker", printable(status.blocker)},
      {"Technical retry", status.technical_retry_count},
      {"Next retry", default(status.next_retry_at)}
    ]

  defp format_line({label, value}), do: "#{label}: #{value}"
  defp default(nil), do: "none"
  defp default(value), do: value

  defp elapsed(nil), do: "unknown"
  defp elapsed(started_at) when is_integer(started_at), do: "#{max(System.system_time(:millisecond) - started_at, 0)}ms"
  defp elapsed(_), do: "unknown"
  defp printable(nil), do: "none"
  defp printable(value) when is_binary(value), do: value
  defp printable(value), do: inspect(value)
end
