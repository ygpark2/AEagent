defmodule AOS.AgentOS.MCP.Client do
  @moduledoc """
  A GenServer that manages an external MCP server process and handles JSON-RPC over Stdio.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def list_tools(pid) do
    GenServer.call(pid, {:request, "tools/list", %{}}, 30_000)
  end

  def call_tool(pid, tool_name, arguments, timeout \\ 60_000) do
    GenServer.call(
      pid,
      {:request, "tools/call", %{name: tool_name, arguments: arguments}},
      timeout
    )
  end

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])

    port =
      Port.open({:spawn_executable, System.find_executable(command)}, [
        :binary,
        :exit_status,
        :use_stdio,
        args: args
      ])

    state = %{
      port: port,
      requests: %{},
      next_id: 1,
      initialized: false,
      buffer: ""
    }

    # Initialize MCP
    send(self(), :initialize)

    {:ok, state}
  end

  @impl true
  def handle_info(:initialize, state) do
    {updated_state, _id} =
      send_request(state, "initialize", %{
        protocolVersion: "2024-11-05",
        capabilities: %{},
        clientInfo: %{name: "AOS-Agent-OS", version: "0.1.0"}
      })

    {:noreply, %{updated_state | initialized: true}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_buffer = state.buffer <> data
    {messages, remaining_buffer} = parse_buffer(new_buffer, [])

    new_state =
      Enum.reduce(messages, %{state | buffer: remaining_buffer}, fn msg, acc ->
        handle_mcp_message(msg, acc)
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:request, method, params}, from, state) do
    {state, id} = send_request(state, method, params)
    new_requests = Map.put(state.requests, id, from)
    {:noreply, %{state | requests: new_requests}}
  end

  defp send_request(state, method, params) do
    id = state.next_id

    request = %{
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: params
    }

    payload = Jason.encode!(request) <> "\n"
    Port.command(state.port, payload)

    {%{state | next_id: id + 1}, id}
  end

  defp parse_buffer(buffer, acc) do
    case String.split(buffer, "\n", parts: 2) do
      [msg, rest] -> parse_buffer(rest, acc ++ [msg])
      [rest] -> {acc, rest}
    end
  end

  defp handle_mcp_message(msg, state) do
    case Jason.decode(msg) do
      {:ok, %{"id" => id, "result" => result}} ->
        case Map.pop(state.requests, id) do
          {nil, _} ->
            state

          {from, remaining_requests} ->
            GenServer.reply(from, {:ok, result})
            %{state | requests: remaining_requests}
        end

      {:ok, %{"id" => id, "error" => error}} ->
        case Map.pop(state.requests, id) do
          {nil, _} ->
            state

          {from, remaining_requests} ->
            GenServer.reply(from, {:error, error})
            %{state | requests: remaining_requests}
        end

      _ ->
        # Log unexpected messages (notifications, logs, etc)
        # Logger.debug("MCP Notification: #{msg}")
        state
    end
  end
end
