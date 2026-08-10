defmodule AOS.AgentOS.Roles.LLM do
  @moduledoc """
  Helper for roles to interact with the LLM. 
  Includes handling for :empty_response as a retryable error.
  """
  alias AOS.AgentOS.LLM.{Client, Usage}
  alias AOS.AgentOS.MCP.Manager
  alias AOS.AgentOS.Tools
  alias AOS.AgentOS.ToolUse.{ApprovalService, AuditService}
  alias AOS.AgentOS.Harness
  alias AOS.AgentOS.Harness.Budget

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
          {:ok, messages, next_opts} ->
            new_history = current_history ++ messages

            call_with_tools(
              nil,
              new_history,
              next_opts,
              notify_pid,
              depth + 1,
              merge_meta(acc_meta, meta)
            )

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{"text" => text} = meta} ->
        {:ok,
         merge_meta(acc_meta, meta)
         |> Map.put(:text, text)
         |> Map.put("harness_budget_state", Keyword.get(opts, :harness_budget_state, %{}))}

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
    Enum.reduce_while(tool_calls, {:ok, [], opts}, fn tool_call, {:ok, acc, current_opts} ->
      case execute_single_tool(tool_call, notify_pid, current_opts) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        {:ok, result, next_opts} ->
          {:cont, {:ok, [{tool_call["id"], tool_call["name"], result} | acc], next_opts}}
      end
    end)
    |> case do
      {:ok, tool_results, next_opts} ->
        tool_messages =
          tool_results
          |> Enum.reverse()
          |> Enum.map(&tool_result_message/1)

        messages = [{"assistant", %{tool_calls: tool_calls}} | tool_messages]
        {:ok, messages, next_opts}

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

      with {:ok, budgeted_opts} <- Budget.before_tool(opts, server_id, tool_name, metadata) do
        decision =
          ApprovalService.request_tool_confirmation(
            server_id,
            tool_name,
            args,
            notify_pid,
            metadata,
            budgeted_opts
          )

        case decision do
          {:pending, request} ->
            {:error, {:approval_required, request}}

          _decision ->
            result =
              execute_decided_tool(
                server_id,
                tool_name,
                args,
                metadata,
                decision,
                notify_pid,
                budgeted_opts
              )

            {:ok, result, Budget.after_tool(budgeted_opts, result)}
        end
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

    Harness.trace(
      Keyword.get(opts, :execution_id),
      "tool",
      "completed",
      %{
        server_id: server_id,
        tool_name: tool_name,
        status: result.status,
        attempts: result.attempts
      }
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
