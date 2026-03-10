defmodule HierarchyPai.Pipeline.PipelineRunner do
  @moduledoc """
  Synchronous wrapper around the async PubSub-based Orchestrator pipeline.

  MCP tool calls are synchronous; this module subscribes to a unique PubSub topic,
  starts an orchestrator task, then collects events until the pipeline completes or
  times out.
  """

  alias HierarchyPai.{Orchestrator, ProviderStore, RunStore}

  @default_timeout 300_000

  @doc """
  Looks up a provider config from ProviderStore by provider entry id or name.
  Falls back to the first saved provider if `nil` is given.
  Returns `{:ok, config}` or `{:error, reason}`.
  """
  @spec resolve_provider(String.t() | nil) :: {:ok, map()} | {:error, String.t()}
  def resolve_provider(provider_ref) do
    providers = ProviderStore.list()

    entry =
      cond do
        is_nil(provider_ref) ->
          List.first(providers)

        true ->
          Enum.find(providers, fn p ->
            p.id == provider_ref or p.name == provider_ref
          end)
      end

    case entry do
      nil ->
        {:error,
         "No provider found. Please add a provider in the hierarchy_pai UI at http://localhost:4000"}

      entry ->
        config = build_config(entry)
        {:ok, config}
    end
  end

  @doc """
  Runs the full pipeline (plan + execute + aggregate) synchronously.
  Returns `{:ok, %{answer, plan, steps}}` or `{:error, reason}`.
  """
  @spec run_task(String.t(), map(), String.t(), timeout()) ::
          {:ok, map()} | {:error, String.t()}
  def run_task(task, provider_config, run_id, timeout \\ @default_timeout) do
    topic = "mcp:run:#{run_id}"
    Phoenix.PubSub.subscribe(HierarchyPai.PubSub, topic)

    Task.start(fn -> Orchestrator.plan(task, provider_config, topic) end)

    collect_run(topic, provider_config, run_id, timeout, %{plan: nil, steps: []})
  end

  @doc """
  Runs only the planning phase synchronously.
  Returns `{:ok, plan}` or `{:error, reason}`.
  """
  @spec plan_task(String.t(), map(), timeout()) :: {:ok, map()} | {:error, String.t()}
  def plan_task(task, provider_config, timeout \\ @default_timeout) do
    topic = "mcp:plan:#{:erlang.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(HierarchyPai.PubSub, topic)

    Task.start(fn -> Orchestrator.plan(task, provider_config, topic) end)

    receive do
      {:orchestrator, {:plan_ready, plan}} ->
        {:ok, plan}

      {:orchestrator, {:error, reason}} ->
        {:error, inspect(reason)}
    after
      timeout -> {:error, "Planning timed out after #{timeout}ms"}
    end
  end

  @doc """
  Executes a pre-built plan synchronously.
  Returns `{:ok, %{answer, steps}}` or `{:error, reason}`.
  """
  @spec execute_plan(map(), map(), String.t(), timeout()) ::
          {:ok, map()} | {:error, String.t()}
  def execute_plan(plan, provider_config, run_id, timeout \\ @default_timeout) do
    topic = "mcp:run:#{run_id}"
    Phoenix.PubSub.subscribe(HierarchyPai.PubSub, topic)

    all_step_ids = plan["steps"] |> Enum.map(& &1["id"]) |> MapSet.new()

    Task.start(fn ->
      Orchestrator.execute(plan, all_step_ids, %{}, provider_config, topic)
    end)

    collect_execution(topic, run_id, timeout, %{steps: []})
  end

  ## Private helpers

  defp collect_run(topic, provider_config, run_id, timeout, acc) do
    receive do
      {:orchestrator, {:plan_ready, plan}} ->
        RunStore.update(run_id, &Map.merge(&1, %{status: :executing, plan: plan}))
        all_step_ids = plan["steps"] |> Enum.map(& &1["id"]) |> MapSet.new()

        Task.start(fn ->
          Orchestrator.execute(plan, all_step_ids, %{}, provider_config, topic)
        end)

        collect_run(topic, provider_config, run_id, timeout, Map.put(acc, :plan, plan))

      {:orchestrator, {:step_done, step_id, output}} ->
        step_summary = %{"id" => step_id, "output" => output}
        updated = Map.update!(acc, :steps, &[step_summary | &1])
        collect_run(topic, provider_config, run_id, timeout, updated)

      {:orchestrator, {:step_error, step_id, reason}} ->
        step_summary = %{"id" => step_id, "error" => inspect(reason)}
        updated = Map.update!(acc, :steps, &[step_summary | &1])
        collect_run(topic, provider_config, run_id, timeout, updated)

      {:orchestrator, {:answer_ready, answer}} ->
        RunStore.update(run_id, &Map.merge(&1, %{status: :done, answer: answer}))
        {:ok, Map.merge(acc, %{answer: answer, steps: Enum.reverse(acc.steps)})}

      {:orchestrator, {:error, reason}} ->
        RunStore.update(run_id, &Map.merge(&1, %{status: :error, error: inspect(reason)}))
        {:error, inspect(reason)}

      {:orchestrator, :wave_failed} ->
        RunStore.update(run_id, &Map.put(&1, :status, :error))
        {:error, "One or more steps failed during execution"}

      {:orchestrator, _other} ->
        collect_run(topic, provider_config, run_id, timeout, acc)
    after
      timeout ->
        RunStore.update(run_id, &Map.put(&1, :status, :error))
        {:error, "Pipeline timed out after #{div(timeout, 1000)}s"}
    end
  end

  defp collect_execution(topic, run_id, timeout, acc) do
    receive do
      {:orchestrator, {:step_done, step_id, output}} ->
        step_summary = %{"id" => step_id, "output" => output}
        updated = Map.update!(acc, :steps, &[step_summary | &1])
        collect_execution(topic, run_id, timeout, updated)

      {:orchestrator, {:step_error, step_id, reason}} ->
        step_summary = %{"id" => step_id, "error" => inspect(reason)}
        updated = Map.update!(acc, :steps, &[step_summary | &1])
        collect_execution(topic, run_id, timeout, updated)

      {:orchestrator, {:answer_ready, answer}} ->
        RunStore.update(run_id, &Map.merge(&1, %{status: :done, answer: answer}))
        {:ok, %{answer: answer, steps: Enum.reverse(acc.steps)}}

      {:orchestrator, {:error, reason}} ->
        RunStore.update(run_id, &Map.merge(&1, %{status: :error, error: inspect(reason)}))
        {:error, inspect(reason)}

      {:orchestrator, :wave_failed} ->
        RunStore.update(run_id, &Map.put(&1, :status, :error))
        {:error, "One or more steps failed during execution"}

      {:orchestrator, _other} ->
        collect_execution(topic, run_id, timeout, acc)
    after
      timeout ->
        RunStore.update(run_id, &Map.put(&1, :status, :error))
        {:error, "Pipeline timed out after #{div(timeout, 1000)}s"}
    end
  end

  defp build_config(entry) do
    base = %{
      provider: entry.provider,
      model: entry.model,
      api_key: entry.api_key,
      max_retries: 1
    }

    cond do
      entry.provider in [:custom, :github_copilot] and entry.endpoint not in [nil, ""] ->
        Map.put(base, :endpoint, entry.endpoint)

      HierarchyPai.LLMProvider.local_provider?(entry.provider) and
          entry.endpoint not in [nil, ""] ->
        Map.put(base, :local_base, entry.endpoint)

      true ->
        base
    end
  end
end
