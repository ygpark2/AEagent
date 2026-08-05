defmodule AOSWeb.V1.GoalWebhookControllerTest do
  use AOSWeb.ConnCase, async: false

  alias AOS.AgentOS.Goals

  setup %{conn: conn} do
    {:ok,
     conn:
       conn
       |> put_req_header("accept", "application/json")
       |> put_req_header(
         "x-aos-webhook-secret",
         :application.get_env(:aos, :webhook_shared_secret, nil)
       )}
  end

  test "accepts a generic goal event through the shared-secret webhook", %{conn: conn} do
    {:ok, goal} = Goals.create_goal(%{name: "webhook-goal", objective: "Process webhook work"})

    conn =
      post(conn, "/api/v1/webhooks/goals/#{goal.id}/events", %{
        event_type: "work.created",
        payload: %{subject: "new work"},
        idempotency_key: "delivery-1",
        start_immediately: false,
        wait: true
      })

    assert %{"data" => %{"channel" => "goal_webhook", "event" => event}} =
             json_response(conn, 202)

    assert event["event_type"] == "work.created"
    assert event["status"] == "dispatched"
  end

  test "rejects a generic goal event without the shared secret", %{conn: conn} do
    {:ok, goal} = Goals.create_goal(%{name: "protected-goal", objective: "Protect work"})

    conn =
      conn
      |> recycle()
      |> put_req_header("accept", "application/json")
      |> put_req_header("x-aos-webhook-secret", "wrong")

    conn = post(conn, "/api/v1/webhooks/goals/#{goal.id}/events", %{event_type: "work.created"})
    assert json_response(conn, 422)
  end
end
