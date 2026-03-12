defmodule HierarchyPai.ProviderStore do
  @moduledoc """
  In-memory store for named LLM provider configurations backed by ETS.

  Entries survive LiveView process crashes and are shared across all sessions
  on the same node. Data is lost on server restart (no persistence layer yet).

  Each entry shape:
      %{
        id:          "uuid-hex",
        name:        "My Copilot",
        provider:    :github_copilot,
        model:       "gpt-4o",
        api_key:     "github_pat_...",
        endpoint:    "https://api.githubcopilot.com/v1/chat/completions",
        max_retries: 0,   # integer, defaults to 0; callers use Map.get(entry, :max_retries, 0)
        is_default:  true # boolean; only one entry has this set to true at a time
      }

  Both `max_retries` and `is_default` are optional for backwards compatibility.
  Use `Map.get(entry, :max_retries, 0)` and `Map.get(entry, :is_default, false)`.
  """

  use GenServer

  @table :provider_store

  ## Public API

  @doc "Returns all saved provider entries, sorted by name."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Returns a single entry by id, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Inserts or updates an entry. Generates an id if none is provided."
  @spec save(map()) :: {:ok, map()}
  def save(entry) do
    GenServer.call(__MODULE__, {:save, entry})
  end

  @doc "Deletes an entry by id."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  @doc "Marks the provider with `id` as the default, clearing is_default on all others."
  @spec set_default(String.t()) :: :ok
  def set_default(id) do
    GenServer.call(__MODULE__, {:set_default, id})
  end

  ## GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:save, entry}, _from, state) do
    id = Map.get(entry, :id) || generate_id()
    full = Map.put(entry, :id, id)
    :ets.insert(@table, {id, full})
    {:reply, {:ok, full}, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set_default, id}, _from, state) do
    :ets.tab2list(@table)
    |> Enum.each(fn {eid, entry} ->
      :ets.insert(@table, {eid, Map.put(entry, :is_default, eid == id)})
    end)

    {:reply, :ok, state}
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
