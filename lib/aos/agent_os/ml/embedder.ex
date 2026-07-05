defmodule AOS.AgentOS.ML.Embedder do
  @moduledoc """
  Bumblebee-based local embedding generator.
  Uses a pre-trained model to convert text into vector embeddings.
  """
  require Logger

  @model_name "sentence-transformers/all-MiniLM-L6-v2"

  def start_link do
    # Warm up the model in a separate process or via FLAME if needed.
    # For now, we'll load it on demand or during app start.
    {:ok, self()}
  end

  def serving do
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_name})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_name})

    Bumblebee.Text.text_embedding(model_info, tokenizer,
      compile: [batch_size: 1],
      defn_options: [compiler: EXLA]
    )
  end

  def embed(text) when is_binary(text) do
    # Using a cached serving would be better in production
    Nx.Serving.run(serving(), text)
    |> Map.get(:embedding)
  end

  @doc """
  Calculates cosine similarity between two vectors.
  """
  def similarity(vec1, vec2) do
    # Cosine Similarity = (A . B) / (||A|| * ||B||)
    dot_product = Nx.dot(vec1, vec2)
    norm1 = Nx.LinAlg.norm(vec1)
    norm2 = Nx.LinAlg.norm(vec2)

    Nx.divide(dot_product, Nx.multiply(norm1, norm2))
    |> Nx.to_number()
  end
end
