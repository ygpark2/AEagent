defmodule AOS.AgentOS.Core.Workflow do
  @moduledoc """
  Durable workflow definition for long-running agent orchestration.
  """
  use AOS.Schema
  import Ecto.Changeset

  @statuses ~w(active paused archived)

  schema "agent_workflows" do
    field :name, :string
    field :description, :string
    field :status, :string, default: "active"
    field :trigger, :map, default: %{}
    field :graph, :map, default: %{}
    field :required_tools, {:array, :string}, default: []
    field :policy_profile, :map, default: %{}
    field :timeout_ms, :integer
    field :retry_policy, :map, default: %{}
    field :approval_policy, :map, default: %{}
    field :state_retention_policy, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(workflow, attrs) do
    workflow
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :trigger,
      :graph,
      :required_tools,
      :policy_profile,
      :timeout_ms,
      :retry_policy,
      :approval_policy,
      :state_retention_policy,
      :metadata
    ])
    |> validate_required([:name, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:timeout_ms, greater_than: 0)
    |> unique_constraint(:name)
  end
end
