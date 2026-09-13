defmodule SymphonyElixir.Feature.Fake do
  @moduledoc "Explicit deterministic role result; scenarios own sequencing and observations."

  @spec executor(String.t(), map()) :: (String.t(), map() -> map())
  def executor(expected_role, result) do
    fn role, _state ->
      if role != expected_role, do: raise(ArgumentError, "unexpected role #{role}")
      result
    end
  end

  @spec plan() :: map()
  def plan do
    %{"status" => "planned", "tasks" => Enum.map(1..2, &%{"id" => "task-#{&1}", "scope" => "Implement part #{&1}", "acceptance" => "Check part #{&1}"})}
  end
end
