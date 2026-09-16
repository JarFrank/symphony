defmodule SymphonyElixir.Feature.CodexRoleExecutor do
  @moduledoc """
  Builds local feature-role prompts and executes them through `CodexExec`,
  `ProcessOwner`, and `Sandbox`.

  The returned function matches `LocalRunner`'s executor contract. Every call
  uses an ephemeral Codex session and a fresh output directory. Reviewer calls
  mount only the detached reviewer checkout supplied by the coordinator.
  """

  alias SymphonyElixir.Feature.{CodexExec, Sandbox}

  @type options :: %{
          required(:model) => String.t(),
          required(:reasoning_effort) => String.t(),
          optional(:skip_git_repo_check) => boolean()
        }

  @doc "Returns a secure role executor for `LocalRunner`."
  @spec executor(options()) :: (map() -> {:ok, map()} | {:error, term()})
  def executor(options) when is_map(options) do
    fn assignment -> execute(assignment, options) end
  end

  @doc "Executes one prepared local role assignment through the secure Codex transport."
  @spec execute(map(), options()) :: {:ok, map()} | {:error, term()}
  def execute(assignment, options) when is_map(assignment) and is_map(options) do
    with :ok <- validate_options(options),
         {:ok, sandbox} <-
           Sandbox.profile(
             role: :codex,
             workspace: assignment.workspace,
             output: assignment.output_dir,
             runtime: assignment.runtime
           ),
         {:ok, request} <- request(assignment, options, sandbox),
         {:ok, response} <- CodexExec.run(request) do
      {:ok, response.result}
    end
  end

  def execute(_assignment, _options), do: {:error, :invalid_codex_role_request}

  @doc false
  @spec request(map(), options(), Sandbox.profile()) :: {:ok, map()} | {:error, term()}
  def request(assignment, options, %Sandbox.Profile{} = sandbox) when is_map(assignment) and is_map(options) do
    with :ok <- validate_options(options) do
      {:ok,
       %{
         attempt_id: assignment.attempt_id,
         execution: assignment.execution,
         execution_id: assignment.execution_id,
         model: options.model,
         output_dir: assignment.output_dir,
         prompt: prompt(assignment),
         reasoning_effort: options.reasoning_effort,
         result_schema: result_schema(assignment),
         reviewed_sha: assignment[:reviewed_sha],
         role: assignment.role,
         runtime: assignment.runtime,
         sandbox: sandbox,
         skip_git_repo_check: Map.get(options, :skip_git_repo_check, false),
         task_id: assignment.task_id
       }}
    end
  end

  def request(_assignment, _options, _sandbox), do: {:error, :invalid_codex_role_request}

  defp validate_options(options) do
    if is_binary(options[:model]) and options[:model] != "" and
         is_binary(options[:reasoning_effort]) and options[:reasoning_effort] != "" do
      :ok
    else
      {:error, :invalid_codex_role_options}
    end
  end

  defp prompt(%{phase: "Planning"} = assignment) do
    """
    You are the Mastermind planner for one approved local feature. The approved
    specification below is authoritative. Produce exactly two small, ordered,
    deterministic implementation tasks. Each task requires a unique nonempty
    id, scope, and acceptance string. You may choose technical details implied
    by the repository architecture and existing contracts, but must not invent
    product requirements. Inspect but do not modify /workspace.

    Approved specification:
    #{assignment.input["spec"]}

    Return the invocation envelope required by the output schema. Set the outer
    status to completed and reason to null. Put the lifecycle result in result:
    {"status":"planned","tasks":[...]}. Repeat the exact role, task_id,
    attempt_id, and execution_id from the schema. Set non-applicable result
    fields to null.
    """
  end

  defp prompt(%{phase: "Resolving"} = assignment) do
    """
    You are the Mastermind coordinator resolving a technical implementation
    question. Treat the approved specification, current plan, repository
    architecture, and existing contracts as authoritative. Resolve routine
    technical choices yourself. Use human_decision_required only if answering
    would create or change a product requirement, weaken a security invariant,
    or materially break a public contract.
    Inspect but do not modify /workspace.

    Approved specification: #{assignment.input["spec"]}
    Question: #{assignment.input["question"]}
    Current task: #{Jason.encode!(current_task(assignment.input))}

    Put either {"status":"resolved","answer":"..."} or
    {"status":"human_decision_required","question":"..."} in result. Set the
    outer status to completed and reason to null, and repeat the exact invocation
    identity required by the schema. Set non-applicable result fields to null.
    """
  end

  defp prompt(%{role: "developer"} = assignment) do
    task = current_task(assignment.input)

    """
    You are the Developer for exactly one local implementation task. Work only
    in /workspace. Do not commit, push, publish, access a tracker, or claim a Git
    SHA; the coordinator exclusively captures the implementation commit. Follow
    the approved specification and existing repository contracts. Implement and
    test the task. If this is rework, address only the actionable findings below
    plus context required by the task.

    Approved specification: #{assignment.input["spec"]}
    Task: #{Jason.encode!(task)}
    Actionable findings: #{Jason.encode!(assignment.input["findings"] || [])}
    Resolved answer: #{assignment.input["answer"] || "none"}

    Put {"status":"completed"} in result when done, or a technical_question or
    failed lifecycle result when necessary. Never include sha in result. Set the
    outer status to completed and reason to null, and repeat the exact invocation
    identity required by the schema. Set non-applicable result fields to null.
    """
  end

  defp prompt(%{role: "reviewer", phase: phase} = assignment) do
    scope =
      if phase == "FinalReview" do
        %{"kind" => "final", "tasks" => assignment.input["tasks"]}
      else
        %{"kind" => "task", "task" => current_task(assignment.input)}
      end

    """
    You are an independent #{phase} reviewer. /workspace is a detached checkout
    of exactly #{assignment.reviewed_sha}. Review only that state. You cannot use
    or mutate the Developer workspace. Inspect the implementation and run the
    relevant local validation. Do not commit, push, publish, or access a tracker.

    Approved specification: #{assignment.input["spec"]}
    Review scope: #{Jason.encode!(scope)}

    Put an approved, changes_requested, technical_question, or failed lifecycle
    result in result. changes_requested requires a nonempty findings list and,
    during FinalReview, the affected task_id. Findings must be actionable. Set
    the outer status to completed and reason to null. Repeat the exact invocation
    identity and reviewed_sha required by the schema. Set non-applicable result
    fields to null.
    """
  end

  defp result_schema(%{role: "mastermind", phase: "Planning"}) do
    object_schema(%{
      "status" => %{"enum" => ["planned", "human_decision_required", "failed"]},
      "tasks" => %{
        "type" => ["array", "null"],
        "minItems" => 2,
        "maxItems" => 2,
        "items" =>
          object_schema(%{
            "id" => string_schema(),
            "scope" => string_schema(),
            "acceptance" => string_schema()
          })
      },
      "question" => nullable_string_schema(),
      "reason" => nullable_string_schema()
    })
  end

  defp result_schema(%{role: "mastermind"}) do
    object_schema(%{
      "status" => %{"enum" => ["resolved", "human_decision_required", "failed"]},
      "answer" => nullable_string_schema(),
      "question" => nullable_string_schema(),
      "reason" => nullable_string_schema()
    })
  end

  defp result_schema(%{role: "developer"}) do
    object_schema(%{
      "status" => %{"enum" => ["completed", "technical_question", "failed"]},
      "question" => nullable_string_schema(),
      "reason" => nullable_string_schema()
    })
  end

  defp result_schema(%{role: "reviewer"}) do
    object_schema(%{
      "status" => %{"enum" => ["approved", "changes_requested", "technical_question", "failed"]},
      "findings" => %{"type" => ["array", "null"], "minItems" => 1, "items" => string_schema()},
      "question" => nullable_string_schema(),
      "reason" => nullable_string_schema(),
      "task_id" => nullable_string_schema()
    })
  end

  defp object_schema(properties) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => Map.keys(properties),
      "properties" => properties
    }
  end

  defp string_schema, do: %{"type" => "string", "minLength" => 1}
  defp nullable_string_schema, do: %{"type" => ["string", "null"], "minLength" => 1}

  defp current_task(state), do: Enum.at(state["tasks"], state["current"])
end
