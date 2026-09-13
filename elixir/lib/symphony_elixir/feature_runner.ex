defmodule SymphonyElixir.FeatureRunner do
  @moduledoc """
  Standalone Stage 1 entry point, intentionally not wired into production dispatch.
  capture/3 durably records a result; advance/3 atomically consumes it and moves
  the feature. step/3 combines them. Re-entry never repeats a recorded result.
  """
  alias SymphonyElixir.Feature.{State, Store}

  @spec create(Path.t(), String.t(), String.t()) :: map()
  def create(path, id, spec) do
    Store.transaction(path, fn db ->
      Store.execute(db, "INSERT OR IGNORE INTO features VALUES (?, 0, ?)", [id, Jason.encode!(State.new(spec))])
      state = Store.fetch(db, id)
      if state["spec"] != spec, do: raise(ArgumentError, "feature specification changed")
      state
    end)
  end

  @spec get(Path.t(), String.t()) :: map()
  def get(path, id), do: Store.transaction(path, &Store.fetch(&1, id))

  @spec step(Path.t(), String.t(), (String.t(), map() -> map())) :: map()
  def step(path, id, executor) do
    case capture(path, id, executor) do
      {:captured, revision} -> advance(path, id, revision)
      {:idle, state} -> state
    end
  end

  @spec capture(Path.t(), String.t(), (String.t(), map() -> map())) :: tuple()
  def capture(path, id, executor) do
    prepared =
      Store.transaction(path, fn db ->
        state = Store.fetch(db, id)

        if State.role(state) do
          Store.execute(db, "INSERT OR IGNORE INTO attempts VALUES (?, ?, 'running', NULL)", [id, state["revision"]])
          {:ready, state["revision"]}
        else
          {:idle, state}
        end
      end)

    execute_attempt(path, id, executor, prepared)
  end

  defp execute_attempt(_path, _id, _executor, {:idle, state}), do: {:idle, state}

  defp execute_attempt(path, id, executor, {:ready, revision}) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      [[status, _]] = Store.execute(db, "SELECT status, result_json FROM attempts WHERE feature_id = ? AND revision = ?", [id, revision])

      if status == "running" do
        result = executor.(State.role(state), state)
        Store.execute(db, "UPDATE attempts SET status = 'recorded', result_json = ? WHERE feature_id = ? AND revision = ?", [encode_result(state, result), id, revision])
      end

      {:captured, revision}
    end)
  end

  @spec advance(Path.t(), String.t(), non_neg_integer()) :: map()
  def advance(path, id, revision) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      [["recorded", json]] = Store.execute(db, "SELECT status, result_json FROM attempts WHERE feature_id = ? AND revision = ?", [id, revision])
      next = State.transition(state, Jason.decode!(json))
      saved = Store.save(db, id, revision, next)
      Store.execute(db, "UPDATE attempts SET status = 'applied' WHERE feature_id = ? AND revision = ?", [id, revision])
      saved
    end)
  end

  @spec answer(Path.t(), String.t(), non_neg_integer(), String.t()) :: map()
  def answer(path, id, revision, answer) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)
      ensure_revision!(state, revision)
      if state["phase"] != "WaitingForHuman", do: raise(ArgumentError, "not waiting for human")
      Store.save(db, id, revision, State.answer(state, answer))
    end)
  end

  defp ensure_revision!(%{"revision" => revision}, revision), do: :ok
  defp ensure_revision!(_, _), do: raise(ArgumentError, "stale revision")

  defp encode_result(state, result) do
    if State.valid_result?(state, result) do
      case Jason.encode(result) do
        {:ok, json} -> json
        {:error, _} -> invalid_result_json()
      end
    else
      invalid_result_json()
    end
  rescue
    Protocol.UndefinedError -> invalid_result_json()
  end

  defp invalid_result_json, do: Jason.encode!(%{"status" => "invalid"})
end
