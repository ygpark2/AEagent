defmodule AOS.AgentOS.Core.Nodes.LLMWorker do
  @moduledoc "Graph node that performs task work through an LLM."

  @behaviour AOS.AgentOS.Core.Node
  alias AOS.AgentOS.Roles.LLM
  require Logger

  @impl true
  def run(context, _opts) do
    task = Map.get(context, :task, "No task provided")
    feedback = Map.get(context, :feedback, "")
    history = Map.get(context, :history, [])
    notify_pid = Map.get(context, :notify)
    selected_skills = Map.get(context, :selected_skills, [])
    skill_brief = build_skill_brief(selected_skills)

    prompt = """
    You are a professional AI Worker. 
    Current Task: #{task}

    #{if feedback != "", do: "Previous Feedback to address: #{feedback}", else: ""}
    #{skill_brief}

    Please perform the task. You have access to tools if needed.
    """

    Logger.info("[LLMWorker] Calling LLM for task: #{task}")

    case LLM.call_with_meta(prompt,
           history: history,
           notify: notify_pid,
           execution_id: Map.get(context, :execution_id),
           source_execution_id: Map.get(context, :source_execution_id),
           session_id: Map.get(context, :session_id),
           workflow_id: Map.get(context, :workflow_id),
           selected_skills: selected_skills
         ) do
      {:ok, %{text: result} = meta} ->
        usage = Map.get(meta, "usage", %{})
        additional_cost = Map.get(meta, "cost_usd", 0.0)

        updated_context =
          context
          |> Map.put(:result, result)
          |> Map.put(:last_outcome, :success)
          |> accumulate_budget(additional_cost, usage)
          |> Map.put(:history, history ++ [{"user", prompt}, {"assistant", result}])

        {:ok, updated_context}

      {:error, reason} ->
        Logger.error("[LLMWorker] LLM Call failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_skill_brief([]), do: ""

  defp build_skill_brief(skills) do
    rendered =
      Enum.map_join(skills, "\n\n", fn skill ->
        """
        Skill: #{skill.name}
        Description: #{skill.description}
        Capabilities: #{Enum.join(skill.capabilities || [], ", ")}
        Instructions:
        #{skill.instructions || "No extra instructions."}
        """
      end)

    """
    Selected Skills:
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
