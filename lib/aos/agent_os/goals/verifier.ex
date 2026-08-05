defmodule AOS.AgentOS.Goals.Verifier do
  @moduledoc """
  Small, deterministic verifier for Goal completion criteria.

  Criteria are intentionally data-driven so integrations can add richer
  verifiers later without changing the Goal lifecycle.
  """

  alias AOS.AgentOS.Core.Execution

  def verify(goal, %Execution{} = execution) do
    criteria = goal.success_criteria || %{}

    case verify_criteria(criteria, execution) do
      {:ok, details} -> %{passed: true, details: details}
      {:error, reason} -> %{passed: false, details: %{reason: reason}}
    end
  end

  defp verify_criteria(criteria, _execution) when criteria in [%{}, nil],
    do: {:ok, %{type: "execution_status", status: "succeeded"}}

  defp verify_criteria(%{"type" => "execution_status", "value" => expected}, execution),
    do: compare_status(execution.status, expected)

  defp verify_criteria(%{type: "execution_status", value: expected}, execution),
    do: compare_status(execution.status, expected)

  defp verify_criteria(%{"type" => "result_contains", "value" => expected}, execution),
    do: result_contains(execution.final_result, expected)

  defp verify_criteria(%{type: "result_contains", value: expected}, execution),
    do: result_contains(execution.final_result, expected)

  defp verify_criteria(%{"all" => criteria}, execution) when is_list(criteria),
    do: verify_all(criteria, execution)

  defp verify_criteria(%{all: criteria}, execution) when is_list(criteria),
    do: verify_all(criteria, execution)

  defp verify_criteria(_criteria, _execution),
    do: {:error, "unsupported success criteria"}

  defp verify_all(criteria, execution) do
    Enum.reduce_while(criteria, {:ok, []}, fn criterion, {:ok, details} ->
      case verify_criteria(criterion, execution) do
        {:ok, detail} -> {:cont, {:ok, [detail | details]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, details} -> {:ok, %{type: "all", criteria: Enum.reverse(details)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compare_status(status, expected) when is_binary(expected) do
    if status == expected do
      {:ok, %{type: "execution_status", status: status}}
    else
      {:error, "expected execution status #{expected}, got #{status}"}
    end
  end

  defp compare_status(_status, _expected), do: {:error, "execution status value is required"}

  defp result_contains(result, expected)
       when is_binary(result) and is_binary(expected) do
    if String.contains?(result, expected) do
      {:ok, %{type: "result_contains", value: expected}}
    else
      {:error, "execution result did not contain expected text"}
    end
  end

  defp result_contains(_result, _expected),
    do: {:error, "result_contains requires a string result and value"}
end
