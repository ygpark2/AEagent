defmodule AOS.AgentOS.Roles.Executor do
  @moduledoc "Executes a user task through the LLM and available tools."

  @behaviour AOS.AgentOS.Role
  alias AOS.AgentOS.Roles.LLM

  def id, do: :executor
  def schema, do: %{}

  def run(input, _ctx) do
    skills = Map.get(input, :selected_skills, [])
    message = Map.get(input, :message) || Map.get(input, :task, "")
    skill_context = build_skill_context(skills)

    prompt = """
    You are an autonomous executor agent. 
    User request: "#{message}"
    #{skill_context}

    CRITICAL CAPABILITY: You HAVE access to real-time web search via the 'web_search' tool.
    If the user asks for current events, stock prices, news, or information you don't have in your training data, you MUST use the 'web_search' tool.

    Do not give excuses about not having real-time access. Just use the tool.

    Available Tool Highlights:
    - web_search: For real-time info, stock prices, news.
    - ls, read_file, grep_search: For codebase interaction.
    - execute_command: For running terminal commands (requires confirmation).
    - write_file, replace: For file edits (require confirmation).

    Proceed with necessary tool calls now to fulfill the request.
    """

    case LLM.call_with_meta(prompt,
           history: Map.get(input, :history, []),
           notify: Map.get(input, :notify),
           execution_id: Map.get(input, :execution_id),
           session_id: Map.get(input, :session_id),
           selected_skills: skills,
           harness_manifest: Map.get(input, :harness_manifest),
           harness_budget_state: Map.get(input, :harness_budget_state, %{}),
           use_tools: true
         ) do
      {:ok, %{text: result} = meta} ->
        usage = Map.get(meta, "usage", %{})
        additional_cost = Map.get(meta, "cost_usd", 0.0)

        {:ok,
         input
         |> Map.merge(%{execution_result: result})
         |> Map.put(:harness_budget_state, Map.get(meta, "harness_budget_state", %{}))
         |> accumulate_budget(additional_cost, usage)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_skill_context([]), do: ""

  defp build_skill_context(skills) do
    rendered =
      Enum.map_join(skills, "\n", fn skill ->
        "- #{skill.name}: #{skill.description} | Capabilities: #{Enum.join(skill.capabilities || [], ", ")}"
      end)

    """
    Selected specialist skills:
    #{rendered}
    """
  end

  defp accumulate_budget(context, additional_cost, usage) do
    usage_history = Map.get(context, :llm_usage, [])

    context
    |> Map.update(:cost_usd, additional_cost, &Float.round(&1 + additional_cost, 6))
    |> Map.put(:estimated_cost, Map.get(context, :cost_usd, 0.0) + additional_cost)
    |> Map.put(:last_llm_usage, usage)
    |> Map.put(:llm_usage, usage_history ++ [usage])
  end
end
