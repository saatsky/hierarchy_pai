defmodule HierarchyPai.Pipeline do
  @moduledoc """
  Ash Domain exposing the hierarchy_pai planning pipeline as MCP tools.

  Tools are auto-discovered by the AshAi MCP router via the `ash_domains` config key.
  """

  use Ash.Domain, extensions: [AshAi]

  tools do
    tool :run_task, HierarchyPai.Pipeline.TaskRunner, :run_task do
      description """
      Run the full hierarchy_pai pipeline end-to-end: plan → execute → synthesise.

      Decomposes the task into parallel specialist steps, executes each concurrently,
      and returns a synthesised final answer with individual step outputs.
      """
    end

    tool :plan_task, HierarchyPai.Pipeline.TaskRunner, :plan_task do
      description """
      Generate a structured execution plan without running it.

      Returns the plan JSON. Review or modify it, then pass to execute_plan.
      """
    end

    tool :execute_plan, HierarchyPai.Pipeline.TaskRunner, :execute_plan do
      description """
      Execute a pre-built plan produced by plan_task.

      Pass the JSON string from plan_task as the `plan` argument.
      """
    end

    tool :list_specialists, HierarchyPai.Pipeline.Discovery, :list_specialists do
      description "List all available specialist agents and their IDs."
    end

    tool :list_skills, HierarchyPai.Pipeline.Discovery, :list_skills do
      description "List all loaded SKILL.md skills with their IDs, types, and descriptions."
    end
  end

  resources do
    resource HierarchyPai.Pipeline.TaskRunner
    resource HierarchyPai.Pipeline.Discovery
  end
end
