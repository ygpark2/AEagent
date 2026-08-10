defmodule AOS.Repo.Migrations.AddDagEventIdempotencyIndex do
  use Ecto.Migration

  def change do
    create unique_index(:agent_dag_events, [:dag_run_id, :idempotency_key],
             name: :agent_dag_events_run_idempotency_index
           )
  end
end
