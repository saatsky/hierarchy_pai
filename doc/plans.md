# Saving, Downloading & Uploading Plans

Hierarchical Planner AI lets you **persist any generated plan** so you can reuse, share, or version it outside the app. Plans are portable JSON files that carry everything needed to reload and re-run the workflow on any instance.

---

## What Is a Plan?

A plan is the structured output produced by the Planner agent. It contains:

- A `goal` — the Planner's restatement of your task
- `assumptions` — any assumptions the Planner made
- `steps` — each step with its title, instruction, specialist agent type, skill, MCP server assignments, and dependencies
- `name` and `task` — the display name and original user-facing task text
- `provider` — informational record of which LLM was used to generate the plan (name, type, model)

---

## Saving a Plan

After the Planner generates a plan and the **Review Plan** screen appears:

1. Click the **Save** (bookmark) icon in the plan toolbar
2. A dialog appears — type a name for the plan
3. Click **Save**

The plan is saved to the **Saved Plans** panel in the sidebar with your chosen name and the original task as a subtitle.

> **Note:** Plans are stored in-memory (ETS). They survive LiveView crashes but are cleared on server restart. Use **Download** for durable storage.

### What gets saved

The plan snapshot captures all UI-level assignments made during review:

| Field | Description |
|---|---|
| `agent_type` | The specialist assigned to each step (Planner choice or your override) |
| `skill_id` | The skill assigned to each step (if any) |
| `mcp_server_names` | MCP servers attached to each step, stored by **name** (not ephemeral ID) |
| `name` | The name you entered in the save dialog |
| `task` | The original task text |
| `provider` | LLM used to generate the plan (informational only; no API keys stored) |

---

## The Saved Plans Panel

The **Saved Plans** panel appears in the left sidebar under **MCP Servers** and **Agent Specialists**. Click the chevron to expand it.

Each row shows:
- **Plan name** (truncated)
- **Task text** (truncated; hover to see full text)
- **▶ Load** — loads the plan into the Planner, restoring all step assignments
- **🗑 Delete** — removes the plan (asks for confirmation)

---

## Downloading a Plan

Click the **↓ Download** button in the plan toolbar to export the current plan as a JSON file. The file is named after the plan goal (e.g. `plan-Retrieve-squad-In-Progress.json`).

The downloaded JSON is self-contained:

```json
{
  "name": "Squad In-Progress Tasks",
  "task": "List my squad's In Progress tasks and summarise them",
  "provider": {
    "name": "Local Jan.ai",
    "type": "jan_ai",
    "model": "llama3.2-3b-instruct"
  },
  "goal": "Retrieve and display all In Progress tasks for the squad",
  "assumptions": ["The user has access to the Collaboration MCP server"],
  "steps": [
    {
      "id": 1,
      "title": "Fetch squad tasks",
      "instruction": "Call GetMySquadTasks with onlySquadMemberTasks: true ...",
      "tool": "llm",
      "agent_type": "executor",
      "skill_id": "collaboration-tasks",
      "mcp_server_names": ["Collaboration"],
      "expected_output": "JSON list of tasks with Status = In Progress",
      "depends_on": []
    }
  ]
}
```

### Key fields in the downloaded plan

| Field | Notes |
|---|---|
| `mcp_server_names` | Human-readable server names; resolved back to live IDs on upload |
| `skill_id` | Skill directory name (e.g. `"collaboration-tasks"`); matched against loaded skills |
| `provider` | Informational only — no API key, endpoint, or credentials included |

---

## Uploading a Plan

Click the **↑ Upload** (arrow-up) icon next to the Saved Plans panel title, or use the upload icon that appears in the sidebar, to load a plan from a JSON file.

### What happens on upload

1. The JSON is validated — must have `"goal"` and `"steps"` keys
2. If the plan contains a `"name"` field, it is **automatically saved to the Saved Plans panel** — no re-entry needed
3. The original `"task"` text is restored in the planner input field
4. `mcp_server_names` are resolved to the current live MCP server IDs by matching names — servers you have connected will be re-linked automatically
5. `skill_id` values are matched against loaded skills — unrecognised IDs are silently ignored
6. The plan opens in Review mode immediately, ready to execute

### Backward compatibility

Plans downloaded before the `mcp_server_names` field was introduced (older format using `mcp_server_ids`) are still accepted. The app falls back to loading those raw IDs if `mcp_server_names` is absent.

---

## Workflow: Share a Plan with a Colleague

1. Configure the plan in the UI (assign specialists, skills, MCP servers)
2. Click **Download** to export the JSON
3. Share the JSON file
4. The colleague opens the app, registers the same MCP server (same **name**), then clicks **Upload**
5. The plan loads with all assignments intact and MCP servers re-linked

---

## Workflow: Version Control for Plans

Because plans are plain JSON, they can be committed to Git:

```bash
# Save plans in a tracked directory
mkdir -p plans/
# After downloading, move the file
mv ~/Downloads/plan-*.json plans/

git add plans/
git commit -m "Add squad-tasks plan"
```

To reload: open the app, click **Upload**, select the file.

---

## Auto-assignment of Skills by the Planner

When the Planner generates a new plan, it automatically receives a list of all loaded skills and their descriptions. It sets the `skill_id` field on each step to the most appropriate skill (or `null` if none fits).

For example, if the `collaboration-tasks` skill is loaded, any step that involves querying DataMiner Collaboration tasks will receive `"skill_id": "collaboration-tasks"` in the generated plan — so the right system prompt is used automatically at execution time without manual assignment.

You can still override any auto-assigned skill in the Review Plan step cards.
