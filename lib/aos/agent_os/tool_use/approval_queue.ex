defmodule AOS.AgentOS.ToolUse.ApprovalQueue do
  @moduledoc """
  Durable queue for human-in-the-loop tool approvals.
  """

  import Ecto.Query

  alias AOS.AgentOS.Execution.EventStore
  alias AOS.AgentOS.Executions
  alias AOS.AgentOS.ToolUse.ApprovalRequest
  alias AOS.Repo

  @default_timeout_seconds 300

  def create_request(attrs) do
    attrs =
      attrs
      |> Map.put_new(:status, "pending")
      |> Map.put_new(:expires_at, DateTime.add(DateTime.utc_now(), @default_timeout_seconds))

    %ApprovalRequest{}
    |> ApprovalRequest.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, request} -> append_event(request)
      _ -> :ok
    end)
  end

  def get_request(id), do: Repo.get(ApprovalRequest, id)
  def get_request!(id), do: Repo.get!(ApprovalRequest, id)

  def list_pending(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    list_requests(status: "pending", limit: limit)
  end

  def list_requests(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    status = Keyword.get(opts, :status)

    ApprovalRequest
    |> maybe_filter_status(status)
    |> order_by([r], asc: r.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def find_approved_tool_request(server_id, tool_name, arguments, execution_ids) do
    execution_ids = execution_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    ApprovalRequest
    |> where([r], r.status == "approved")
    |> where([r], r.server_id == ^server_id and r.tool_name == ^tool_name)
    |> where([r], r.execution_id in ^execution_ids)
    |> order_by([r], desc: r.decided_at, desc: r.inserted_at)
    |> Repo.all()
    |> Enum.find(&(&1.arguments == arguments))
  end

  def approve(id, attrs \\ %{}) do
    with {:ok, request} <- decide(id, "approved", attrs) do
      maybe_resume_execution(request, attrs)
      {:ok, request}
    end
  end

  def reject(id, attrs \\ %{}) do
    with {:ok, request} <- decide(id, "rejected", attrs) do
      maybe_handle_rejection(request, attrs)
      {:ok, request}
    end
  end

  def cancel_pending_for_execution(execution_id, reason \\ "Execution timed out") do
    from(r in ApprovalRequest,
      where: r.execution_id == ^execution_id and r.status == "pending"
    )
    |> Repo.all()
    |> Enum.map(fn req ->
      reject(req.id, %{decision_reason: reason})
    end)
  end

  def serialize(%ApprovalRequest{} = request) do
    %{
      id: request.id,
      execution_id: request.execution_id,
      session_id: request.session_id,
      workflow_id: request.workflow_id,
      server_id: request.server_id,
      tool_name: request.tool_name,
      arguments: request.arguments,
      risk_tier: request.risk_tier,
      status: request.status,
      requested_by: request.requested_by,
      decided_by: request.decided_by,
      decision_reason: request.decision_reason,
      expires_at: request.expires_at,
      decided_at: request.decided_at,
      inserted_at: request.inserted_at,
      updated_at: request.updated_at
    }
  end

  defp decide(id, status, attrs) when status in ~w(approved rejected) do
    case get_request(id) do
      nil ->
        {:error, :not_found}

      %ApprovalRequest{status: "pending"} = request ->
        request
        |> ApprovalRequest.changeset(
          Map.merge(attrs, %{status: status, decided_at: DateTime.utc_now()})
        )
        |> Repo.update()
        |> tap(fn
          {:ok, updated} -> append_decision_event(updated)
          _ -> :ok
        end)

      %ApprovalRequest{} ->
        {:error, "approval request already decided"}
    end
  end

  defp maybe_resume_execution(%ApprovalRequest{execution_id: nil}, _attrs), do: :ok

  defp maybe_resume_execution(%ApprovalRequest{} = request, attrs) do
    resume? = Map.get(attrs, :resume, Map.get(attrs, "resume", true))

    if resume? do
      case Executions.get_execution(request.execution_id) do
        nil ->
          :ok

        execution when execution.status in ~w(suspended blocked) ->
          async? = Map.get(attrs, :async, true)

          Executions.resume_execution(execution.id,
            async: async?,
            approval_request: request
          )

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_handle_rejection(%ApprovalRequest{execution_id: nil}, _attrs), do: :ok

  defp maybe_handle_rejection(%ApprovalRequest{} = request, _attrs) do
    alias AOS.AgentOS.Orchestration.DAGStore

    case Executions.get_execution(request.execution_id) do
      nil ->
        :ok

      execution ->
        run = DAGStore.get_run_by_execution(execution.id)
        cancel_suspended_dag_run(run)
        fail_suspended_execution(execution)
    end
  end

  defp cancel_suspended_dag_run(%{status: "suspended"} = run) do
    alias AOS.AgentOS.Orchestration.{DAGStore, EventProtocol, MetaCoordinator}

    DAGStore.update_run(run.id, %{
      status: "cancelled",
      finished_at: DateTime.utc_now(),
      error_message: "approval_rejected"
    })

    run.id
    |> DAGStore.list_nodes()
    |> Enum.filter(&(&1.status in ~w(suspended pending ready)))
    |> Enum.each(fn node ->
      DAGStore.update_node(node, %{
        status: "cancelled",
        outcome: "rejected",
        finished_at: DateTime.utc_now()
      })
    end)

    MetaCoordinator.emit(
      EventProtocol.new("orchestration.cancelled", %{
        run_id: run.id,
        execution_id: run.execution_id,
        parent_run_id: run.parent_run_id,
        orchestrator_id: run.orchestrator_id,
        idempotency_key: "#{run.id}:orchestration.cancelled:rejection",
        payload: %{reason: "approval_rejected"}
      })
    )
  end

  defp cancel_suspended_dag_run(_run), do: :ok

  defp fail_suspended_execution(%{status: status} = execution)
       when status in ~w(suspended blocked) do
    Executions.fail_execution(
      execution.id,
      %{
        task: execution.task,
        domain: execution.domain,
        session_id: execution.session_id,
        execution_history: []
      },
      :approval_rejected
    )
  end

  defp fail_suspended_execution(_execution), do: :ok

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [r], r.status == ^status)

  defp append_event(%ApprovalRequest{execution_id: nil}), do: :ok

  defp append_event(%ApprovalRequest{} = request) do
    EventStore.append_event(%{
      execution_id: request.execution_id,
      session_id: request.session_id,
      workflow_id: request.workflow_id,
      event_type: "approval.requested",
      source: "approval_queue",
      payload: %{
        "approval_request_id" => request.id,
        "server_id" => request.server_id,
        "tool_name" => request.tool_name,
        "risk_tier" => request.risk_tier
      }
    })
  end

  defp append_decision_event(%ApprovalRequest{execution_id: nil}), do: :ok

  defp append_decision_event(%ApprovalRequest{} = request) do
    EventStore.append_event(%{
      execution_id: request.execution_id,
      session_id: request.session_id,
      workflow_id: request.workflow_id,
      event_type: "approval.#{request.status}",
      source: "approval_queue",
      payload: %{
        "approval_request_id" => request.id,
        "server_id" => request.server_id,
        "tool_name" => request.tool_name,
        "decided_by" => request.decided_by,
        "decision_reason" => request.decision_reason
      }
    })
  end
end
