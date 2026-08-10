defmodule AOS.AgentOS.Core.HarnessTrace do
  @moduledoc "Normalized trace record emitted by the agent harness."

  use AOS.Schema
  import Ecto.Changeset

  schema "agent_harness_traces" do
    field :episode_id, Ecto.UUID
    field :execution_id, Ecto.UUID
    field :trace_type, :string
    field :phase, :string
    field :payload, :map, default: %{}
    field :sequence, :integer, default: 0
    field :source, :string, default: "harness"
    field :idempotency_key, :string

    timestamps(updated_at: false)
  end

  def changeset(trace, attrs) do
    trace
    |> cast(attrs, [
      :episode_id,
      :execution_id,
      :trace_type,
      :phase,
      :payload,
      :sequence,
      :source,
      :idempotency_key
    ])
    |> validate_required([:episode_id, :execution_id, :trace_type, :phase, :payload, :sequence])
    |> unique_constraint(:idempotency_key,
      name: :agent_harness_traces_episode_id_idempotency_key_index
    )
  end
end
