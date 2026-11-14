defmodule AOS.AgentOS.Execution.Watchdog do
  @moduledoc """
  Monitors active executions against configured SLA timeouts and transitions
  stalled runs cleanly to `timed_out`, releasing pending approvals and resources.
  """
  use GenServer
  require Logger

  alias AOS.AgentOS.Config
  alias AOS.AgentOS.Execution.Store
  alias AOS.AgentOS.Executions

  @default_interval_ms 10_000
  @default_timeout_ms 300_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Triggers an immediate timeout sweep across active executions.
  """
  def check_timeouts(server \\ __MODULE__, opts \\ []) do
    GenServer.call(server, {:check_timeouts, opts})
  end

  @impl true
  def init(opts) do
    interval =
      Keyword.get(
        opts,
        :interval_ms,
        Config.get(:watchdog_interval_ms, @default_interval_ms)
      )

    timeout =
      Keyword.get(
        opts,
        :default_timeout_ms,
        Config.get(:execution_timeout_ms, @default_timeout_ms)
      )

    if interval > 0 do
      schedule_check(interval)
    end

    {:ok, %{interval_ms: interval, default_timeout_ms: timeout}}
  end

  @impl true
  def handle_call({:check_timeouts, call_opts}, _from, state) do
    timed_out = do_check_timeouts(state, call_opts)
    {:reply, {:ok, timed_out}, state}
  end

  @impl true
  def handle_info(:check_timeouts, state) do
    do_check_timeouts(state, [])

    if state.interval_ms > 0 do
      schedule_check(state.interval_ms)
    end

    {:noreply, state}
  end

  defp do_check_timeouts(state, call_opts) do
    default_timeout = Keyword.get(call_opts, :default_timeout_ms, state.default_timeout_ms)
    now = Keyword.get(call_opts, :now, DateTime.utc_now())

    Store.list_executions(status: "running")
    |> Enum.filter(fn execution ->
      execution_expired?(execution, now, default_timeout) and
        timeout_running_execution(execution)
    end)
  end

  defp execution_expired?(execution, now, default_timeout) do
    timeout_ms = get_execution_timeout(execution, default_timeout)
    started = execution.started_at || execution.inserted_at
    started != nil and DateTime.diff(now, started, :millisecond) >= timeout_ms
  end

  defp timeout_running_execution(execution) do
    Logger.warning(
      "[Watchdog] Execution #{execution.id} exceeded timeout. Transitioning to timed_out."
    )

    case Executions.timeout_execution(execution.id, %{}, :sla_timeout_exceeded) do
      {:ok, _updated} -> true
      _ -> false
    end
  end

  defp get_execution_timeout(execution, default_timeout) do
    case execution.execution_log do
      %{"timeout_ms" => t} when is_integer(t) and t > 0 -> t
      %{"sla_timeout_ms" => t} when is_integer(t) and t > 0 -> t
      _ -> default_timeout
    end
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_timeouts, interval)
  end
end
