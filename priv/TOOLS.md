# TOOLS.md — hierarchy_pai MCP Server

hierarchy_pai exposes its full multi-agent planning and execution pipeline as an
**MCP (Model Context Protocol) server**. Any MCP-compatible client — Jan.ai, VS Code Copilot,
Claude Desktop, Cursor — can delegate complex tasks to this server: the pipeline decomposes them
into parallel specialist steps, executes them concurrently, and returns a synthesised answer.

---

## Endpoint

| Transport | URL |
|-----------|-----|
| Streamable HTTP (POST) | `http://localhost:4000/mcp` |

Protocol version: **`2024-11-05`** (MCP JSON-RPC 2.0).

> **Docker:** replace `localhost:4000` with `host.docker.internal:4000` if calling from inside a
> container.

---

## Prerequisites

Before calling any tool, ensure at least one LLM provider is saved in the hierarchy_pai UI at
`http://localhost:4000`. The `provider` argument in each tool accepts either the **display name**
or the **opaque ID** shown in the Providers panel (e.g. `"jan-mistral"` or the UUID string). If
omitted, the first saved provider is used automatically.

---

## Available Tools

| Tool | Phase | Description |
|------|-------|-------------|
| [`run_task`](#run_task) | Full pipeline | Plan → execute → synthesised answer in one call |
| [`plan_task`](#plan_task) | Plan only | Generate a plan for review; execute later with `execute_plan` |
| [`execute_plan`](#execute_plan) | Execute only | Run a plan produced by `plan_task` |
| [`list_specialists`](#list_specialists) | Discovery | List the 12 specialist agent types |
| [`list_skills`](#list_skills) | Discovery | List loaded SKILL.md methodology packs |

---

## `run_task`

Run the full pipeline end-to-end: the Planner LLM decomposes the task into 3–8
dependency-aware steps, assigns a specialist agent to each, executes them in parallel waves,
and synthesises a final answer via the Aggregator LLM.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `task` | string | ✅ | The task or question to plan and execute. Be specific — more context produces better decomposition. |
| `provider` | string | ❌ | Saved provider display name or ID from the hierarchy_pai UI. Defaults to the first saved provider. |

### Response

```json
{
  "run_id": "a3f8c1d2e4b56789",
  "answer": "## Final synthesised answer\n\nAll steps completed...",
  "steps": [
    { "id": 1, "output": "Output from step 1..." },
    { "id": 2, "output": "Output from step 2..." }
  ]
}
```

On error (always `200 OK`, error embedded in result):

```json
{ "run_id": "a3f8c1d2e4b56789", "error": "Rate limited by provider (HTTP 429)..." }
```

### Timeout

`run_task` waits up to **5 minutes** for the full pipeline. Long tasks with many steps or slow
local models (Jan.ai) may approach this limit. For fine-grained control, use `plan_task` +
`execute_plan` separately.

---

## `plan_task`

Generate a structured execution plan **without running it**. Inspect or modify the plan, then
pass it directly to `execute_plan`.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `task` | string | ✅ | The task to decompose into a plan. |
| `provider` | string | ❌ | Saved provider display name or ID. Defaults to the first saved provider. |

### Response

```json
{
  "goal": "Concise restatement of the task",
  "assumptions": ["Any assumption the planner made"],
  "steps": [
    {
      "id": 1,
      "title": "Short step title",
      "instruction": "Detailed instruction for this step",
      "tool": "llm",
      "agent_type": "backend_architect",
      "expected_output": "What this step should produce",
      "depends_on": []
    },
    {
      "id": 2,
      "title": "Another step",
      "instruction": "...",
      "tool": "llm",
      "agent_type": "content_creator",
      "expected_output": "...",
      "depends_on": [1]
    }
  ]
}
```

**Step fields:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | integer | Unique step identifier within this plan |
| `title` | string | Short human-readable step name |
| `instruction` | string | Detailed prompt sent to the specialist agent |
| `tool` | string | Always `"llm"` (future-proofed for other tool types) |
| `agent_type` | string | Specialist ID — see [`list_specialists`](#list_specialists) |
| `expected_output` | string | What the step should produce (guides the agent) |
| `depends_on` | integer[] | IDs of steps that must complete before this one runs |

On error:

```json
{ "error": "Planner LLM error: ..." }
```

---

## `execute_plan`

Execute a plan produced by `plan_task`. Pass the **plan object** (not a JSON string) directly as
the `plan` argument.

### Arguments

| Name | Type | Required | Description |
|------|------|----------|-------------|
| `task` | string | ✅ | Original task description — used for run tracking and the Aggregator's context. |
| `plan` | object | ✅ | The plan object as returned by `plan_task` (with `goal` and `steps` fields). MCP clients automatically pass objects — do not re-encode as a string. |
| `provider` | string | ❌ | Saved provider display name or ID. Defaults to the first saved provider. |

### Response

Same shape as `run_task`:

```json
{
  "run_id": "b7c49a1f...",
  "answer": "## Final synthesised answer...",
  "steps": [
    { "id": 1, "output": "..." },
    { "id": 2, "output": "..." }
  ]
}
```

On error:

```json
{ "run_id": "b7c49a1f...", "error": "Executor LLM error: ..." }
```

### Two-step workflow (recommended for large tasks)

```
1. plan  = plan_task(task="...", provider="my-provider")
2. review plan.steps — check agent assignments, instruction quality
3. result = execute_plan(task="...", plan=plan, provider="my-provider")
```

This lets you inspect and optionally correct the decomposition before committing LLM calls.

---

## `list_specialists`

Discover the available specialist agent types. Use the `id` values when reviewing a plan
produced by `plan_task` — you can supply them as hints in your task description to influence
agent assignment (e.g. *"use the growth_hacker for the GTM step"*).

### Arguments

None.

### Response

```json
{
  "count": 12,
  "specialists": [
    { "id": "executor",             "name": "⚡ General Executor" },
    { "id": "backend_architect",    "name": "🏗️ Backend Architect" },
    { "id": "frontend_developer",   "name": "🎨 Frontend Developer" },
    { "id": "ai_engineer",          "name": "🤖 AI Engineer" },
    { "id": "devops_automator",     "name": "🚀 DevOps Automator" },
    { "id": "rapid_prototyper",     "name": "⚡ Rapid Prototyper" },
    { "id": "content_creator",      "name": "📝 Content Creator" },
    { "id": "trend_researcher",     "name": "🔍 Trend Researcher" },
    { "id": "feedback_synthesizer", "name": "💬 Feedback Synthesizer" },
    { "id": "data_analytics",       "name": "📊 Data Analytics" },
    { "id": "sprint_prioritizer",   "name": "🎯 Sprint Prioritizer" },
    { "id": "growth_hacker",        "name": "📈 Growth Hacker" }
  ]
}
```

---

## `list_skills`

Discover loaded SKILL.md methodology packs. Skills override a specialist's default system
prompt with a specific methodology (e.g. Press Release, Jobs-to-be-Done). Skill names can be
mentioned in the `task` description to have the Planner assign them to relevant steps.

### Arguments

None.

### Response

```json
{
  "count": 6,
  "skills": [
    { "id": "press-release",      "name": "Press Release",       "type": "content",     "description": "Amazon-style working-backwards PR/FAQ format..." },
    { "id": "discovery-process",  "name": "Discovery Process",   "type": "research",    "description": "Structured discovery interviews and synthesis..." },
    { "id": "jobs-to-be-done",    "name": "Jobs To Be Done",     "type": "research",    "description": "JTBD framework for understanding user motivations..." },
    { "id": "epic-breakdown",     "name": "Epic Breakdown",      "type": "engineering", "description": "Decompose epics into user stories with acceptance criteria..." },
    { "id": "dor-check",          "name": "Definition of Ready", "type": "engineering", "description": "Checklist validation before a story enters a sprint..." },
    { "id": "pbs-score",          "name": "PBS Score",           "type": "research",    "description": "Product–Business–Strategy alignment scoring..." }
  ]
}
```

> Skill count reflects `priv/skills/` on the running instance. New skills added at runtime
> appear immediately via [`list_skills`](#list_skills).

---

## Client Setup

### Jan.ai

1. Open **Jan.ai → Settings → MCP Servers → Add**
2. Set **Name**: `hierarchy_pai`
3. Set **Transport**: `Streamable HTTP`
4. Set **URL**: `http://localhost:1337` ← your Jan.ai endpoint *(leave as-is)*
5. Add a **new server** for hierarchy_pai:
   - **URL**: `http://localhost:4000/mcp`
   - **Transport**: `Streamable HTTP`
6. Save and enable the server. All 5 tools will appear in Jan.ai's tool list.

### VS Code (GitHub Copilot / Copilot Chat)

Create `.vscode/mcp.json` in your workspace (or add to User settings):

```json
{
  "servers": {
    "hierarchy_pai": {
      "type": "http",
      "url": "http://localhost:4000/mcp"
    }
  }
}
```

Restart VS Code or run **MCP: Restart Server**. The tools appear in Copilot Chat's tool picker.

### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or
`%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "hierarchy_pai": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://localhost:4000/mcp"]
    }
  }
}
```

> Claude Desktop uses stdio transport by default; `mcp-remote` bridges it to HTTP.

### Cursor / Other HTTP clients

Set the MCP server URL to `http://localhost:4000/mcp` with transport type `HTTP` or
`Streamable HTTP`. No authentication required.

---

## Error Handling

All tools always return **HTTP 200** with a JSON result. Errors are embedded in the response
rather than using HTTP error codes (per MCP spec's `isError` field convention).

| `error` value | Cause | Fix |
|---------------|-------|-----|
| `"No provider found..."` | No LLM provider saved | Add a provider at `http://localhost:4000` |
| `"Rate limited by provider (HTTP 429)..."` | Provider rate limit hit | Wait and retry, or switch to a higher-tier model |
| `"Planner LLM error: ..."` | Planning phase failed | Check provider connectivity; try a larger model |
| `"Planning timed out after 300000ms"` | Plan took > 5 min | Use a faster/local model or shorten the task |
| `"Executor LLM error: ..."` | A step execution failed | See `run_id` in the UI for details |

---

## Rate Limit Guidance

The execution engine runs a maximum of **2 steps concurrently** (`max_concurrency: 2`) to
avoid overwhelming rate-limited providers. For cloud providers with strict RPM limits:

- Prefer `plan_task` + `execute_plan` over `run_task` so you can inspect step count first
- Use a local Jan.ai model (no rate limits) for high-step tasks
- The UI (`http://localhost:4000`) gives finer control: retry individual steps or skip failed ones

---

## Developer / Debug Endpoints

These endpoints are available **only in `dev` environment** (not production/Docker):

| Endpoint | Description |
|----------|-------------|
| `POST /ash_ai/mcp` | ash_ai built-in dev tools (Ash resource introspection) |
| `POST /tidewave/mcp` | Tidewave code evaluation tools (live Elixir eval in the app process) |

---

## Implementation Notes

- Built with **ash_ai** (`AshAi.Mcp.Router` + Ash Domain generic actions + Plug transport)
- Transport is a standard `Plug.Router` — no GenServer, no socket state, no timeout issues from the transport layer
- All tools return Elixir maps (`:map` type); ash_ai JSON-encodes them once → clean single-encoded JSON in `content[].text`
- Errors are always `{:ok, %{error: reason}}` — never `{:error, ...}` — to prevent ash_ai from raising and converting them to JSON-RPC `-32000` protocol errors
- A custom proxy (`HierarchyPaiWeb.Plugs.MCPRouter`) normalises flat MCP client arguments under the `"input"` key that ash_ai expects, and flattens `inputSchema` in `tools/list` responses for client compatibility
- Tool definitions auto-discovered from the `HierarchyPai.Pipeline` Ash Domain (configured in `config :hierarchy_pai, ash_domains: [HierarchyPai.Pipeline]`)

