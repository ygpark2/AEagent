defmodule AOS.AgentOS.Execution.CheckpointServiceTest do
  use AOS.DataCase, async: true

  alias AOS.AgentOS.Core.{Artifact, Session}
  alias AOS.AgentOS.Execution.{CheckpointPayload, CheckpointService, ResumeContext}
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.Orchestration.DAGEngine
  alias AOS.Repo

  describe "ResumeContext" do
    test "round-trip preserves :artifacts, :node_outputs, and :skills while omitting nil fields" do
      context = %{
        artifacts: [
          %{"id" => "art_1", "kind" => "step", "payload" => %{"text" => "hello"}}
        ],
        node_outputs: %{
          "worker" => %{"result" => "success", "score" => 0.95}
        },
        skills: ["code_analysis", "web_search"]
      }

      resume_ctx = ResumeContext.from_map(context)
      assert is_struct(resume_ctx, ResumeContext)
      assert length(resume_ctx.artifacts) == 1
      assert resume_ctx.skills == ["code_analysis", "web_search"]

      restored_map = ResumeContext.to_map(resume_ctx)

      # Verify atom keys match pattern matching
      assert %{artifacts: [art], node_outputs: outputs, skills: skills} = restored_map
      assert art[:id] == "art_1" or art["id"] == "art_1"
      assert skills == ["code_analysis", "web_search"]
      assert outputs["worker"][:result] == "success" or outputs[:worker][:result] == "success"

      # Verify fallback string keys are also retained
      assert Map.has_key?(restored_map, "artifacts")
      assert Map.has_key?(restored_map, "node_outputs")

      # Verify nil fields are cleanly omitted
      refute Map.has_key?(restored_map, :feedback)
      refute Map.has_key?(restored_map, "feedback")
      refute Map.has_key?(restored_map, :result)
      refute Map.has_key?(restored_map, "result")
      refute Map.has_key?(restored_map, :goal_id)
      refute Map.has_key?(restored_map, "goal_id")
    end

    test "preserves custom domain fields in context without dropping" do
      stored_json = %{
        "artifacts" => [%{"id" => "art_2", "kind" => "evidence"}],
        "node_outputs" => %{"evaluator" => %{"verdict" => "passed"}},
        "my_custom_metric" => 42,
        "custom_domain_flag" => true
      }

      restored = stored_json |> ResumeContext.from_map() |> ResumeContext.to_map()

      assert %{artifacts: _, node_outputs: _} = restored
      assert restored["my_custom_metric"] == 42
      assert restored["custom_domain_flag"] == true

      # If atom exists in VM, atom key is also available
      if is_atom(:my_custom_metric) do
        assert restored[:my_custom_metric] == 42
      end
    end
  end

  describe "DAGEngine.restore_context/1 and persistable_context/1" do
    test "restores context with artifacts and node_outputs to pattern-matchable atom keys" do
      stored_json = %{
        "artifacts" => [
          %{"id" => "art_100", "kind" => "file", "payload" => %{"path" => "/tmp/test.txt"}}
        ],
        "node_outputs" => %{
          "start" => %{"result" => "initialized", "count" => 5}
        },
        "inputs" => %{
          "start" => %{"result" => "initialized"}
        },
        "execution_history" => [
          %{"node_id" => "start", "outcome" => "success", "feedback" => "good"}
        ],
        "domain_data" => %{"nested_key" => "nested_value"}
      }

      restored = DAGEngine.restore_context(stored_json)

      # Pattern match on atom keys
      assert %{
               artifacts: [artifact],
               node_outputs: node_outputs,
               inputs: inputs,
               execution_history: [history_step]
             } = restored

      # Deep-atomized artifacts
      assert artifact.id == "art_100"
      assert artifact.kind == "file"
      assert artifact.payload.path == "/tmp/test.txt"

      # Deep-atomized node_outputs
      assert node_outputs[:start][:result] == "initialized"
      assert node_outputs["start"]["result"] == "initialized"
      assert node_outputs[:start][:count] == 5

      # Inputs and history
      assert inputs[:start][:result] == "initialized"
      assert history_step.node_id == "start"
      assert history_step.outcome == "success"

      # Fallbacks retain string keys as well
      assert Map.has_key?(restored, "artifacts")
      assert Map.has_key?(restored, "node_outputs")
      assert Map.has_key?(restored, "domain_data")
      assert restored["domain_data"]["nested_key"] == "nested_value"
    end

    test "round-trip serialization with persistable_context and restore_context" do
      context = %{
        artifacts: [%{id: "art_3", kind: "diff", payload: %{lines: 10}}],
        node_outputs: %{worker: %{result: "built", status: "ok"}},
        intermediate_var: "keep_me"
      }

      serialized = DAGEngine.persistable_context(context)

      # Verify all keys in serialized JSON map are strings
      assert is_map(serialized)
      assert Enum.all?(Map.keys(serialized), &is_binary/1)
      assert is_list(serialized["artifacts"])
      assert is_map(serialized["node_outputs"])

      restored = DAGEngine.restore_context(serialized)

      assert %{artifacts: [art], node_outputs: outputs} = restored
      assert art.id == "art_3"
      assert art.kind == "diff"
      assert outputs[:worker][:result] == "built"
      assert restored[:intermediate_var] == "keep_me" or restored["intermediate_var"] == "keep_me"
    end
  end

  describe "CheckpointService database round-trip" do
    test "checkpoint_context restores artifacts, node_outputs, and custom keys from DB" do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          title: "checkpoint session",
          task: "checkpoint persistence test",
          status: "active"
        })
        |> Repo.insert()

      {:ok, execution, _context} =
        Executions.ensure_execution(%{
          task: "checkpoint persistence test",
          session_id: session.id
        })

      # Build checkpoint payload with artifacts, node_outputs, and custom domain fields
      context = %{
        artifacts: [
          %{"id" => "db_art_1", "kind" => "report", "payload" => %{"summary" => "passed"}}
        ],
        node_outputs: %{
          "fetcher" => %{"result" => "data_fetched", "items_count" => 3}
        },
        custom_domain_key: "preserved_across_db"
      }

      payload = CheckpointPayload.build(context, "fetcher", "analyzer")

      # Insert checkpoint artifact in DB
      {:ok, artifact} =
        %Artifact{}
        |> Artifact.changeset(%{
          execution_id: execution.id,
          session_id: execution.session_id,
          kind: "checkpoint",
          label: "checkpoint:fetcher",
          payload: payload,
          position: 1
        })
        |> Repo.insert()

      # Restore via CheckpointService.checkpoint_context
      restored_context = CheckpointService.checkpoint_context(execution.id, artifact.id)

      assert is_map(restored_context)
      assert %{artifacts: [art], node_outputs: node_outputs} = restored_context
      assert art[:id] == "db_art_1" or art["id"] == "db_art_1"

      assert node_outputs["fetcher"][:result] == "data_fetched" or
               node_outputs[:fetcher][:result] == "data_fetched"

      assert restored_context[:custom_domain_key] == "preserved_across_db" or
               restored_context["custom_domain_key"] == "preserved_across_db"

      assert to_string(restored_context[:resume_from_node]) == "analyzer"
    end

    test "initial_context_for_run restores resume seed and merges initial_context" do
      {:ok, session} =
        %Session{}
        |> Session.changeset(%{
          title: "seed session",
          task: "seed persistence test",
          status: "active"
        })
        |> Repo.insert()

      {:ok, execution, _context} =
        Executions.ensure_execution(%{
          task: "seed persistence test",
          session_id: session.id
        })

      # Persist resume seed artifact
      seed_context = %{
        artifacts: [%{"id" => "seed_art", "kind" => "seed"}],
        node_outputs: %{"seed_node" => %{"result" => "seed_result"}},
        seed_field: "from_seed"
      }

      {:ok, _seed_artifact} =
        %Artifact{}
        |> Artifact.changeset(%{
          execution_id: execution.id,
          session_id: execution.session_id,
          kind: "resume_seed",
          label: "resume_seed",
          payload: %{"context" => seed_context},
          position: 0
        })
        |> Repo.insert()

      initial_override = %{
        node_outputs: %{"override_node" => %{"result" => "override_result"}},
        new_param: "extra_val"
      }

      restored_struct = CheckpointService.initial_context_for_run(execution.id, initial_override)
      runtime_map = CheckpointService.to_runtime_map(restored_struct)

      assert %{artifacts: [art], node_outputs: outputs} = runtime_map
      assert art[:id] == "seed_art" or art["id"] == "seed_art"

      assert outputs["seed_node"][:result] == "seed_result" or
               outputs[:seed_node][:result] == "seed_result"

      assert outputs["override_node"][:result] == "override_result" or
               outputs[:override_node][:result] == "override_result"

      assert runtime_map[:seed_field] == "from_seed" or runtime_map["seed_field"] == "from_seed"
      assert runtime_map[:new_param] == "extra_val" or runtime_map["new_param"] == "extra_val"
    end
  end
end
