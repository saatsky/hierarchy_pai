defmodule HierarchyPai.McpServerStore do
  @moduledoc """
  In-memory store for registered external MCP servers, backed by ETS.

  Each entry represents an external HTTP MCP server that executor steps can
  call tools from. Users register servers in the Planner UI; the Connect
  button calls `HierarchyPai.McpClient.connect/1` to fetch and cache the
  server's tool list.

  Data is node-local and not persisted across server restarts.

  Entry shape:

      %{
        id:         "hex-id",
        name:       "Brave Search",
        url:        "http://localhost:9000/mcp",
        status:     :disconnected | :checking | :connected | :error,
        tools:      [%{"name" => "...", "description" => "...", "inputSchema" => %{...}}],
        tool_count: 0,
        error:      nil | String.t()
      }

  """

  use GenServer

  @table :mcp_server_store

  ## Public API

  @doc "Returns all registered MCP servers sorted by name."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns a single server entry by id, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates a server entry. Generates an id if none is provided."
  @spec save(map()) :: {:ok, map()}
  def save(entry) do
    GenServer.call(__MODULE__, {:save, entry})
  end

  @doc "Deletes a server entry by id."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc """
  Updates the connection status, tool list, and error field for a server.
  Called after `McpClient.connect/1` returns.
  """
  @spec update_status(String.t(), atom(), list(), String.t() | nil) :: :ok
  def update_status(id, status, tools \\ [], error \\ nil) do
    GenServer.call(__MODULE__, {:update_status, id, status, tools, error})
  end

  ## GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:save, entry}, _from, state) do
    id = Map.get(entry, :id) || generate_id()

    full =
      entry
      |> Map.put(:id, id)
      |> Map.put_new(:status, :disconnected)
      |> Map.put_new(:tools, [])
      |> Map.put_new(:tool_count, 0)
      |> Map.put_new(:error, nil)

    :ets.insert(@table, {id, full})
    {:reply, {:ok, full}, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_status, id, status, tools, error}, _from, state) do
    case :ets.lookup(@table, id) do
      [{_id, entry}] ->
        updated =
          entry
          |> Map.put(:status, status)
          |> Map.put(:tools, tools)
          |> Map.put(:tool_count, length(tools))
          |> Map.put(:error, error)

        :ets.insert(@table, {id, updated})
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
