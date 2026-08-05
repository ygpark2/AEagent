defmodule Mix.Tasks.Agent.Goal do
  @moduledoc "Create, inspect, control, and trigger durable AgentOS goals."

  @shortdoc "Manage durable AgentOS goals"

  use Mix.Task

  alias AOS.AgentOS.Goals

  @impl true
  def run(["create" | args]) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          goal_type: :string,
          autonomy_level: :string,
          trigger_type: :string,
          every_seconds: :integer,
          owner: :string,
          description: :string
        ]
      )

    reject_invalid!(invalid)

    case argv do
      [name | objective_parts] when objective_parts != [] ->
        trigger = build_trigger(opts)

        attrs = %{
          name: name,
          objective: Enum.join(objective_parts, " "),
          description: Keyword.get(opts, :description),
          goal_type: Keyword.get(opts, :goal_type, "ongoing"),
          autonomy_level: Keyword.get(opts, :autonomy_level),
          owner: Keyword.get(opts, :owner),
          trigger: trigger
        }

        case Goals.create_goal(attrs) do
          {:ok, goal} -> print_goal(goal)
          {:error, reason} -> Mix.raise("failed to create goal: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix agent.goal create <name> <objective> [options]")
    end
  end

  def run(["list" | args]) do
    Mix.Task.run("app.start")
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [limit: :integer, status: :string])
    reject_invalid!(invalid)

    Goals.list_goals(limit: Keyword.get(opts, :limit, 20), status: Keyword.get(opts, :status))
    |> Enum.each(fn goal ->
      Mix.shell().info("#{goal.id} | #{goal.status} | #{goal.name} | #{goal.objective}")
    end)
  end

  def run(["show", id_or_name]) do
    Mix.Task.run("app.start")
    print_goal(Goals.get_goal!(id_or_name))
  end

  def run(["trigger" | args]) do
    Mix.Task.run("app.start")

    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          event_type: :string,
          payload: :string,
          source: :string,
          idempotency_key: :string,
          wait: :boolean,
          start_immediately: :boolean
        ]
      )

    reject_invalid!(invalid)

    case argv do
      [id_or_name, event_type] ->
        payload = parse_payload!(Keyword.get(opts, :payload, "{}"))

        case Goals.trigger(id_or_name, event_type, payload,
               source: Keyword.get(opts, :source, "cli"),
               idempotency_key: Keyword.get(opts, :idempotency_key),
               async: !Keyword.get(opts, :wait, false),
               execution_async: !Keyword.get(opts, :wait, false),
               start_immediately: Keyword.get(opts, :start_immediately, true)
             ) do
          {:ok, event} -> Mix.shell().info("event_id=#{event.id} status=#{event.status}")
          {:error, reason} -> Mix.raise("failed to trigger goal: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("usage: mix agent.goal trigger <goal_id_or_name> <event_type> [options]")
    end
  end

  def run([command, id_or_name]) when command in ["pause", "resume", "cancel"] do
    Mix.Task.run("app.start")

    result =
      case command do
        "pause" -> Goals.pause_goal(id_or_name)
        "resume" -> Goals.resume_goal(id_or_name)
        "cancel" -> Goals.cancel_goal(id_or_name)
      end

    case result do
      {:ok, goal} -> print_goal(goal)
      {:error, reason} -> Mix.raise("failed to #{command} goal: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("usage: mix agent.goal create|list|show|trigger|pause|resume|cancel ...")
  end

  defp build_trigger(opts) do
    type = Keyword.get(opts, :trigger_type, "manual")
    base = %{"type" => type}

    case Keyword.get(opts, :every_seconds) do
      nil -> base
      seconds -> Map.put(base, "every_seconds", seconds)
    end
  end

  defp parse_payload!(payload) do
    case Jason.decode(payload) do
      {:ok, value} when is_map(value) -> value
      _ -> Mix.raise("--payload must be a JSON object")
    end
  end

  defp reject_invalid!([]), do: :ok
  defp reject_invalid!(invalid), do: Mix.raise("invalid options: #{inspect(invalid)}")

  defp print_goal(goal) do
    Mix.shell().info("id=#{goal.id}")
    Mix.shell().info("name=#{goal.name}")
    Mix.shell().info("status=#{goal.status}")
    Mix.shell().info("objective=#{goal.objective}")
    Mix.shell().info("trigger=#{Jason.encode!(goal.trigger)}")
  end
end
