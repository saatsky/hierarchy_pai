# TOOLS.md — hierarchy_pai MCP Server (ash_ai)

hierarchy_pai exposes a **multi-agent planning and execution pipeline** as an MCP server.
Any MCP-compatible client (Jan.ai, VS Code, Claude Desktop, etc.) can call these tools to
delegate complex tasks that require structured decomposition, parallel specialist execution,
and synthesised answers.

## Endpoint

```
POST http://localhost:4000/mcp
```

Standard MCP JSON-RPC 2.0 over HTTP (streamable). Protocol version: `2024-11-05`.

---

## Tools

| Tool | Purpose |
|------|---------|
| `run_task` | Full pipeline: plan → execute → synthesise answer |
| `plan_task` | Planning phase only — returns plan JSON |
| `execute_plan` | Execute a pre-built plan JSON |
| `list_specialists` | Discover available specialist agents |
| `list_skills` | Discover loaded SKILL.md skills |

---

## `run_task`

Run the full hierarchy_pai pipeline end-to-end.

Decomposes `task` into parallel specialist steps using the Planner LLM, executes each
concurrently with the appropriate specialist agent, and returns a synthesised final answer.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `task` | string | ✅ | The task or question to plan and execute |
| `provider` | string | ❌ | Saved provider name or ID from the hierarchy_pai UI. Defaults to first saved provider |

### Response (JSON string)

```json
{
  "run_id": "a3f8c1d2",
  "answer": "## Final synthesised answer...",
  "steps": [
    { "id": "step-1", "output": "Step output text..." },
    { "id": "step-2", "output": "Step output text..." }
  ]
}
```

On error:
```json
{ "run_id": "a3f8c1d2", "error": "No provider found. Please add a provider at http://localhost:4000" }
```

---

## `plan_task`

Generate a structured execution plan without running it. Use this to inspect or review
the plan before committing to execution via `execute_plan`.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `task` | string | ✅ | The task to plan |
| `provider` | string | ❌ | Saved provider name or ID |

### Response (JSON string)

```json
{
  "goal": "The high-level goal",
  "steps": [
    {
      "id": "step-1",
      "title": "Step title",
      "description": "What this step does",
      "agent": "content_creator",
      "depends_on": []
    }
  ]
}
```

---

## `execute_plan`

Execute a pre-built plan produced by `plan_task`. Pass the JSON string from `plan_task`
as the `plan` argument.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `task` | string | ✅ | Original task description (for run tracking) |
| `plan` | string | ✅ | Plan JSON string as returned by `plan_task` |
| `provider` | string | ❌ | Saved provider name or ID |

### Response (JSON string)

Same shape as `run_task` response (`run_id`, `answer`, `steps`).

---

## `list_specialists`

List all available specialist agents.

### Arguments

None.

### Response (JSON string)

```json
{
  "count": 12,
  "specialists": [
    { "id": "executor", "name": "⚡ General Executor" },
    { "id": "backend_architect", "name": "🏗️ Backend Architect" },
    { "id": "frontend_developer", "name": "🎨 Frontend Developer" },
    { "id": "ai_engineer", "name": "🤖 AI Engineer" },
    { "id": "devops_automator", "name": "🚀 DevOps Automator" },
    { "id": "rapid_prototyper", "name": "⚡ Rapid Prototyper" },
    { "id": "content_creator", "name": "📝 Content Creator" },
    { "id": "trend_researcher", "name": "🔍 Trend Researcher" },
    { "id": "feedback_synthesizer", "name": "💬 Feedback Synthesizer" },
    { "id": "data_analytics", "name": "📊 Data Analytics" },
    { "id": "sprint_prioritizer", "name": "🎯 Sprint Prioritizer" },
    { "id": "growth_hacker", "name": "📈 Growth Hacker" }
  ]
}
```

---

## `list_skills`

List all loaded SKILL.md skills.

### Arguments

None.

### Response (JSON string)

```json
{
  "count": 4,
  "skills": [
    { "id": "press-release", "name": "Press Release", "type": "content", "description": "Amazon-style PR..." },
    { "id": "discovery-process", "name": "Discovery Process", "type": "research", "description": "..." },
    { "id": "jobs-to-be-done", "name": "Jobs To Be Done", "type": "research", "description": "..." },
    { "id": "epic-breakdown", "name": "Epic Breakdown", "type": "engineering", "description": "..." }
  ]
}
```

---

## Implementation Notes

This MCP server is implemented using **ash_ai** (`AshAi.Mcp.Router` + Ash Domain + generic actions).
The transport is a standard `Plug.Router` — no GenServer, no timeout issues.

Tools are auto-discovered from the `HierarchyPai.Pipeline` Ash Domain registered in
`config :hierarchy_pai, ash_domains: [HierarchyPai.Pipeline]`.

Before calling `run_task` or `plan_task`, ensure at least one LLM provider is configured
in the hierarchy_pai UI at `http://localhost:4000`.

