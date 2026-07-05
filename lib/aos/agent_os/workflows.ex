defmodule AOS.AgentOS.Workflows do
  @moduledoc """
  Public API for durable workflow definitions.
  """

  import Ecto.Query

  alias AOS.AgentOS.Core.Workflow
  alias AOS.AgentOS.Executions
  alias AOS.Repo

  @default_limit 50

  def create_workflow(attrs) do
    %Workflow{}
    |> Workflow.changeset(attrs)
    |> Repo.insert()
  end

  def update_workflow(id, attrs) do
    id
    |> get_workflow!()
    |> Workflow.changeset(attrs)
    |> Repo.update()
  end

  def get_workflow(id), do: Repo.get(Workflow, id)
  def get_workflow!(id), do: Repo.get!(Workflow, id)

  def get_workflow_by_name(name) when is_binary(name),
    do: Repo.get_by(Workflow, name: name)

  def list_workflows(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    status = Keyword.get(opts, :status)

    Workflow
    |> maybe_filter_status(status)
    |> order_by([w], desc: w.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def enqueue_workflow(id_or_name, task, opts \\ []) when is_binary(task) do
    with {:ok, workflow} <- resolve_workflow(id_or_name) do
      execution_opts =
        opts
        |> Keyword.put(:workflow_id, workflow.id)
        |> Keyword.put_new(:initial_context, workflow_initial_context(workflow, opts))

      Executions.enqueue(task, execution_opts)
    end
  end

  def serialize(%Workflow{} = workflow) do
    %{
      id: workflow.id,
      name: workflow.name,
      description: workflow.description,
      status: workflow.status,
      trigger: workflow.trigger,
      graph: workflow.graph,
      required_tools: workflow.required_tools,
      policy_profile: workflow.policy_profile,
      timeout_ms: workflow.timeout_ms,
      retry_policy: workflow.retry_policy,
      approval_policy: workflow.approval_policy,
      state_retention_policy: workflow.state_retention_policy,
      metadata: workflow.metadata,
      inserted_at: workflow.inserted_at,
      updated_at: workflow.updated_at
    }
  end

  defp resolve_workflow(id_or_name) do
    case get_workflow_by_id_or_name(id_or_name) do
      %Workflow{status: "active"} = workflow -> {:ok, workflow}
      %Workflow{} = workflow -> {:error, "workflow #{workflow.name} is #{workflow.status}"}
      nil -> {:error, "workflow not found: #{id_or_name}"}
    end
  end

  defp get_workflow_by_id_or_name(id_or_name) do
    case Ecto.UUID.cast(id_or_name) do
      {:ok, uuid} -> get_workflow(uuid) || get_workflow_by_name(id_or_name)
      :error -> get_workflow_by_name(id_or_name)
    end
  end

  defp workflow_initial_context(workflow, opts) do
    opts
    |> Keyword.get(:initial_context, %{})
    |> Map.merge(%{
      workflow_id: workflow.id,
      workflow_name: workflow.name,
      workflow_policy_profile: workflow.policy_profile,
      workflow_approval_policy: workflow.approval_policy
    })
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [w], w.status == ^status)
end
