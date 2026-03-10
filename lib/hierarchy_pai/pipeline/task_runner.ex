defmodule HierarchyPai.Pipeline.TaskRunner do
  @moduledoc """
  Ash Resource exposing pipeline execution actions as MCP tools.

  Each generic action wraps the synchronous PipelineRunner functions, encoding
  results as JSON strings so they are compatible with the MCP tool protocol.
  """

  use Ash.Resource, domain: HierarchyPai.Pipeline

  alias HierarchyPai.Pipeline.PipelineRunner
  alias HierarchyPai.RunStore

  actions do
    action :run_task, :string do
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
        provider_ref = input.arguments[:provider]

        with {:ok, provider_config} <- PipelineRunner.resolve_provider(provider_ref) do
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

          case PipelineRunner.run_task(task, provider_config, run_id) do
            {:ok, result} ->
              {:ok,
               Jason.encode!(%{
                 run_id: run_id,
                 answer: result.answer,
                 steps:
                   Enum.map(result.steps, fn s ->
                     %{id: s["id"], output: s["output"]}
                   end)
               })}

            {:error, reason} ->
              {:ok, Jason.encode!(%{run_id: run_id, error: reason})}
          end
        end
      end
    end

    action :plan_task, :string do
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
        provider_ref = input.arguments[:provider]

        with {:ok, provider_config} <- PipelineRunner.resolve_provider(provider_ref) do
          case PipelineRunner.plan_task(task, provider_config) do
            {:ok, plan} ->
              {:ok, Jason.encode!(plan)}

            {:error, reason} ->
              {:ok, Jason.encode!(%{error: reason})}
          end
        end
      end
    end

    action :execute_plan, :string do
      description """
      Execute a pre-built plan JSON produced by `plan_task`.

      Pass the JSON string returned by `plan_task` as the `plan` argument.
      Returns a synthesised answer and individual step outputs.
      """

      argument :task, :string do
        allow_nil? false
        description "The original task description (used for context and run tracking)."
      end

      argument :plan, :string do
        allow_nil? false
        description "The plan JSON string as returned by plan_task."
      end

      argument :provider, :string do
        allow_nil? true
        description "Saved provider name or ID. Defaults to the first saved provider."
      end

      run fn input, _context ->
        task = input.arguments.task
        plan_json = input.arguments.plan
        provider_ref = input.arguments[:provider]

        with {:ok, plan} <- Jason.decode(plan_json),
             {:ok, provider_config} <- PipelineRunner.resolve_provider(provider_ref) do
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

          case PipelineRunner.execute_plan(plan, provider_config, run_id) do
            {:ok, result} ->
              {:ok,
               Jason.encode!(%{
                 run_id: run_id,
                 answer: result.answer,
                 steps:
                   Enum.map(result.steps, fn s ->
                     %{id: s["id"], output: s["output"]}
                   end)
               })}

            {:error, reason} ->
              {:ok, Jason.encode!(%{run_id: run_id, error: reason})}
          end
        else
          {:error, %Jason.DecodeError{} = err} ->
            {:ok, Jason.encode!(%{error: "Invalid plan JSON: #{Exception.message(err)}"})}

          {:error, reason} ->
            {:ok, Jason.encode!(%{error: reason})}
        end
      end
    end
  end
end
