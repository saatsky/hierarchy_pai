defmodule HierarchyPai.RunStore do
  @moduledoc """
  In-memory store for MCP pipeline runs backed by ETS.

  Each run tracks a task submitted via the MCP server from planning through
  aggregation.  Runs are visible to all connected LiveView tabs via PubSub.

  Run shape:
      %{
        id:         "uuid-hex",
        task:       "original task text",
        status:     :planning | :executing | :aggregating | :done | :error,
        plan:       map() | nil,
        steps:      [%{id, title, status, output}],
        answer:     String.t() | nil,
        error:      String.t() | nil,
        started_at: DateTime.t()
      }
  """

  use GenServer

  @table :run_store
  @max_runs 20
  @pubsub HierarchyPai.PubSub
  @topic "mcp_runs"

  ## Public API

  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, run} -> run end)
    |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
    |> Enum.take(@max_runs)
  end

  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{_id, run}] -> run
      [] -> nil
    end
  end

  @spec put(map()) :: {:ok, map()}
  def put(run) do
    GenServer.call(__MODULE__, {:put, run})
  end

  @spec update(String.t(), (map() -> map())) :: {:ok, map()} | :error
  def update(id, fun) do
    GenServer.call(__MODULE__, {:update, id, fun})
  end

  ## GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, run}, _from, state) do
    run = Map.put_new(run, :started_at, DateTime.utc_now())
    :ets.insert(@table, {run.id, run})
    broadcast({:mcp_run_updated, run})
    {:reply, {:ok, run}, state}
  end

  def handle_call({:update, id, fun}, _from, state) do
    case :ets.lookup(@table, id) do
      [{_id, run}] ->
        updated = fun.(run)
        :ets.insert(@table, {id, updated})
        broadcast({:mcp_run_updated, updated})
        {:reply, {:ok, updated}, state}

      [] ->
        {:reply, :error, state}
    end
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:run_store, event})
  end
end
