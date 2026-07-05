defmodule AOS.AgentOS.MCP.Manager do
  @moduledoc """
  Manager for multiple MCP server clients.
  """
  use GenServer
  require Logger
  alias AOS.AgentOS.MCP.Client
  alias AOS.AgentOS.MCP.Internal.Shell
  alias AOS.AgentOS.Tools

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def all_tools do
    internal_tools =
      case Shell.list_tools() do
        {:ok, %{"tools" => tools}} -> Enum.map(tools, &Map.put(&1, "server_id", "internal"))
        _ -> []
      end

    external_tools = GenServer.call(__MODULE__, :all_tools)
    internal_tools ++ external_tools
  end

  def sync_tool_registry do
    all_tools()
    |> Tools.sync_registry()
  end

  def call_tool(server_id, tool_name, arguments, timeout \\ 60_000)

  def call_tool("internal", tool_name, arguments, _timeout) do
    Shell.call_tool(tool_name, arguments)
  end

  def call_tool(server_id, tool_name, arguments, timeout) do
    GenServer.call(__MODULE__, {:call_tool, server_id, tool_name, arguments, timeout}, timeout)
  end

  @doc """
  Dynamically registers a new MCP server.
  """
  def register_server(id, opts) do
    GenServer.call(__MODULE__, {:register_server, id, opts})
  end

  @doc """
  Dynamically unregisters and stops an MCP server.
  """
  def unregister_server(id) do
    GenServer.call(__MODULE__, {:unregister_server, id})
  end

  @impl true
  def init(_) do
    servers = Application.get_env(:aos, :mcp_servers, %{})

    clients =
      Enum.reduce(servers, %{}, fn {id, opts}, acc ->
        case Client.start_link(Keyword.put(opts, :name, nil)) do
          {:ok, pid} -> Map.put(acc, id, pid)
          _ -> acc
        end
      end)

    {:ok, %{clients: clients}}
  end

  @impl true
  def handle_call({:register_server, id, opts}, _from, state) do
    case Map.get(state.clients, id) do
      nil ->
        case Client.start_link(Keyword.put(opts, :name, nil)) do
          {:ok, pid} ->
            Logger.info("[MCP.Manager] Registered new server: #{id}")
            {:reply, :ok, %{state | clients: Map.put(state.clients, id, pid)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _pid ->
        {:reply, {:error, :already_registered}, state}
    end
  end

  @impl true
  def handle_call({:unregister_server, id}, _from, state) do
    case Map.get(state.clients, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      pid ->
        # Properly stop the client process
        GenServer.stop(pid)
        Logger.info("[MCP.Manager] Unregistered server: #{id}")
        {:reply, :ok, %{state | clients: Map.delete(state.clients, id)}}
    end
  end

  @impl true
  def handle_call(:all_tools, _from, state) do
    tools =
      Enum.flat_map(state.clients, fn {id, pid} ->
        case Client.list_tools(pid) do
          {:ok, %{"tools" => tools}} ->
            Enum.map(tools, &Map.put(&1, "server_id", id))

          _ ->
            []
        end
      end)

    {:reply, tools, state}
  end

  @impl true
  def handle_call({:call_tool, server_id, tool_name, arguments, timeout}, _from, state) do
    case Map.get(state.clients, server_id) do
      nil -> {:reply, {:error, :server_not_found}, state}
      pid -> {:reply, Client.call_tool(pid, tool_name, arguments, timeout), state}
    end
  end
end
