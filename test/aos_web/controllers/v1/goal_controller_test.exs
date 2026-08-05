defmodule AOSWeb.V1.GoalControllerTest do
  use AOSWeb.ConnCase, async: false

  alias AOS.AgentOS.Goals

  test "creates and triggers a goal through the authenticated API", %{conn: conn} do
    conn =
      conn
      |> put_api_auth()
      |> put_req_header("accept", "application/json")

    conn =
      post(conn, "/api/v1/goals", %{
        name: "api-goal",
        objective: "Handle an incoming work item",
        goal_type: "one_shot"
      })

    assert %{"data" => %{"id" => goal_id, "status" => "active"}} = json_response(conn, 201)

    conn =
      conn
      |> recycle()
      |> put_api_auth()
      |> put_req_header("accept", "application/json")

    conn =
      post(conn, "/api/v1/goals/#{goal_id}/events", %{
        event_type: "work_item.created",
        payload: %{title: "API event"},
        start_immediately: false,
        wait: true
      })

    assert %{
             "data" => %{
               "event" => %{"event_type" => "work_item.created", "status" => "dispatched"},
               "run" => %{"status" => "queued"}
             }
           } = json_response(conn, 202)

    assert [%{event_type: "work_item.created"}] =
             Goals.list_events(goal_id)
  end
end
