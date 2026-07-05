defmodule AOS.AgentOS.Roles.LLM do
  @moduledoc """
  Helper for roles to interact with the LLM. 
  Includes handling for :empty_response as a retryable error.
  """
  alias AOS.AgentOS.LLM.{Client, Usage}
  alias AOS.AgentOS.MCP.Manager
  alias AOS.AgentOS.Tools
  alias AOS.AgentOS.ToolUse.{ApprovalService, AuditService}

  require OpenTelemetry.Tracer, as: Tracer

  def call(prompt, opts \\ []) do
    Tracer.with_span "LLM.call" do
      case call_with_meta(prompt, opts) do
        {:ok, %{text: text}} -> {:ok, text}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def call_with_meta(prompt, opts \\ []) do
    Tracer.with_span "LLM.call_with_meta" do
      use_tools? = Keyword.get(opts, :use_tools, true)
      notify_pid = Keyword.get(opts, :notify)
      history = Keyword.get(opts, :history, [])

      if use_tools? do
        call_with_tools(prompt, history, opts, notify_pid)
      else
        execute_call(prompt, history, opts)
      end
    end
  end

  defp call_with_tools(prompt, history, opts, notify_pid, depth \\ 0, acc_meta \\ empty_meta()) do
    if depth > 10,
      do: {:ok, Map.merge(acc_meta, %{text: "Too many tool calls."})},
      else: continue_tool_loop(prompt, history, opts, notify_pid, depth, acc_meta)
  end

  defp continue_tool_loop(prompt, history, opts, notify_pid, depth, acc_meta) do
    current_history = current_tool_history(prompt, history, depth)

    case execute_call_raw(nil, current_history, Keyword.put(opts, :tools, permitted_tools(opts))) do
      {:ok, %{"tool_calls" => tool_calls} = meta} when not is_nil(tool_calls) ->
        case tool_response_messages(tool_calls, notify_pid, opts) do
          {:ok, messages} ->
            new_history = current_history ++ messages

            call_with_tools(
              nil,
              new_history,
              opts,
              notify_pid,
              depth + 1,
              merge_meta(acc_meta, meta)
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{"text" => text} = meta} ->
        {:ok, Map.merge(merge_meta(acc_meta, meta), %{text: text})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_tool_history(prompt, history, 0) when not is_nil(prompt),
    do: history ++ [{"user", prompt}]

  defp current_tool_history(_prompt, history, _depth), do: history

  defp permitted_tools(opts) do
    Manager.all_tools()
    |> Tools.permitted_tools(Keyword.get(opts, :selected_skills, []))
  end

  defp tool_response_messages(tool_calls, notify_pid, opts) do
    Enum.reduce_while(tool_calls, {:ok, []}, fn tool_call, {:ok, acc} ->
      case execute_single_tool(tool_call, notify_pid, opts) do
        {:error, reason} -> {:halt, {:error, reason}}
        result -> {:cont, {:ok, [{tool_call["id"], tool_call["name"], result} | acc]}}
      end
    end)
    |> case do
      {:ok, tool_results} ->
        tool_messages =
          tool_results
          |> Enum.reverse()
          |> Enum.map(&tool_result_message/1)

        messages = [{"assistant", %{tool_calls: tool_calls}} | tool_messages]
        {:ok, messages}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_result_message({id, name, result}) do
    {"tool", %{id: id, name: name, content: result}}
  end

  defp execute_single_tool(%{"name" => full_name, "arguments" => args}, notify_pid, opts) do
    Tracer.with_span "LLM.execute_tool", %{attributes: %{"tool.name" => full_name}} do
      parts = String.split(full_name, "__", parts: 2)

      {server_id, tool_name} =
        case parts do
          [s, t] -> {s, t}
          [t] -> {"internal", t}
        end

      metadata = Tools.metadata_for(server_id, tool_name)

      decision =
        ApprovalService.request_tool_confirmation(
          server_id,
          tool_name,
          args,
          notify_pid,
          metadata,
          opts
        )

      case decision do
        {:pending, request} ->
          {:error, {:approval_required, request}}

        _decision ->
          execute_decided_tool(server_id, tool_name, args, metadata, decision, notify_pid, opts)
      end
    end
  end

  defp execute_decided_tool(server_id, tool_name, args, metadata, decision, notify_pid, opts) do
    started_at = DateTime.utc_now()
    display_name = "Tool: #{tool_name}"

    if is_pid(notify_pid) and decision == :approved,
      do: send(notify_pid, {:workflow_step_started, display_name})

    raw_result =
      case decision do
        :approved -> call_tool_with_retry(server_id, tool_name, args, metadata, 1)
        :rejected -> {1, {:error, "Tool execution rejected by user."}}
      end

    attempts = attempts_from_result(raw_result)

    result =
      Tools.normalize_result(
        server_id,
        tool_name,
        args,
        metadata,
        decision,
        raw_result_to_outcome(raw_result),
        attempts
      )

    AuditService.persist_tool_audit(
      opts,
      server_id,
      tool_name,
      metadata,
      args,
      result,
      started_at
    )

    if notify_pid,
      do: send(notify_pid, {:workflow_step_completed, display_name, %{result: result}})

    result
  end

  defp execute_call(prompt, history, opts) do
    case execute_call_raw(prompt, history, opts) do
      {:ok, %{"text" => text} = meta} -> {:ok, Map.merge(meta, %{text: text})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_call_raw(prompt, history, opts) do
    Client.call_raw(prompt, history, opts)
  end

  def list_models do
    Client.list_models()
  end

  defp call_tool_with_retry(server_id, tool_name, args, metadata, attempt) do
    timeout_ms = Map.get(metadata, :timeout_ms, 60_000)

    result =
      case Manager.call_tool(server_id, tool_name, args, timeout_ms) do
        {:ok, res} -> {:ok, res}
        {:error, err} -> {:error, err}
      end

    cond do
      match?({:ok, _}, result) ->
        {attempt, result}

      metadata.retryable and attempt < 2 and retryable_tool_error?(elem(result, 1)) ->
        Process.sleep(250)
        call_tool_with_retry(server_id, tool_name, args, metadata, attempt + 1)

      true ->
        {attempt, result}
    end
  end

  defp raw_result_to_outcome({_attempts, result}), do: result

  defp attempts_from_result({attempts, _result}), do: attempts

  defp retryable_tool_error?(reason) when is_binary(reason) do
    downcased = String.downcase(reason)

    String.contains?(downcased, "network") or String.contains?(downcased, "timeout") or
      String.contains?(downcased, "http error: 5")
  end

  defp retryable_tool_error?(_reason), do: false

  def estimate_usage(prompt, history, result_text) do
    Usage.estimate_usage(prompt, history, result_text)
  end

  def estimate_cost(usage, model \\ nil) do
    Usage.estimate_cost(usage, model)
  end

  defp empty_meta do
    %{
      "usage" => Usage.normalize_usage(nil),
      "cost_usd" => 0.0
    }
  end

  defp merge_meta(acc, meta) do
    acc_usage = Usage.normalize_usage(acc["usage"] || acc[:usage])
    meta_usage = Usage.normalize_usage(meta["usage"] || meta[:usage])

    %{
      "usage" => %{
        prompt_tokens: acc_usage.prompt_tokens + meta_usage.prompt_tokens,
        completion_tokens: acc_usage.completion_tokens + meta_usage.completion_tokens,
        total_tokens: acc_usage.total_tokens + meta_usage.total_tokens
      },
      "cost_usd" =>
        Float.round(
          (acc["cost_usd"] || acc[:cost_usd] || 0.0) +
            (meta["cost_usd"] || meta[:cost_usd] || 0.0),
          6
        ),
      "model" => meta["model"] || acc["model"] || acc[:model]
    }
  end
end
