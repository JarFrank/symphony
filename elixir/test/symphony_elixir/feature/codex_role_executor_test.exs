defmodule SymphonyElixir.Feature.CodexRoleExecutorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Feature.{CodexRoleExecutor, Sandbox}

  test "planning request carries the authoritative spec and a strict two-task schema" do
    request = request(assignment("mastermind", "Planning", "planning"))
    assert request.prompt =~ "Approved specification:"
    assert request.prompt =~ "authoritative spec"
    assert request.result_schema["properties"]["tasks"]["minItems"] == 2
    assert request.result_schema["properties"]["tasks"]["maxItems"] == 2
    assert Enum.sort(request.result_schema["required"]) == Enum.sort(Map.keys(request.result_schema["properties"]))
    assert request.role == "mastermind"
    assert request.skip_git_repo_check == true
  end

  test "resolver prompt distinguishes technical resolution from a human-level decision" do
    assignment =
      assignment("mastermind", "Resolving", "task-1")
      |> put_in([:input, "question"], "Which contract applies?")

    request = request(assignment)
    assert request.prompt =~ "Resolve routine"
    assert request.prompt =~ "technical choices yourself"
    assert request.prompt =~ "Which contract applies?"
    assert request.result_schema["properties"]["status"]["enum"] == ["resolved", "human_decision_required", "failed"]
  end

  test "Developer request excludes SHA authority and contains only actionable rework context" do
    assignment =
      assignment("developer", "Implementing", "task-1")
      |> put_in([:input, "findings"], ["Fix the boundary"])

    request = request(assignment)
    assert request.prompt =~ "Do not commit, push, publish"
    assert request.prompt =~ "Fix the boundary"
    refute Map.has_key?(request.result_schema["properties"], "sha")
    assert request.result_schema["properties"]["status"]["enum"] == ["completed", "technical_question", "failed"]
  end

  test "task and final Reviewer requests are tied to the exact SHA" do
    task = request(assignment("reviewer", "Reviewing", "task-1"))
    final = request(assignment("reviewer", "FinalReview", "task-2"))

    assert task.reviewed_sha == String.duplicate("a", 40)
    assert task.prompt =~ "detached checkout"
    assert task.prompt =~ task.reviewed_sha
    assert task.prompt =~ ~s("kind":"task")
    assert final.prompt =~ ~s("kind":"final")
    assert final.result_schema["properties"]["status"]["enum"] == ["approved", "changes_requested", "technical_question", "failed"]
  end

  test "invalid options and requests fail before Codex execution" do
    assert {:error, :invalid_codex_role_options} =
             CodexRoleExecutor.request(assignment("developer", "Implementing", "task-1"), %{}, sandbox())

    assert {:error, :invalid_codex_role_request} = CodexRoleExecutor.request(:invalid, %{}, sandbox())
    assert {:error, :invalid_codex_role_request} = CodexRoleExecutor.execute(:invalid, %{})

    executor = CodexRoleExecutor.executor(%{model: "model", reasoning_effort: "low"})
    assert is_function(executor, 1)

    assert {:error, _reason} =
             CodexRoleExecutor.execute(
               assignment("developer", "Implementing", "task-1"),
               %{model: "model", reasoning_effort: "low"}
             )
  end

  defp request(assignment) do
    assert {:ok, request} =
             CodexRoleExecutor.request(
               assignment,
               %{model: "model", reasoning_effort: "high", skip_git_repo_check: true},
               sandbox()
             )

    request
  end

  defp assignment(role, phase, task_id) do
    input = %{
      "answer" => "existing answer",
      "current" => if(task_id == "task-2", do: 1, else: 0),
      "findings" => [],
      "spec" => "authoritative spec",
      "tasks" => [
        %{"id" => "task-1", "scope" => "first", "acceptance" => "first accepted"},
        %{"id" => "task-2", "scope" => "second", "acceptance" => "second accepted"}
      ]
    }

    %{
      attempt_id: "attempt",
      execution: %{
        attempt_id: "attempt",
        execution_id: "execution",
        feature_id: "feature",
        owner_token: "owner",
        revision: 1
      },
      execution_id: "execution",
      input: input,
      output_dir: "/output",
      phase: phase,
      reviewed_sha: String.duplicate("a", 40),
      role: role,
      runtime: "/runtime/state.sqlite3",
      task_id: task_id,
      workspace: "/workspace"
    }
  end

  defp sandbox do
    %Sandbox.Profile{
      auth_source: nil,
      codex_binary: nil,
      developer_workspace: nil,
      kind: :standard,
      output: "/output",
      role: :test,
      root: "/root",
      runtime: "/runtime/state.sqlite3",
      workspace: "/workspace"
    }
  end
end
