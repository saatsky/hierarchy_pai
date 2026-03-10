defmodule HierarchyPai.Pipeline.Discovery do
  @moduledoc """
  Ash Resource exposing discovery actions as MCP tools.

  Allows MCP clients to enumerate available specialist agents and skills
  before deciding how to use run_task or plan_task.
  """

  use Ash.Resource, domain: HierarchyPai.Pipeline

  alias HierarchyPai.Agents.AgentRegistry
  alias HierarchyPai.SkillStore

  actions do
    action :list_specialists, :string do
      description """
      List all available specialist agents in this hierarchy_pai instance.

      Returns a JSON array of specialists with their id, name, and description.
      Use the specialist `id` values as hints when calling `run_task` or `plan_task`
      if you want to guide which specialists are assigned to which steps.
      """

      run fn _input, _context ->
        specialists =
          AgentRegistry.agents()
          |> Enum.map(fn {name, id, icon} ->
            %{id: id, name: "#{icon} #{name}"}
          end)

        {:ok, Jason.encode!(%{specialists: specialists, count: length(specialists)})}
      end
    end

    action :list_skills, :string do
      description """
      List all loaded skills available in this hierarchy_pai instance.

      Skills are domain-specific methodology prompts (e.g. press-release, jobs-to-be-done)
      that can be applied to specialist steps to refine the output format and approach.
      Skills are defined in SKILL.md files under priv/skills/.

      Returns a JSON array of skills with their id, name, type, and description.
      """

      run fn _input, _context ->
        skills =
          SkillStore.list()
          |> Enum.map(fn skill ->
            %{
              id: skill.id,
              name: skill.name,
              type: skill.type,
              description: skill.description
            }
          end)

        {:ok, Jason.encode!(%{skills: skills, count: length(skills)})}
      end
    end
  end
end
