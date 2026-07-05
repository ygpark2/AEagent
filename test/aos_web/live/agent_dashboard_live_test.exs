defmodule AOSWeb.AgentDashboardLiveTest do
  use AOSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.ApprovalQueue

  setup %{conn: conn} do
    {:ok, conn: put_admin_session(conn)}
  end

  test "renders approval request and approves tool execution", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    send(
      view.pid,
      {:request_tool_confirmation, "approval-123", "execute_command", %{"command" => "git"},
       self()}
    )

    assert render(view) =~ "Security Check"
    assert render(view) =~ "execute_command"

    view
    |> element("button[phx-click=\"approve_tool\"]")
    |> render_click()

    assert_receive {:tool_approval, "approval-123", :approved}
    assert render(view) =~ "Approved"
  end

  test "renders approval request and rejects tool execution", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    send(
      view.pid,
      {:request_tool_confirmation, "approval-456", "write_file", %{"path" => "tmp.txt"}, self()}
    )

    assert render(view) =~ "write_file"

    view
    |> element("button[phx-click=\"reject_tool\"]")
    |> render_click()

    assert_receive {:tool_approval, "approval-456", :rejected}
    assert render(view) =~ "Rejected"
  end

  test "updates inspection pane when tool result includes inspection payload", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    send(
      view.pid,
      {:workflow_step_completed, "Tool: write_file",
       %{result: %{inspection: "File: lib/demo.ex\n+ line"}}}
    )

    html = render(view)
    assert html =~ "Inspection"
    assert html =~ "File: lib/demo.ex"
    assert html =~ "+ line"
  end

  test "handles execution terminal success without duplicating final chat message", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    send(
      view.pid,
      {:execution_terminal, "succeeded",
       %{id: "exec-1", status: "succeeded", final_result: "done", task: "demo"}}
    )

    html = render(view)
    assert html =~ "Idle"
    refute html =~ "Execution finished: succeeded"
  end

  test "renders terminal failure message from execution event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    send(
      view.pid,
      {:execution_terminal, "failed",
       %{id: "exec-2", status: "failed", error_message: "boom", task: "demo"}}
    )

    html = render(view)
    assert html =~ "Failed"
    assert html =~ "boom"
  end

  test "renders panel debate progress events", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    send(
      view.pid,
      {:panel_debate_event,
       %{
         event: :persona_completed,
         phase: :revision,
         round: 2,
         discipline: "Economist",
         text: "The incentive structure changed after criticism."
       }}
    )

    html = render(view)
    assert html =~ "Economist completed revision round 2"
    assert html =~ "incentive structure"
  end

  test "handles dashboard slash session command without queueing execution", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    view
    |> form("#chat-form", %{"message" => "/session"})
    |> render_submit()

    html = render(view)
    assert html =~ "session_id=(new)"
    refute html =~ "Execution queued:"
  end

  test "handles dashboard slash history command without queueing execution", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    view
    |> form("#chat-form", %{"message" => "/history"})
    |> render_submit()

    html = render(view)
    assert html =~ "no user prompts yet"
    refute html =~ "Execution queued:"
  end

  test "handles dashboard slash skills command without queueing execution", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    view
    |> form("#chat-form", %{"message" => "/skills"})
    |> render_submit()

    html = render(view)
    assert html =~ "registered skills:"
    assert html =~ "example_skill"
    refute html =~ "Execution queued:"
  end

  test "switches right pane to settings tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    view
    |> element(~s(button[phx-click="switch_right_tab"][phx-value-tab="settings"]))
    |> render_click()

    html = render(view)
    assert html =~ "Dashboard Settings"
    assert html =~ "Left Pane Font"
    assert html =~ "Right Pane Font"
    assert html =~ "Message Density"
    assert html =~ "Chat Bubble Width"
  end

  test "renders durable approval queue in approvals tab and rejects request", %{conn: conn} do
    {:ok, execution} = Executions.enqueue("dashboard approval task", start_immediately: false)

    {:ok, request} =
      ApprovalQueue.create_request(%{
        execution_id: execution.id,
        session_id: execution.session_id,
        server_id: "internal",
        tool_name: "write_file",
        arguments: %{"path" => "tmp.txt"},
        risk_tier: "high"
      })

    {:ok, view, _html} = live(conn, "/agent")

    view
    |> element(~s(button[phx-click="switch_right_tab"][phx-value-tab="approvals"]))
    |> render_click()

    html = render(view)
    assert html =~ "Pending Approvals"
    assert html =~ "write_file"
    assert html =~ "tmp.txt"

    view
    |> element(~s(button[phx-click="reject_durable_approval"][phx-value-id="#{request.id}"]))
    |> render_click()

    html = render(view)
    assert html =~ "Approval rejected."
    assert html =~ "No pending approvals."
  end

  test "updates ui settings without leaving settings tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/agent")

    view
    |> element(~s(button[phx-click="switch_right_tab"][phx-value-tab="settings"]))
    |> render_click()

    view
    |> form("form[phx-change=\"update_ui_settings\"]", %{
      "ui" => %{"right_font_size" => "22"}
    })
    |> render_change()

    html = render(view)
    assert html =~ "Dashboard Settings"
    assert html =~ "22px"
  end
end
