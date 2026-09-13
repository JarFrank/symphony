defmodule SymphonyElixir.FeatureRunner do
  @moduledoc """
  Standalone Stage 2 Task 1 fake runner. It journals `prepare -> execute ->
  record -> apply`; only the three journal phases hold SQLite write locks.
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
      {:running, _execution} -> get(path, id)
    end
  end

  @spec capture(Path.t(), String.t(), (String.t(), map() -> map())) :: tuple()
  def capture(path, id, executor) do
    case prepare(path, id) do
      {:execute, execution} ->
        try do
          result = executor.(execution.state_role, execution.input)
          record(path, id, execution, result)
        rescue
          error ->
            release(path, id, execution)
            reraise error, __STACKTRACE__
        end

      other ->
        other
    end
  end

  @spec prepare(Path.t(), String.t()) :: tuple()
  def prepare(path, id) do
    Store.transaction(path, fn db ->
      state = Store.fetch(db, id)

      case State.role(state) do
        nil -> {:idle, state}
        role -> prepare_attempt(db, id, state, role)
      end
    end)
  end

  @spec record(Path.t(), String.t(), map(), term()) :: {:captured, non_neg_integer()}
  def record(path, id, execution, result) do
    Store.transaction(path, fn db ->
      [[status, execution_id, owner]] = Store.execute(db, "SELECT status, execution_id, execution_owner FROM attempts WHERE feature_id = ? AND revision = ?", [id, execution.revision])

      if status != "running" or execution_id != execution.execution_id or owner != execution.owner_token do
        raise ArgumentError, "stale execution"
      end

      Store.execute(db, "UPDATE attempts SET status = 'recorded', result_json = ? WHERE feature_id = ? AND revision = ? AND execution_id = ? AND execution_owner = ?", [
        encode_result(execution.input, result),
        id,
        execution.revision,
        execution.execution_id,
        execution.owner_token
      ])

      {:captured, execution.revision}
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

  defp prepare_attempt(db, id, state, role) do
    revision = state["revision"]
    owner = owner_token()
    rows = Store.execute(db, "SELECT status, execution_owner FROM attempts WHERE feature_id = ? AND revision = ?", [id, revision])

    case rows do
      [] -> create_execution(db, id, revision, state, role, owner)
      [["recorded", _]] -> {:captured, revision}
      [["running", ^owner]] -> {:running, %{revision: revision}}
      [["running", _]] -> create_execution(db, id, revision, state, role, owner)
    end
  end

  defp create_execution(db, id, revision, state, role, owner) do
    execution = %{
      attempt_id: token(),
      execution_id: token(),
      owner_token: owner,
      revision: revision,
      input: state,
      state_role: role
    }

    Store.execute(
      db,
      "INSERT INTO attempts (feature_id, revision, status, result_json, attempt_id, input_json, execution_id, execution_owner) VALUES (?, ?, 'running', NULL, ?, ?, ?, ?) ON CONFLICT(feature_id, revision) DO UPDATE SET execution_id = excluded.execution_id, execution_owner = excluded.execution_owner",
      [id, revision, execution.attempt_id, Jason.encode!(state), execution.execution_id, owner]
    )

    {:execute, execution}
  end

  defp release(path, id, execution) do
    Store.transaction(path, fn db ->
      Store.execute(db, "UPDATE attempts SET execution_owner = NULL WHERE feature_id = ? AND revision = ? AND execution_id = ? AND execution_owner = ? AND status = 'running'", [
        id,
        execution.revision,
        execution.execution_id,
        execution.owner_token
      ])
    end)
  end

  defp owner_token do
    key = {__MODULE__, :owner_token}

    case :persistent_term.get(key, nil) do
      nil ->
        value = token()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp token, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
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
