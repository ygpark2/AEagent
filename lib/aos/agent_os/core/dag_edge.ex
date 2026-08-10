defmodule AOS.AgentOS.Core.DAGEdge do
  @moduledoc "Persistent dependency edge in a DAG run."

  use AOS.Schema
  import Ecto.Changeset

  schema "agent_dag_edges" do
    field :dag_run_id, Ecto.UUID
    field :from_node_id, :string
    field :to_node_id, :string
    field :on, :string
    field :condition, :map, default: %{}
    field :metadata, :map, default: %{}

    timestamps()
  end

  def changeset(edge, attrs) do
    edge
    |> cast(attrs, [:dag_run_id, :from_node_id, :to_node_id, :on, :condition, :metadata])
    |> validate_required([:dag_run_id, :from_node_id, :to_node_id])
  end
end
