defmodule HierarchyPai.PlanStore do
  @moduledoc """
  In-memory store for named saved plans, backed by ETS.

  Users can save any plan produced by the Planner to give it a name and
  recall it later for review, editing, or re-execution. Plans can also be
  exported as JSON files and re-imported via the UI.

  Data is node-local and not persisted across server restarts. Export the
  plan to JSON for durable storage.

  Entry shape:

      %{
        id:       "hex-id",
        name:     "Q1 Research Plan",
        task:     "Original task description",
        plan:     %{"goal" => "...", "steps" => [...]},
        saved_at: ~U[2026-03-17 10:00:00Z]
      }

  """

  use GenServer

  @table :plan_store
  @max_plans 50

  ## Public API

  @doc "Returns all saved plans sorted by most recently saved first."
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, entry} -> entry end)
    |> Enum.sort_by(& &1.saved_at, {:desc, DateTime})
    |> Enum.take(@max_plans)
  end

  @doc "Returns a single plan entry by id, or `nil` if not found."
  @spec get(String.t()) :: map() | nil
  def get(id) do
    case :ets.lookup(@table, id) do
      [{_id, entry}] -> entry
      [] -> nil
    end
  end

  @doc "Saves a plan under the given name. Generates a new id."
  @spec save(String.t(), String.t(), map()) :: {:ok, map()}
  def save(name, task, plan) do
    GenServer.call(__MODULE__, {:save, name, task, plan})
  end

  @doc "Deletes a saved plan by id."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    GenServer.call(__MODULE__, {:delete, id})
  end

  ## GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init([]) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:save, name, task, plan}, _from, state) do
    id = generate_id()

    entry = %{
      id: id,
      name: name,
      task: task,
      plan: plan,
      saved_at: DateTime.utc_now()
    }

    :ets.insert(@table, {id, entry})
    {:reply, {:ok, entry}, state}
  end

  @impl true
  def handle_call({:delete, id}, _from, state) do
    :ets.delete(@table, id)
    {:reply, :ok, state}
  end

  defp generate_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
