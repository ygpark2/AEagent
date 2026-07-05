defmodule AOS.AgentOS.DashboardService do
  @moduledoc """
  Application service for the agent dashboard LiveView.
  """

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.MCP.Internal.Shell
  alias AOS.AgentOS.Skills.CommandFormatter
  alias AOS.AgentOS.ToolUse.ApprovalQueue
  alias AOSWeb.Live.Presenters.AgentDashboardPresenter

  def initial_assigns(default_ui_settings) do
    %{
      messages: [],
      current_status: "Ready",
      file_tree: load_file_tree(),
      active_diff: "",
      input_value: "",
      session_id: nil,
      prompt_history: [],
      agent_pid: nil,
      pending_approvals: %{},
      durable_approvals: durable_approvals(),
      active_right_tab: :inspection,
      ui_settings: default_ui_settings,
      full_width: true
    }
  end

  def disconnected_assigns(default_ui_settings) do
    %{
      messages: [],
      current_status: "Connecting...",
      file_tree: "Loading...",
      active_diff: "",
      input_value: "",
      session_id: nil,
      prompt_history: [],
      agent_pid: nil,
      pending_approvals: %{},
      durable_approvals: [],
      active_right_tab: :inspection,
      ui_settings: default_ui_settings,
      full_width: true
    }
  end

  def submit_message(message, assigns, notify_pid) do
    case handle_command(String.trim(message), assigns) do
      {:ok, updates} ->
        updates

      :not_a_command ->
        enqueue_message(message, assigns, notify_pid)
    end
  end

  defp enqueue_message(message, assigns, notify_pid) do
    existing_messages = assigns.messages
    user_msg = %{role: "user", content: message, type: :chat}
    new_messages = existing_messages ++ [user_msg]

    {:ok, execution} =
      Executions.enqueue(message,
        notify: notify_pid,
        history: chat_history(new_messages),
        session_id: assigns.session_id
      )

    execution_msg = %{
      role: "system",
      content: "Execution queued: #{execution.id}",
      type: :system
    }

    %{
      messages: new_messages ++ [execution_msg],
      input_value: "",
      current_status: "Designing workflow...",
      session_id: execution.session_id,
      prompt_history: assigns.prompt_history ++ [message]
    }
  end

  def receive_tool_approval_request(assigns, approval_ref, tool_name, args, requester_pid) do
    approval_msg = AgentDashboardPresenter.approval_message(approval_ref, tool_name, args)
    pending_approvals = Map.put(assigns.pending_approvals, approval_ref, requester_pid)

    %{
      messages: assigns.messages ++ [approval_msg],
      current_status: "Waiting for approval...",
      pending_approvals: pending_approvals
    }
  end

  def resolve_tool_approval(assigns, approval_ref, decision) do
    case Map.pop(assigns.pending_approvals, approval_ref) do
      {nil, pending_approvals} ->
        %{pending_approvals: pending_approvals}

      {requester_pid, pending_approvals} ->
        send(requester_pid, {:tool_approval, approval_ref, decision})

        %{
          messages: update_approval_messages(assigns.messages, approval_ref, decision),
          current_status: approval_status_text(decision),
          pending_approvals: pending_approvals
        }
    end
  end

  def durable_approvals do
    ApprovalQueue.list_pending()
    |> Enum.map(&ApprovalQueue.serialize/1)
  end

  def merge_ui_settings(
        current,
        params,
        defaults \\ AgentDashboardPresenter.default_ui_settings()
      ) do
    Enum.reduce(params, current, fn {key, value}, acc ->
      Map.put(acc, key, normalize_ui_setting(key, value, defaults))
    end)
  end

  defp load_file_tree do
    case Shell.call_tool("list_codebase_structure", %{}) do
      {:ok, %{content: [%{text: file_tree} | _]}} -> file_tree
      _ -> "Unable to load workspace structure."
    end
  end

  defp handle_command("", assigns) do
    {:ok, append_system_message(assigns, help_text())}
  end

  defp handle_command("/help", assigns) do
    {:ok, append_system_message(assigns, help_text())}
  end

  defp handle_command("/session", assigns) do
    {:ok, append_system_message(assigns, "session_id=#{assigns.session_id || "(new)"}")}
  end

  defp handle_command("/history", assigns) do
    history_text =
      case assigns.prompt_history do
        [] ->
          "no user prompts yet"

        prompts ->
          prompts
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {prompt, index} -> "#{index}. #{prompt}" end)
      end

    {:ok, append_system_message(assigns, history_text)}
  end

  defp handle_command("/skills", assigns) do
    {:ok, append_system_message(assigns, CommandFormatter.registered_skills_text())}
  end

  defp handle_command(command, assigns) when is_binary(command) do
    if String.starts_with?(command, "/") do
      {:ok,
       append_system_message(
         assigns,
         "unknown command: #{command}\nuse /help to list available commands"
       )}
    else
      :not_a_command
    end
  end

  defp handle_command(_message, _assigns), do: :not_a_command

  defp append_system_message(assigns, content) do
    %{
      messages: assigns.messages ++ [%{role: "system", content: content, type: :system}],
      input_value: "",
      current_status: assigns.current_status
    }
  end

  defp help_text do
    Enum.join(
      [
        "/help show commands",
        "/session show current session id",
        "/history show user prompts in this dashboard session",
        "/skills show registered skills"
      ],
      "\n"
    )
  end

  defp chat_history(messages) do
    messages
    |> Enum.reject(&(&1.type == :system))
    |> Enum.map(&{&1.role, &1.content})
  end

  defp update_approval_messages(messages, approval_ref, decision) do
    Enum.map(messages, fn
      %{approval_ref: ^approval_ref} = msg ->
        %{msg | status: approval_message_status(decision)}

      msg ->
        msg
    end)
  end

  defp approval_status_text(:approved), do: "Approved tool execution."
  defp approval_status_text(:rejected), do: "Rejected tool execution."
  defp approval_status_text(_decision), do: "Tool approval resolved."

  defp approval_message_status(:approved), do: "Approved"
  defp approval_message_status(:rejected), do: "Rejected"
  defp approval_message_status(_decision), do: "Resolved"

  defp normalize_ui_setting(key, value, defaults)
       when key in ["left_font_size", "center_font_size", "right_font_size", "input_font_size"] do
    case Integer.parse(to_string(value)) do
      {size, ""} -> max(12, min(size, 24))
      _ -> Map.get(defaults, key)
    end
  end

  defp normalize_ui_setting("chat_width", value, _defaults) do
    case value do
      width when width in ["75", "85", "90", "100"] -> width
      _ -> "90"
    end
  end

  defp normalize_ui_setting("message_density", value, _defaults) do
    case value do
      density when density in ["compact", "comfortable", "relaxed"] -> density
      _ -> "comfortable"
    end
  end

  defp normalize_ui_setting(_key, value, _defaults), do: value
end
