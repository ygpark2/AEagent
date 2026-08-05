defmodule AOS.AgentOS.Runtime.Scheduler do
  @moduledoc """
  An autonomous scheduler, now powered by the Dynamic Agent Graph Engine.
  """
  use GenServer
  require Logger
  alias AOS.AgentOS.Core.{Architect, Engine}
  alias AOS.AgentOS.Goals

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def schedule_task(task_name, cron_expr, initial_input) do
    GenServer.cast(__MODULE__, {:schedule, task_name, cron_expr, initial_input})
  end

  @impl true
  def init(_) do
    :timer.send_interval(60_000, :tick)
    {:ok, %{tasks: []}}
  end

  @impl true
  def handle_cast({:schedule, name, expr, input}, state) do
    Logger.info("Scheduled task #{name} (Cron: #{expr})")
    {:noreply, Map.put(state, :tasks, state.tasks ++ [%{name: name, expr: expr, input: input}])}
  end

  @impl true
  def handle_info(:tick, state) do
    Goals.dispatch_due_goals()

    Enum.each(state.tasks, fn task ->
      Logger.info("Autonomous Wakeup: Executing scheduled task '#{task.name}'...")

      # Use the task content/description to design a graph dynamically
      task_description = Map.get(task.input, :task, task.name)
      graph = Architect.build_graph(task_description)

      Task.start(fn ->
        Engine.run(graph, task.input)
      end)
    end)

    {:noreply, state}
  end
end
