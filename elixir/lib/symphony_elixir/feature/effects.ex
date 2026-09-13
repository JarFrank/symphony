defmodule SymphonyElixir.Feature.Effects do
  @moduledoc "Durable fake effect intents. Reconcile before execution on every retry."
  alias SymphonyElixir.Feature.Store

  @spec intent(Path.t(), String.t(), String.t(), map()) :: :ok
  def intent(path, id, key, intent) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      Store.execute(db, "INSERT OR IGNORE INTO effects VALUES (?, ?, 'intent', ?, NULL, ?)", [id, key, Jason.encode!(intent), state["revision"]])
      [[json]] = Store.execute(db, "SELECT intent_json FROM effects WHERE feature_id = ? AND operation_key = ?", [id, key])
      if Jason.decode!(json) != intent, do: raise(ArgumentError, "effect key reused for different intent")
      :ok
    end)
  end

  @spec run(Path.t(), String.t(), String.t(), (String.t(), map() -> tuple()), (String.t(), map() -> term())) :: term()
  def run(path, id, key, reconcile, execute) do
    Store.transaction(path, fn db ->
      [[status, intent, result, revision]] = Store.execute(db, "SELECT status, intent_json, result_json, feature_revision FROM effects WHERE feature_id = ? AND operation_key = ?", [id, key])

      if status == "completed" do
        Jason.decode!(result)
      else
        intent = Jason.decode!(intent)

        result = reconcile_or_execute(db, {id, key, revision}, intent, reconcile, execute)

        Store.execute(db, "UPDATE effects SET status = 'completed', result_json = ? WHERE feature_id = ? AND operation_key = ?", [Jason.encode!(result), id, key])
        result
      end
    end)
  end

  defp reconcile_or_execute(db, {id, key, revision}, intent, reconcile, execute) do
    case reconcile.(key, intent) do
      {:found, existing} ->
        existing

      :missing ->
        ensure_revision!(db, id, revision)
        execute.(key, intent)
    end
  end

  defp ensure_revision!(db, id, revision) do
    if Store.fetch(db, id)["revision"] != revision, do: raise(ArgumentError, "stale effect revision")
  end
end
