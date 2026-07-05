defmodule AOS.AgentOS.Core.MemoryStore do
  @moduledoc """
  Persistence operations for long-term memory cleanup.
  """

  import Ecto.Query

  alias AOS.AgentOS.Core.Execution
  alias AOS.AgentOS.ML.Embedder
  alias AOS.Repo

  def update_embedding(%Execution{} = execution) do
    embedding = Embedder.embed(execution.task)
    # Convert Nx tensor to binary for storage
    binary_vector = Nx.to_binary(embedding)

    execution
    |> Execution.changeset(%{embedding: binary_vector})
    |> Repo.update()
  end

  def search_similar_tasks(query_text, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    domain = Keyword.get(opts, :domain)

    # 1. Embed the query
    query_vector = Embedder.embed(query_text)

    # 2. Fetch candidates (successful executions with embeddings)
    query =
      from(e in Execution,
        where: e.success == true and not is_nil(e.embedding)
      )

    query = if domain, do: where(query, [e], e.domain == ^to_string(domain)), else: query

    candidates = Repo.all(query)

    # 3. Rank candidates by similarity in Elixir (RAG)
    candidates
    |> Enum.map(fn cand ->
      # MiniLM size
      cand_vector = Nx.from_binary(cand.embedding, :f32) |> Nx.reshape({384})
      score = Embedder.similarity(query_vector, cand_vector)
      {cand, score}
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(limit)
  end

  def delete_failed_executions_before(cutoff) do
    query =
      from e in "agent_executions",
        where: e.success == false and e.inserted_at < ^cutoff

    {count, _} = Repo.delete_all(query)
    count
  end

  def clear_success_logs_before(cutoff) do
    query =
      from e in "agent_executions",
        where: e.success == true and e.inserted_at < ^cutoff

    {count, _} = Repo.update_all(query, set: [execution_log: nil])
    count
  end

  def successful_count_for_domain(domain) do
    domain_str = to_string(domain)

    from(e in "agent_executions",
      where: e.domain == ^domain_str and e.success == true,
      select: count(e.id)
    )
    |> Repo.one()
  end

  def delete_oldest_successes_for_domain(_domain, count) when count <= 0, do: 0

  def delete_oldest_successes_for_domain(domain, count) do
    domain_str = to_string(domain)

    ids_to_delete =
      from(e in "agent_executions",
        where: e.domain == ^domain_str and e.success == true,
        order_by: [asc: e.inserted_at],
        limit: ^count,
        select: e.id
      )
      |> Repo.all()

    delete_query = from e in "agent_executions", where: e.id in ^ids_to_delete
    {deleted, _} = Repo.delete_all(delete_query)
    deleted
  end
end
