defmodule AOS.AgentOS.LLM.Client do
  @moduledoc """
  Selects an LLM provider and applies shared retry policy.
  """

  require Logger

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.LLM.HTTPError
  alias AOS.AgentOS.LLM.Provider.{Local, OpenAI}

  @max_retries 3
  @base_sleep_ms 1000

  def call_raw(prompt, history, opts) do
    do_call_raw(prompt, history, opts, Keyword.get(opts, :retry_count, 0))
  end

  def list_models do
    provider().list_models()
  end

  defp do_call_raw(prompt, history, opts, retry_count) do
    current_model = Keyword.get(opts, :model) || Config.agent_model()

    case provider().call(prompt, history, opts) do
      {:ok, result} ->
        {:ok, result}

      {:error, %HTTPError{retryable: true} = error} ->
        retry_http(prompt, history, opts, current_model, retry_count, error)

      {:error, :empty_response} ->
        Logger.warning("LLM returned empty response. Retrying with different model...")
        handle_retry_raw(prompt, history, opts, current_model, retry_count)

      {:error, {:retryable_http_error, status}} ->
        Logger.warning("LLM Error #{status}: Attempting recovery...")
        handle_retry_raw(prompt, history, opts, current_model, retry_count)

      {:error, {:transport_error, _reason}} ->
        handle_retry_raw(prompt, history, opts, current_model, retry_count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_http(prompt, history, opts, model, count, error) do
    limit = if error.code == "free_rate_limited", do: 1, else: @max_retries
    wait = error.retry_after_ms || round(@base_sleep_ms * :math.pow(2, count))

    if count < limit and wait <= 60_000 do
      Process.sleep(wait)
      model = if Config.cliproxy_api?(), do: select_fallback_model(model), else: model
      opts = opts |> Keyword.put(:model, model) |> Keyword.put(:retry_count, count + 1)
      do_call_raw(prompt, history, opts, count + 1)
    else
      {:error, error}
    end
  end

  defp handle_retry_raw(prompt, history, opts, current_model, retry_count) do
    if retry_count < @max_retries do
      new_model =
        if Config.cliproxy_api?(),
          do: select_fallback_model(current_model),
          else: current_model

      wait_time = (@base_sleep_ms * :math.pow(2, retry_count)) |> round()

      Logger.info(
        "Retrying (#{retry_count + 1}/#{@max_retries}) with model #{new_model} in #{wait_time}ms..."
      )

      Process.sleep(wait_time)

      new_opts =
        opts |> Keyword.put(:retry_count, retry_count + 1) |> Keyword.put(:model, new_model)

      do_call_raw(prompt, history, new_opts, retry_count + 1)
    else
      {:error, "Max LLM retries reached"}
    end
  end

  defp select_fallback_model(current_model) do
    case list_models() do
      {:ok, models} when length(models) > 1 ->
        models
        |> Enum.filter(&fallback_candidate?(&1, current_model))
        |> case do
          [] -> current_model
          candidates -> Enum.random(candidates)
        end

      _ ->
        current_model
    end
  end

  defp model_family(model) do
    model
    |> to_string()
    |> String.replace(~r|^models/|, "")
    |> String.split("-", parts: 2)
    |> List.first()
  end

  defp fallback_candidate?(model, current_model) do
    model != current_model and model_family(model) == model_family(current_model)
  end

  defp provider do
    Config.llm_provider() || runtime_provider()
  end

  defp runtime_provider do
    case runtime_type() do
      :local -> Local
      _ -> OpenAI
    end
  end

  defp runtime_type do
    Config.runtime_type()
  end
end
