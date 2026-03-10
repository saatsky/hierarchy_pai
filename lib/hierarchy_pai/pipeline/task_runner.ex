defmodule HierarchyPai.Pipeline.TaskRunner do
  @moduledoc """
  Ash Resource exposing pipeline execution actions as MCP tools.

  Each generic action wraps the synchronous PipelineRunner functions and returns
  plain Elixir maps. ash_ai serializes these to JSON via Jason.encode!/1 for the
  MCP text content field, producing clean (single-encoded) JSON per the MCP spec.
  """

  use Ash.Resource, domain: HierarchyPai.Pipeline

  require Logger

  alias HierarchyPai.Pipeline.PipelineRunner
  alias HierarchyPai.RunStore

  actions do
    action :run_task, :map do
      description """
      Run the full hierarchy_pai planning pipeline end-to-end.

      Decomposes `task` into parallel specialist steps using the Planner LLM,
      executes each step concurrently with the appropriate specialist agent,
      and returns a synthesised final answer alongside individual step outputs.

      Optionally supply `provider` (saved provider name or ID from the hierarchy_pai
      UI at http://localhost:4000) to select which LLM provider to use.
      Defaults to the first saved provider if omitted.
      """

      argument :task, :string do
        allow_nil? false
        description "The task or question to plan and execute."
      end

      argument :provider, :string do
        allow_nil? true

        description "Saved provider name or ID from the hierarchy_pai UI. Defaults to the first saved provider."
      end

      run fn input, _context ->
        task = input.arguments.task
        provider_ref = Map.get(input.arguments, :provider)

        try do
          case PipelineRunner.resolve_provider(provider_ref) do
            {:error, reason} ->
              Logger.warning("[MCP run_task] provider resolve failed: #{reason}")
              {:ok, %{error: reason}}

            {:ok, provider_config} ->
              run_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

              RunStore.put(%{
                id: run_id,
                task: task,
                status: :planning,
                plan: nil,
                steps: [],
                answer: nil,
                error: nil
              })

              Logger.info(
                "[MCP run_task] starting run_id=#{run_id} task=#{String.slice(task, 0, 80)}"
              )

              case PipelineRunner.run_task(task, provider_config, run_id) do
                {:ok, result} ->
                  {:ok,
                   %{
                     run_id: run_id,
                     answer: result.answer,
                     steps:
                       Enum.map(result.steps, fn s ->
                         %{id: s["id"], output: s["output"]}
                       end)
                   }}

                {:error, reason} ->
                  Logger.error("[MCP run_task] pipeline failed run_id=#{run_id}: #{reason}")
                  {:ok, %{run_id: run_id, error: reason}}
              end
          end
        rescue
          e ->
            Logger.error("[MCP run_task] unexpected error: #{Exception.message(e)}")
            {:ok, %{error: Exception.message(e)}}
        end
      end
    end

    action :plan_task, :map do
      description """
      Generate a structured execution plan for a task without executing it.

      Returns a JSON plan object containing steps with specialist assignments and
      dependencies. You can review and optionally modify the plan, then pass it to
      `execute_plan` to run it.
      """

      argument :task, :string do
        allow_nil? false
        description "The task to plan."
      end

      argument :provider, :string do
        allow_nil? true
        description "Saved provider name or ID. Defaults to the first saved provider."
      end

      run fn input, _context ->
        task = input.arguments.task
        provider_ref = Map.get(input.arguments, :provider)

        try do
          case PipelineRunner.resolve_provider(provider_ref) do
            {:error, reason} ->
              Logger.warning("[MCP plan_task] provider resolve failed: #{reason}")
              {:ok, %{error: reason}}

            {:ok, provider_config} ->
              Logger.info("[MCP plan_task] planning task=#{String.slice(task, 0, 80)}")

              case PipelineRunner.plan_task(task, provider_config) do
                {:ok, plan} ->
                  {:ok, plan}

                {:error, reason} ->
                  Logger.error("[MCP plan_task] planning failed: #{reason}")
                  {:ok, %{error: reason}}
              end
          end
        rescue
          e ->
            Logger.error("[MCP plan_task] unexpected error: #{Exception.message(e)}")
            {:ok, %{error: Exception.message(e)}}
        end
      end
    end

    action :execute_plan, :map do
      description """
      Execute a pre-built plan produced by `plan_task`.

      Pass the plan object returned by `plan_task` as the `plan` argument.
      Returns a synthesised answer and individual step outputs.
      """

      argument :task, :string do
        allow_nil? false
        description "The original task description (used for context and run tracking)."
      end

      argument :plan, :map do
        allow_nil? false
        description "The plan object as returned by plan_task."
      end

      argument :provider, :string do
        allow_nil? true
        description "Saved provider name or ID. Defaults to the first saved provider."
      end

      run fn input, _context ->
        task = input.arguments.task
        plan = input.arguments.plan
        provider_ref = Map.get(input.arguments, :provider)

        try do
          case PipelineRunner.resolve_provider(provider_ref) do
            {:error, reason} ->
              Logger.warning("[MCP execute_plan] provider resolve failed: #{reason}")
              {:ok, %{error: reason}}

            {:ok, provider_config} ->
              run_id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

              RunStore.put(%{
                id: run_id,
                task: task,
                status: :executing,
                plan: plan,
                steps: [],
                answer: nil,
                error: nil
              })

              Logger.info("[MCP execute_plan] starting run_id=#{run_id}")

              case PipelineRunner.execute_plan(plan, provider_config, run_id) do
                {:ok, result} ->
                  {:ok,
                   %{
                     run_id: run_id,
                     answer: result.answer,
                     steps:
                       Enum.map(result.steps, fn s ->
                         %{id: s["id"], output: s["output"]}
                       end)
                   }}

                {:error, reason} ->
                  Logger.error("[MCP execute_plan] pipeline failed run_id=#{run_id}: #{reason}")
                  {:ok, %{run_id: run_id, error: reason}}
              end
          end
        rescue
          e ->
            Logger.error("[MCP execute_plan] unexpected error: #{Exception.message(e)}")
            {:ok, %{error: Exception.message(e)}}
        end
      end
    end
  end
end
