defmodule HierarchyPai.Orchestrator do
  @moduledoc """
  Coordinates the hierarchical planning pipeline with separate plan/execute phases.

  Events emitted (all wrapped as `{:orchestrator, event}`):
    :planning_started
    {:planner_token, token}           (streamed from Planner)
    {:plan_ready, plan_map}
    {:step_started, step_map}
    {:step_token, step_id, token}     (streamed from Executor)
    {:step_done, step_id, output}
    {:step_error, step_id, reason}
    {:results_ready, results}
    :aggregating_started
    {:final_token, token}             (streamed from Aggregator)
    {:answer_ready, answer}
    {:error, reason}
  """

  alias HierarchyPai.Agents.{Planner, Executor, Aggregator}

  # Phase 1: only planning.
  @spec plan(String.t(), map(), String.t()) :: :ok
  def plan(task, provider_config, pubsub_topic) do
    broadcast(pubsub_topic, :planning_started)

    case Planner.plan(task, provider_config, pubsub_topic) do
      {:ok, plan} -> broadcast(pubsub_topic, {:plan_ready, plan})
      {:error, reason} -> broadcast(pubsub_topic, {:error, reason})
    end

    :ok
  end

  # Phase 2: execute accepted steps (dependency-aware parallel waves) then aggregate.
  # accepted_step_ids: MapSet of integer step IDs
  # step_configs: %{step_id => provider_config} (per-step override; falls back to default_provider_config)
  @spec execute(map(), MapSet.t(), map(), map(), String.t()) :: :ok
  def execute(plan, accepted_step_ids, step_configs, default_provider_config, pubsub_topic) do
    steps =
      (plan["steps"] || [])
      |> Enum.filter(&MapSet.member?(accepted_step_ids, &1["id"]))

    goal = plan["goal"] || ""

    case execute_waves(steps, step_configs, default_provider_config, pubsub_topic) do
      {:ok, results} ->
        broadcast(pubsub_topic, {:results_ready, results})
        broadcast(pubsub_topic, :aggregating_started)

        case Aggregator.aggregate(goal, results, default_provider_config, pubsub_topic) do
          {:ok, answer} -> broadcast(pubsub_topic, {:answer_ready, answer})
          {:error, reason} -> broadcast(pubsub_topic, {:error, reason})
        end

      {:error, _reason} ->
        # Individual {:step_error} events already broadcast inside execute_waves.
        # Emit :wave_failed so the UI can show the action panel without overwriting step error state.
        broadcast(pubsub_topic, :wave_failed)
    end

    :ok
  end

  # Execute only the given step_ids (no aggregation). Used for retrying failed steps.
  # On success broadcasts {:partial_results_ready, results}.
  # On failure relies on {:step_error} events already broadcast per step.
  @spec execute_steps(map(), MapSet.t(), map(), map(), String.t()) :: :ok
  def execute_steps(plan, step_ids, step_configs, default_provider_config, pubsub_topic) do
    steps =
      (plan["steps"] || [])
      |> Enum.filter(&MapSet.member?(step_ids, &1["id"]))

    case execute_waves(steps, step_configs, default_provider_config, pubsub_topic) do
      {:ok, results} -> broadcast(pubsub_topic, {:partial_results_ready, results})
      {:error, _reason} -> broadcast(pubsub_topic, :wave_failed)
    end

    :ok
  end

  # Re-run only the aggregation with previously collected results.
  @spec reaggregate(String.t(), list(), map(), String.t()) :: :ok
  def reaggregate(goal, step_results, provider_config, pubsub_topic) do
    broadcast(pubsub_topic, :aggregating_started)

    case Aggregator.aggregate(goal, step_results, provider_config, pubsub_topic) do
      {:ok, answer} -> broadcast(pubsub_topic, {:answer_ready, answer})
      {:error, reason} -> broadcast(pubsub_topic, {:error, reason})
    end

    :ok
  end

  # --- private ---

  # Topological levels: returns [[wave1_steps], [wave2_steps], ...]
  # Steps in the same wave are independent and can run in parallel.
  defp topological_levels(steps) do
    build_levels(steps, MapSet.new(), [])
  end

  defp build_levels([], _done, acc), do: Enum.reverse(acc)

  defp build_levels(remaining, done, acc) do
    {ready, not_ready} =
      Enum.split_with(remaining, fn step ->
        (step["depends_on"] || [])
        |> Enum.all?(&MapSet.member?(done, &1))
      end)

    if ready == [] do
      # circular or unresolvable — run everything remaining as one wave
      Enum.reverse([remaining | acc])
    else
      new_done = Enum.reduce(ready, done, &MapSet.put(&2, &1["id"]))
      build_levels(not_ready, new_done, [ready | acc])
    end
  end

  defp execute_waves(steps, step_configs, default_config, pubsub_topic) do
    levels = topological_levels(steps)

    Enum.reduce_while(levels, {:ok, []}, fn wave, {:ok, all_results} ->
      case execute_wave(wave, all_results, step_configs, default_config, pubsub_topic) do
        {:ok, wave_results} -> {:cont, {:ok, all_results ++ wave_results}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp execute_wave(steps, completed_results, step_configs, default_config, pubsub_topic) do
    raw =
      Task.async_stream(
        steps,
        fn step ->
          broadcast(pubsub_topic, {:step_started, step})
          config = Map.get(step_configs, step["id"], default_config)

          case Executor.execute(step, completed_results, config, pubsub_topic) do
            {:ok, output} ->
              broadcast(pubsub_topic, {:step_done, step["id"], output})
              {:ok, %{"step_id" => step["id"], "title" => step["title"], "output" => output}}

            {:error, reason} ->
              broadcast(pubsub_topic, {:step_error, step["id"], reason})
              {:error, reason}
          end
        end,
        timeout: :infinity,
        max_concurrency: System.schedulers_online()
      )
      |> Enum.to_list()

    # raw is [{:ok, {:ok, result}} | {:ok, {:error, reason}} | {:exit, reason}]
    errors =
      Enum.filter(raw, fn
        {:ok, {:error, _}} -> true
        {:exit, _} -> true
        _ -> false
      end)

    if errors != [] do
      {:error, "One or more steps failed in this wave"}
    else
      results = Enum.map(raw, fn {:ok, {:ok, r}} -> r end)
      {:ok, results}
    end
  end

  defp broadcast(topic, event) do
    Phoenix.PubSub.broadcast(HierarchyPai.PubSub, topic, {:orchestrator, event})
  end
end
