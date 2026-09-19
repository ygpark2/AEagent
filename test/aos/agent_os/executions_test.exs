defmodule AOS.AgentOS.ExecutionsTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Core.{Artifact, Engine, Execution, Graph, PolicyGate, Session}
  alias AOS.AgentOS.Executions

  alias AOS.Test.Support.Nodes.{
    CheckpointReporter,
    CheckpointWorker,
    HistoryProbeWorker,
    MockEvaluator,
    MockWorker
  }

  test "creates session-linked queued execution" do
    assert {:ok, execution} =
             Executions.enqueue("queued task",
               start_immediately: false,
               autonomy_level: "read_only"
             )

    assert execution.status == "queued"
    assert execution.session_id
    assert execution.autonomy_level == "read_only"

    session = Executions.get_session!(execution.session_id)
    assert session.task == "queued task"
    assert session.status == "active"
    assert session.autonomy_level == "read_only"
  end

  test "records artifacts for completed graph execution" do
    graph =
      Graph.new(:test_simple)
      |> Graph.add_node(:worker, MockWorker)
      |> Graph.add_node(:evaluator, MockEvaluator)
      |> Graph.set_initial(:worker)
      |> Graph.add_transition(:worker, :success, :evaluator)
      |> Graph.add_transition(:evaluator, :pass, nil)

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        title: "artifact session",
        task: "artifact session",
        status: "active"
      })
      |> Repo.insert()

    assert {:ok, final_context} =
             Engine.run(graph, %{
               task: "artifact task",
               session_id: session.id
             })

    execution = Executions.get_execution!(final_context.execution_id)
    artifacts = Executions.list_artifacts(execution.id)

    assert execution.status == "succeeded"
    assert length(artifacts) >= 3
    assert Enum.any?(artifacts, &(&1.kind == "step" and &1.label == "worker"))
    assert Enum.any?(artifacts, &(&1.kind == "execution_log"))
  end

  test "complete_execution emits terminal event to notify pid" do
    {:ok, execution} = Executions.enqueue("terminal event task", start_immediately: false)

    assert {:ok, _updated} =
             Executions.complete_execution(execution.id, %{
               task: "terminal event task",
               session_id: execution.session_id,
               notify: self(),
               result: "done",
               execution_history: []
             })

    assert_receive {:execution_terminal, "succeeded", completed_execution}
    assert completed_execution.id == execution.id
  end

  test "resume and retry create follow-up executions in same session" do
    {:ok, execution} =
      Executions.enqueue("resume task", start_immediately: false, autonomy_level: "supervised")

    {:ok, resumed} = Executions.resume_execution(execution.id, start_immediately: false)
    {:ok, retried} = Executions.retry_execution(execution.id, start_immediately: false)

    assert resumed.session_id == execution.session_id
    assert retried.session_id == execution.session_id
    assert resumed.id != execution.id
    assert retried.id != execution.id
    assert resumed.source_execution_id == execution.id
    assert retried.source_execution_id == execution.id
    assert resumed.trigger_kind == "resume"
    assert retried.trigger_kind == "retry"
  end

  test "replay returns execution bundle" do
    {:ok, execution} = Executions.enqueue("replay task", start_immediately: false)

    replay = Executions.replay_execution(execution.id)

    assert replay.execution.id == execution.id
    assert replay.session.id == execution.session_id
    assert Enum.map(replay.lineage, & &1.id) == [execution.id]
    assert replay.latest_checkpoint == nil
    assert replay.artifacts == []
    assert replay.tool_audits == []
  end

  test "replay exposes policy decision events" do
    {:ok, execution} = Executions.enqueue("replay policy task", start_immediately: false)

    context = %{
      execution_id: execution.id,
      session_id: execution.session_id,
      task: "safe task",
      execution_history: [],
      cost_usd: 0.0
    }

    assert {:ok, _updated_context} = PolicyGate.check(context, :worker)

    replay = Executions.replay_execution(execution.id)
    policy_events = Enum.filter(replay.events, &(&1.event_type == "policy.allowed"))

    assert length(policy_events) == 3
    assert Enum.all?(policy_events, &(&1.execution_id == execution.id))
  end

  test "session_history returns prior user and assistant turns when compression is disabled" do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        title: "history session",
        task: "history session",
        status: "active",
        autonomy_level: "supervised"
      })
      |> Repo.insert()

    {:ok, _first} =
      %Execution{}
      |> Execution.changeset(%{
        session_id: session.id,
        domain: "general",
        task: "first question",
        status: "succeeded",
        trigger_kind: "manual",
        autonomy_level: "supervised",
        success: true,
        final_result: "first answer"
      })
      |> Repo.insert()

    {:ok, _second} =
      %Execution{}
      |> Execution.changeset(%{
        session_id: session.id,
        domain: "general",
        task: "second question",
        status: "failed",
        trigger_kind: "manual",
        autonomy_level: "supervised",
        success: false,
        error_message: "second error"
      })
      |> Repo.insert()

    assert Executions.session_history(session.id, compress: false) == [
             {"user", "first question"},
             {"assistant", "first answer"},
             {"user", "second question"},
             {"assistant", "Execution failed: second error"}
           ]
  end

  test "session_history compresses older turns into a system summary" do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        title: "compressed history session",
        task: "compressed history session",
        status: "active",
        autonomy_level: "supervised"
      })
      |> Repo.insert()

    for index <- 1..7 do
      {:ok, _execution} =
        %Execution{}
        |> Execution.changeset(%{
          session_id: session.id,
          domain: "general",
          task: "question #{index}",
          status: "succeeded",
          trigger_kind: "manual",
          autonomy_level: "supervised",
          success: true,
          final_result: "answer #{index}"
        })
        |> Repo.insert()
    end

    assert [
             {"system", summary},
             {"user", "question 2"},
             {"assistant", "answer 2"},
             {"user", "question 3"},
             {"assistant", "answer 3"},
             {"user", "question 4"},
             {"assistant", "answer 4"},
             {"user", "question 5"},
             {"assistant", "answer 5"},
             {"user", "question 6"},
             {"assistant", "answer 6"},
             {"user", "question 7"},
             {"assistant", "answer 7"}
           ] =
             Executions.session_history(session.id)

    assert summary =~ "Previous conversation summary"
    assert summary =~ "question 1"
  end

  test "run_existing_execution falls back to session history when no explicit history is provided" do
    graph =
      Graph.new(:history_probe)
      |> Graph.add_node(:worker, HistoryProbeWorker)
      |> Graph.set_initial(:worker)
      |> Graph.add_transition(:worker, :success, nil)

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        title: "history probe session",
        task: "history probe session",
        status: "active",
        autonomy_level: "supervised"
      })
      |> Repo.insert()

    {:ok, _previous} =
      %Execution{}
      |> Execution.changeset(%{
        session_id: session.id,
        domain: "general",
        task: "earlier prompt",
        status: "succeeded",
        trigger_kind: "manual",
        autonomy_level: "supervised",
        success: true,
        final_result: "earlier reply"
      })
      |> Repo.insert()

    {:ok, queued} =
      Executions.enqueue("new prompt",
        start_immediately: false,
        session_id: session.id,
        autonomy_level: "supervised"
      )

    assert {:ok, final_context} =
             Executions.run_existing_execution(queued.id, queued.task,
               session_id: session.id,
               autonomy_level: "supervised",
               graph_builder: fn _task, _opts -> graph end
             )

    assert final_context.captured_history == [
             {"user", "earlier prompt"},
             {"assistant", "earlier reply"}
           ]
  end

  test "resume seeds new execution from latest checkpoint context" do
    {:ok, execution} = Executions.enqueue("checkpoint task", start_immediately: false)

    {:ok, _artifact} =
      Repo.insert(
        Artifact.changeset(%Artifact{}, %{
          execution_id: execution.id,
          session_id: execution.session_id,
          kind: "checkpoint",
          label: "checkpoint:test",
          payload: %{
            context: %{
              "feedback" => "resume from checkpoint",
              "history" => [%{"role" => "user", "content" => "prior context"}],
              "result" => "partial result"
            }
          },
          position: 1
        })
      )

    {:ok, resumed} = Executions.resume_execution(execution.id, start_immediately: false)
    replay = Executions.replay_execution(resumed.id)

    assert resumed.source_execution_id == execution.id
    assert replay.execution.trigger_kind == "resume"
    assert Enum.map(replay.lineage, & &1.id) == [execution.id, resumed.id]
  end

  test "resume can target a specific checkpoint artifact" do
    {:ok, execution} = Executions.enqueue("checkpoint selection task", start_immediately: false)

    {:ok, older_checkpoint} =
      Repo.insert(
        Artifact.changeset(%Artifact{}, %{
          execution_id: execution.id,
          session_id: execution.session_id,
          kind: "checkpoint",
          label: "checkpoint:worker",
          payload: %{
            "node_id" => "worker",
            "next_node_id" => "evaluator",
            "context" => %{"result" => "older"}
          },
          position: 1
        })
      )

    {:ok, _newer_checkpoint} =
      Repo.insert(
        Artifact.changeset(%Artifact{}, %{
          execution_id: execution.id,
          session_id: execution.session_id,
          kind: "checkpoint",
          label: "checkpoint:evaluator",
          payload: %{
            "node_id" => "evaluator",
            "next_node_id" => nil,
            "context" => %{"result" => "newer"}
          },
          position: 2
        })
      )

    {:ok, resumed} =
      Executions.resume_execution(execution.id,
        start_immediately: false,
        checkpoint_id: older_checkpoint.id
      )

    assert {:ok, resumed_context} =
             Executions.run_existing_execution(resumed.id, resumed.task,
               session_id: resumed.session_id,
               autonomy_level: resumed.autonomy_level,
               graph_builder: fn _task, _opts ->
                 Graph.new(:checkpoint_target)
                 |> Graph.add_node(:evaluator, CheckpointReporter)
                 |> Graph.set_initial(:evaluator)
                 |> Graph.add_transition(:evaluator, :success, nil)
               end
             )

    assert resumed_context.reporter_visits == 1
    assert resumed_context.resume_from_node == :evaluator
    assert resumed_context.checkpoint_artifact_id == older_checkpoint.id
  end

  test "resume can rerun the checkpoint node" do
    graph =
      Graph.new(:checkpoint_restart)
      |> Graph.add_node(:worker, CheckpointWorker)
      |> Graph.add_node(:reporter, CheckpointReporter)
      |> Graph.set_initial(:worker)
      |> Graph.add_transition(:worker, :success, :reporter)
      |> Graph.add_transition(:reporter, :success, nil)

    {:ok, execution} = Executions.enqueue("checkpoint restart task", start_immediately: false)

    {:ok, checkpoint} =
      Repo.insert(
        Artifact.changeset(%Artifact{}, %{
          execution_id: execution.id,
          session_id: execution.session_id,
          kind: "checkpoint",
          label: "checkpoint:worker",
          payload: %{
            "node_id" => "worker",
            "next_node_id" => "reporter",
            "context" => %{"result" => "older"}
          },
          position: 1
        })
      )

    {:ok, resumed} =
      Executions.resume_execution(execution.id,
        start_immediately: false,
        checkpoint_id: checkpoint.id,
        resume_mode: "checkpoint_node"
      )

    assert {:ok, resumed_context} =
             Executions.run_existing_execution(resumed.id, resumed.task,
               session_id: resumed.session_id,
               autonomy_level: resumed.autonomy_level,
               graph_builder: fn _task, _opts -> graph end
             )

    assert resumed_context.worker_visits == 1
    assert resumed_context.reporter_visits == 1
    assert resumed_context.resume_from_node == :worker
    assert resumed_context.resume_mode == "checkpoint_node"
  end

  test "resume continues from checkpoint next node" do
    graph =
      Graph.new(:checkpoint_resume)
      |> Graph.add_node(:worker, CheckpointWorker)
      |> Graph.add_node(:reporter, CheckpointReporter)
      |> Graph.set_initial(:worker)
      |> Graph.add_transition(:worker, :success, :reporter)
      |> Graph.add_transition(:reporter, :success, nil)

    graph_builder = fn _task, _opts -> graph end

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        title: "checkpoint resume session",
        task: "checkpoint resume session",
        status: "active",
        autonomy_level: "supervised"
      })
      |> Repo.insert()

    {:ok, source_execution} =
      Executions.enqueue("checkpoint flow",
        start_immediately: false,
        session_id: session.id,
        autonomy_level: "supervised"
      )

    {:ok, _checkpoint} =
      Repo.insert(
        Artifact.changeset(%Artifact{}, %{
          execution_id: source_execution.id,
          session_id: session.id,
          kind: "checkpoint",
          label: "checkpoint:worker",
          payload: %{
            "node_id" => "worker",
            "next_node_id" => "reporter",
            "context" => %{
              "result" => "worker-1",
              "history" => [%{"role" => "user", "content" => "checkpoint"}]
            }
          },
          position: 1
        })
      )

    {:ok, resumed} =
      Executions.enqueue("checkpoint flow",
        start_immediately: false,
        session_id: session.id,
        source_execution_id: source_execution.id,
        trigger_kind: "resume",
        autonomy_level: "supervised"
      )

    assert {:ok, resumed_context} =
             Executions.run_existing_execution(resumed.id, resumed.task,
               session_id: resumed.session_id,
               autonomy_level: resumed.autonomy_level,
               graph_builder: graph_builder
             )

    assert resumed_context.reporter_visits == 1
    assert Map.get(resumed_context, :worker_visits, 0) == 0
  end

  test "completion dispatches slack response through configured dispatcher" do
    previous = :application.get_env(:aos, :slack_response_dispatcher, nil)
    previous_pid = :application.get_env(:aos, :slack_test_pid, nil)

    Application.put_env(
      :aos,
      :slack_response_dispatcher,
      AOS.Test.Support.SlackResponseDispatcher
    )

    Application.put_env(:aos, :slack_test_pid, self())

    on_exit(fn ->
      Application.put_env(:aos, :slack_response_dispatcher, previous)
      Application.put_env(:aos, :slack_test_pid, previous_pid)
    end)

    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        title: "slack session",
        task: "slack session",
        status: "active",
        autonomy_level: "supervised",
        metadata: %{"slack" => %{"response_url" => "https://hooks.slack.test/response"}}
      })
      |> Repo.insert()

    session_id = session.id

    {:ok, execution} =
      Executions.enqueue("dispatch task",
        start_immediately: false,
        session_id: session.id,
        trigger_kind: "slack"
      )

    assert {:ok, _updated} =
             Executions.complete_execution(execution.id, %{
               task: "dispatch task",
               session_id: session.id,
               result: "done",
               execution_history: []
             })

    assert_receive {:slack_dispatch, ^session_id, execution_id, "succeeded", slack_metadata}
    assert execution_id == execution.id
    assert slack_metadata["response_url"] == "https://hooks.slack.test/response"
  end
end
