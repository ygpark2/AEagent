defmodule AOS.AgentOS.Tools.ResultNormalizer do
  @moduledoc false

  def normalize(server_id, tool_name, args, metadata, decision, raw_result, attempts) do
    case raw_result do
      {:ok, result} ->
        %{
          ok: true,
          status: "succeeded",
          server_id: server_id,
          tool_name: tool_name,
          arguments: args,
          risk_tier: metadata.risk_tier,
          requires_confirmation: metadata.requires_confirmation,
          approval_status: approval_status(decision, metadata.requires_confirmation),
          attempts: attempts,
          user_message: "Tool #{tool_name} completed.",
          error_message: nil,
          content: Map.get(result, :content) || Map.get(result, "content") || [],
          inspection: Map.get(result, :inspection) || Map.get(result, "inspection"),
          raw_result: result
        }

      {:error, reason} ->
        message = error_message(reason)

        %{
          ok: false,
          status: error_status(decision),
          server_id: server_id,
          tool_name: tool_name,
          arguments: args,
          risk_tier: metadata.risk_tier,
          requires_confirmation: metadata.requires_confirmation,
          approval_status: approval_status(decision, metadata.requires_confirmation),
          attempts: attempts,
          user_message: "Tool #{tool_name} failed: #{message}",
          error_message: message,
          content: [%{type: "text", text: "Tool #{tool_name} failed: #{message}"}],
          inspection: nil,
          raw_result: nil
        }
    end
  end

  defp approval_status(:approved, _), do: "approved"
  defp approval_status(:rejected, _), do: "rejected"
  defp approval_status(:pending, _), do: "pending"
  defp approval_status(_decision, false), do: "not_required"
  defp approval_status(_decision, true), do: "pending"
  defp error_status(:rejected), do: "rejected"
  defp error_status(:pending), do: "pending"
  defp error_status(_decision), do: "failed"
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)
end
