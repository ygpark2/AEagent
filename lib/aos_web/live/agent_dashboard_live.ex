defmodule AOSWeb.AgentDashboardLive do
  @moduledoc """
  UI for Autonomous Evolutionary Agent.
  Handles both engine and tool-level notification tuples.
  """
  use AOSWeb, :live_view
  require Logger
  alias AOS.AgentOS.DashboardService
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.ApprovalQueue
  alias AOSWeb.Live.Presenters.AgentDashboardPresenter

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      {:ok, assign(socket, DashboardService.initial_assigns(default_ui_settings()))}
    else
      {:ok, assign(socket, DashboardService.disconnected_assigns(default_ui_settings()))}
    end
  end

  @impl true
  def handle_event("submit_message", %{"message" => message}, socket) do
    if message == "" do
      {:noreply, socket}
    else
      {:noreply, assign(socket, DashboardService.submit_message(message, socket.assigns, self()))}
    end
  end

  @impl true
  def handle_event("approve_tool", %{"ref" => approval_ref}, socket) do
    {:noreply,
     assign(
       socket,
       DashboardService.resolve_tool_approval(socket.assigns, approval_ref, :approved)
     )}
  end

  @impl true
  def handle_event("reject_tool", %{"ref" => approval_ref}, socket) do
    {:noreply,
     assign(
       socket,
       DashboardService.resolve_tool_approval(socket.assigns, approval_ref, :rejected)
     )}
  end

  @impl true
  def handle_event("switch_right_tab", %{"tab" => tab}, socket) do
    active_right_tab =
      case tab do
        "settings" -> :settings
        "approvals" -> :approvals
        _ -> :inspection
      end

    {:noreply,
     assign(socket,
       active_right_tab: active_right_tab,
       durable_approvals: DashboardService.durable_approvals()
     )}
  end

  @impl true
  def handle_event("approve_durable_approval", %{"id" => id}, socket) do
    {:noreply, resolve_durable_approval(socket, id, :approved)}
  end

  @impl true
  def handle_event("reject_durable_approval", %{"id" => id}, socket) do
    {:noreply, resolve_durable_approval(socket, id, :rejected)}
  end

  @impl true
  def handle_event("update_ui_settings", %{"ui" => params}, socket) do
    {:noreply,
     assign(socket,
       ui_settings: DashboardService.merge_ui_settings(socket.assigns.ui_settings, params)
     )}
  end

  @impl true
  def handle_event("reset_ui_settings", _params, socket) do
    {:noreply, assign(socket, ui_settings: default_ui_settings())}
  end

  # --- Real-time Streaming Handlers ---

  @impl true
  def handle_info({:llm_stream_started, ref}, socket) do
    message = %{role: "assistant", type: :chat, content: "", stream_ref: ref}
    {:noreply, assign(socket, messages: socket.assigns.messages ++ [message])}
  end

  @impl true
  def handle_info({:llm_stream_delta, ref, text}, socket) do
    messages =
      Enum.map(socket.assigns.messages, fn message ->
        if Map.get(message, :stream_ref) == ref,
          do: Map.update!(message, :content, &(&1 <> text)),
          else: message
      end)

    {:noreply, assign(socket, messages: messages)}
  end

  @impl true
  def handle_info({:llm_stream_finished, ref, _status}, socket) do
    messages = Enum.reject(socket.assigns.messages, &(Map.get(&1, :stream_ref) == ref))
    {:noreply, assign(socket, messages: messages)}
  end

  @impl true
  def handle_info({:architect_status, status}, socket) do
    new_message = AgentDashboardPresenter.architect_message(status)

    {:noreply,
     assign(socket, messages: socket.assigns.messages ++ [new_message], current_status: status)}
  end

  # Handle 3-element tuple from Engine
  @impl true
  def handle_info({:workflow_step_started, node_id, _module}, socket) do
    handle_step_started(to_string(node_id), socket)
  end

  # Handle 2-element tuple from Tools/LLM
  @impl true
  def handle_info({:workflow_step_started, display_name}, socket) do
    handle_step_started(display_name, socket)
  end

  # Handle 4-element tuple from Engine
  @impl true
  def handle_info({:workflow_step_completed, node_id, module, context}, socket) do
    handle_step_completed(node_id, module, context, socket)
  end

  # Handle 3-element tuple from Tools/LLM
  @impl true
  def handle_info({:workflow_step_completed, display_name, result_map}, socket) do
    handle_step_completed(display_name, nil, result_map, socket)
  end

  @impl true
  def handle_info({:workflow_error, node_id, reason}, socket) do
    new_message = AgentDashboardPresenter.workflow_error_message(node_id, reason)

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [new_message],
       current_status: "Error occurred."
     )}
  end

  @impl true
  def handle_info({:execution_terminal, status, execution}, socket) do
    {messages, current_status} =
      AgentDashboardPresenter.terminal_messages(socket.assigns.messages, status, execution)

    {:noreply,
     assign(socket,
       messages: messages,
       current_status: current_status
     )}
  end

  @impl true
  def handle_info({:panel_debate_event, event}, socket) do
    new_message = AgentDashboardPresenter.panel_debate_message(event)

    {:noreply,
     assign(socket,
       messages: socket.assigns.messages ++ [new_message],
       current_status: new_message.content
     )}
  end

  @impl true
  def handle_info(
        {:request_tool_confirmation, approval_ref, tool_name, args, requester_pid},
        socket
      ) do
    {:noreply,
     assign(
       socket,
       DashboardService.receive_tool_approval_request(
         socket.assigns,
         approval_ref,
         tool_name,
         args,
         requester_pid
       )
     )}
  end

  defp handle_step_completed(node_id, module, data, socket) do
    {new_message, status_text, inspection} =
      AgentDashboardPresenter.step_completed_message(node_id, module, data)

    socket =
      socket
      |> assign(
        messages: socket.assigns.messages ++ [new_message],
        current_status: status_text
      )
      |> maybe_assign_inspection(inspection)

    {:noreply, socket}
  end

  defp handle_step_started(name, socket) do
    {new_message, content} = AgentDashboardPresenter.step_started_message(name)

    {:noreply,
     assign(socket, messages: socket.assigns.messages ++ [new_message], current_status: content)}
  end

  defp maybe_assign_inspection(socket, nil), do: socket
  defp maybe_assign_inspection(socket, inspection), do: assign(socket, active_diff: inspection)

  defp resolve_durable_approval(socket, id, decision) do
    result =
      case decision do
        :approved -> ApprovalQueue.approve(id, %{decided_by: "dashboard"})
        :rejected -> ApprovalQueue.reject(id, %{decided_by: "dashboard"})
      end

    case result do
      {:ok, request} ->
        maybe_resume_after_approval(decision, request)

        assign(socket,
          durable_approvals: DashboardService.durable_approvals(),
          current_status: "Approval #{request.status}."
        )

      {:error, reason} ->
        assign(socket, current_status: "Approval failed: #{inspect(reason)}")
    end
  end

  defp maybe_resume_after_approval(:approved, %{execution_id: execution_id})
       when is_binary(execution_id) do
    Executions.resume_execution(execution_id, async: true, start_immediately: true)
  end

  defp maybe_resume_after_approval(_decision, _request), do: :ok

  defp default_ui_settings do
    AgentDashboardPresenter.default_ui_settings()
  end
end
