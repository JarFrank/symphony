defmodule SymphonyElixir.Feature.TechnicalRetry do
  @moduledoc "Durable, bounded retry state for coordinator operations, not role rework."
  alias SymphonyElixir.Feature.Store

  @spec ready?(Path.t(), String.t(), String.t(), integer()) :: boolean()
  def ready?(runtime, feature_id, key, now_ms \\ System.system_time(:millisecond)) do
    Store.read(runtime, fn db ->
      case Store.execute(db, "SELECT status, due_at_ms FROM technical_retries WHERE feature_id = ? AND operation_key = ?", [feature_id, key]) do
        [] -> true
        [["scheduled", due_at_ms]] -> due_at_ms <= now_ms
        [["completed", _]] -> true
        _ -> false
      end
    end)
  end

  @spec exhausted?(Path.t(), String.t(), String.t()) :: boolean()
  def exhausted?(runtime, feature_id, key) do
    Store.read(runtime, fn db ->
      Store.execute(db, "SELECT status FROM technical_retries WHERE feature_id = ? AND operation_key = ?", [feature_id, key]) == [["exhausted"]]
    end)
  end

  @spec attempts(Path.t(), String.t(), String.t()) :: non_neg_integer()
  def attempts(runtime, feature_id, key) do
    Store.read(runtime, fn db ->
      case Store.execute(db, "SELECT attempts FROM technical_retries WHERE feature_id = ? AND operation_key = ?", [feature_id, key]) do
        [[count]] -> count
        [] -> 0
      end
    end)
  end

  @doc "Returns the next durable scheduled wake-up for one feature."
  @spec next_due(Path.t(), String.t()) :: :none | {:scheduled, String.t(), integer(), non_neg_integer()}
  def next_due(runtime, feature_id) do
    Store.read(runtime, fn db ->
      case Store.execute(
             db,
             "SELECT operation_key, due_at_ms, attempts FROM technical_retries WHERE feature_id = ? AND status = 'scheduled' ORDER BY due_at_ms ASC LIMIT 1",
             [feature_id]
           ) do
        [[key, due_at_ms, attempts]] -> {:scheduled, key, due_at_ms, attempts}
        [] -> :none
      end
    end)
  end

  @spec schedule(
          Path.t(),
          String.t(),
          String.t(),
          String.t(),
          atom(),
          String.t(),
          map(),
          pos_integer(),
          non_neg_integer(),
          integer()
        ) ::
          :retry | :exhausted
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def schedule(runtime, feature_id, key, operation, classification, diagnostic, target, max_attempts, backoff_ms, now_ms \\ System.system_time(:millisecond)) do
    Store.transaction(runtime, fn db ->
      attempts =
        case Store.execute(db, "SELECT attempts FROM technical_retries WHERE feature_id = ? AND operation_key = ?", [feature_id, key]) do
          [[count]] -> count + 1
          [] -> 1
        end

      if attempts > max_attempts do
        upsert(db, %{
          feature_id: feature_id,
          key: key,
          operation: operation,
          status: "exhausted",
          classification: :retry_exhausted,
          diagnostic: diagnostic,
          attempts: attempts,
          max_attempts: max_attempts,
          due_at_ms: now_ms,
          target: target
        })

        :exhausted
      else
        # Linear backoff is deliberately journaled.  Callers do not sleep: a
        # later coordinator invocation observes the due time, including after
        # a VM restart.
        due_at_ms = now_ms + backoff_ms * attempts

        upsert(db, %{
          feature_id: feature_id,
          key: key,
          operation: operation,
          status: "scheduled",
          classification: classification,
          diagnostic: diagnostic,
          attempts: attempts,
          max_attempts: max_attempts,
          due_at_ms: due_at_ms,
          target: target
        })

        :retry
      end
    end)
  end

  @spec complete(Path.t(), String.t(), String.t()) :: :ok
  def complete(runtime, feature_id, key) do
    Store.transaction(runtime, fn db ->
      Store.execute(db, "UPDATE technical_retries SET status = 'completed' WHERE feature_id = ? AND operation_key = ?", [feature_id, key])
      :ok
    end)
  end

  defp upsert(db, attrs) do
    Store.execute(
      db,
      "INSERT INTO technical_retries (feature_id, operation_key, operation, status, classification, diagnostic, attempts, max_attempts, due_at_ms, target_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(feature_id, operation_key) DO UPDATE SET status = excluded.status, classification = excluded.classification, diagnostic = excluded.diagnostic, attempts = excluded.attempts, max_attempts = excluded.max_attempts, due_at_ms = excluded.due_at_ms, target_json = excluded.target_json",
      [
        attrs.feature_id,
        attrs.key,
        attrs.operation,
        attrs.status,
        Atom.to_string(attrs.classification),
        attrs.diagnostic,
        attrs.attempts,
        attrs.max_attempts,
        attrs.due_at_ms,
        Jason.encode!(attrs.target)
      ]
    )
  end
end
