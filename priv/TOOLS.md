
# TOOLS.md — hierarchy_pai MCP Interface (Agent‑Centric, Extensible)

This MCP server exposes a **multi‑agent**, **multi‑skill**, **pipeline‑driven** reasoning engine used for backlog scoring, prioritization, semantic analysis, risk modeling, and extensible AI workflows.

It supports:
- Agent discovery (`list_agents`)
- Skill discovery (`list_skills`)
- Skill metadata inspection (`describe_skill`)
- Dynamic multi‑step pipelines (`execute_task`)
- Pipeline introspection (`inspect_pipeline`)
- Natural‑language explanations (`explain_pipeline`)

This file specifies the **public API contract** between Jan.ai (or any MCP client) and `hierarchy_pai`.

---
# 1. API OVERVIEW

`hierarchy_pai` exposes **one generic task execution engine** and several discovery/introspection tools.

### Available MCP Tools
| Tool Name | Purpose |
|----------|---------|
| `list_agents` | Discover available reasoning agents |
| `list_skills` | Discover available skills and the agent(s) that implement them |
| `describe_skill` | Retrieve schema & parameters for a given skill |
| `execute_task` | Execute a full multi‑step pipeline |
| `inspect_pipeline` | Validate & inspect pipeline steps without executing |
| `explain_pipeline` | Provide natural‑language reasoning for chosen pipeline |

---
# 2. TOOL: `list_agents`

### Description
Returns the list of internal agents available inside hierarchy_pai.

### Response Schema
```json
{
  "agents": [
    {
      "id": "planner-agent",
      "description": "General planning, reasoning, workflow composition."
    },
    {
      "id": "backlog-analyzer",
      "description": "Backlog scoring, grooming, PBS, DoR, triage."
    },
    {
      "id": "semantic-model",
      "description": "Clustering, duplicate detection, embeddings."
    },
    {
      "id": "risk-model-agent",
      "description": "Risk scoring, impact estimation, risk heatmaps."
    },
    {
      "id": "estimation-agent",
      "description": "Effort estimation and sizing."
    },
    {
      "id": "prioritization-agent",
      "description": "WSJF, RICE, MoSCoW, sort & filter."
    }
  ]
}
```

---
# 3. TOOL: `list_skills`

### Description
Returns all skills and which agents support them.

### Response Schema
```json
{
  "skills": [
    { "name": "pbs_score", "agents": ["backlog-analyzer"], "params": {"weights": "object", "round_to": "number"}},
    { "name": "definition_of_ready", "agents": ["backlog-analyzer"], "params": {"checklist": "array"}},
    { "name": "wsjf", "agents": ["prioritization-agent"], "params": {"use_inferred_cost_of_delay": "boolean"}},
    { "name": "cluster_semantic", "agents": ["semantic-model"], "params": {"k": "number"}},
    { "name": "detect_duplicates", "agents": ["semantic-model"], "params": {}},
    { "name": "estimate_effort", "agents": ["estimation-agent"], "params": {}},
    { "name": "risk_heatmap", "agents": ["risk-model-agent"], "params": {}},
    { "name": "sort", "agents": ["prioritization-agent"], "params": {"by": "string", "direction": "string"}},
    { "name": "filter", "agents": ["prioritization-agent"], "params": {"field": "string", "value": "string"}},
    { "name": "summarize_backlog", "agents": ["planner-agent"], "params": {} }
  ]
}
```

---
# 4. TOOL: `describe_skill`

### Description
Returns detailed metadata about a skill: parameter schema, expected inputs, expected outputs.

### Request Example
```json
{ "skill": "pbs_score" }
```

### Response Example
```json
{
  "skill": "pbs_score",
  "description": "Compute Product Backlog Score using weighted, normalized formula.",
  "input_schema": {
    "tasks": "array"
  },
  "output_schema": {
    "tasks": "array"
  },
  "params": {
    "weights": {
      "business_value": "number",
      "urgency": "number",
      "strategic_alignment": "number",
      "effort": "number",
      "risk": "number",
      "dependencies": "number"
    },
    "round_to": "number"
  },
  "version": "1.1"
}
```

---
# 5. TOOL: `execute_task`

### Description
Executes a **pipeline** consisting of multiple steps.
Each step specifies:
- agent
- skill
- params

The system maintains a **shared context** across steps (typically including `tasks`).

### Request Schema
```jsonc
{
  "task_type": "pipeline",
  "version": "1.0",
  "pipeline": [
    {
      "agent": "backlog-analyzer",
      "skill": "pbs_score",
      "params": {
        "weights": {
          "business_value": 0.30,
          "urgency": 0.20,
          "strategic_alignment": 0.15,
          "effort": 0.15,
          "risk": 0.10,
          "dependencies": 0.10
        },
        "round_to": 2
      }
    },
    {
      "agent": "backlog-analyzer",
      "skill": "definition_of_ready",
      "params": { "checklist": ["title", "acceptance_criteria", "estimation"] }
    },
    {
      "agent": "semantic-model",
      "skill": "cluster_semantic",
      "params": { "k": 10 }
    },
    {
      "agent": "prioritization-agent",
      "skill": "sort",
      "params": { "by": "pbs_score", "direction": "desc" }
    }
  ],
  "inputs": {
    "tasks": []
  },
  "explain": true,
  "trace": true,
  "strict": false
}
```

### Output Schema
```json
{
  "status": "ok",
  "results": {
    "tasks": []
  },
  "trace": [],
  "explanations": [],
  "version": "1.0"
}
```

---
# 6. TOOL: `inspect_pipeline`

Returns a validation of a pipeline without running it.

### Example
```json
{
  "valid": true,
  "steps": [
    { "skill": "pbs_score", "agent": "backlog-analyzer", "status": "ok" },
    { "skill": "definition_of_ready", "agent": "backlog-analyzer", "status": "ok" }
  ]
}
```

---
# 7. TOOL: `explain_pipeline`

### Example Output
```json
{
  "explanations": [
    "pbs_score chosen for priority scoring using weighted model.",
    "definition_of_ready ensures tasks are actionable.",
    "cluster_semantic groups similar tasks for deduplication.",
    "sort orders tasks by descending PBS."
  ]
}
```

---
# 8. Error Model

```json
{
  "status": "error",
  "error": {
    "code": "invalid_schema",
    "message": "Pipeline parameter "k" must be >= 1"
  },
  "trace_id": "req-123"
}
```

---
# 9. Versioning

- All requests must specify a version
- Skills may be versioned individually: `pbs_score@1.1`
- Pipeline execution engine evolves independently of skills

---
# END OF TOOLS.md
