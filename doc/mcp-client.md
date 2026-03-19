# MCP Client — Connecting External Tools to Steps

Hierarchical Planner AI can connect to external **MCP (Model Context Protocol) servers** and expose their tools directly to individual plan steps. This lets an executor step call real APIs, databases, or services — not just generate text.

> **MCP Server vs MCP Client**: The app also _exposes_ its own planning pipeline as an MCP server at `POST /mcp` (see [priv/TOOLS.md](../priv/TOOLS.md)). This document covers the _client_ side — consuming tools from **external** MCP servers inside executor steps.

---

## How It Works

1. You register one or more external MCP servers in the **MCP Servers** sidebar panel
2. The app connects to each server and fetches its tool list
3. During plan review, you attach a server to a step using the **MCP Servers** selector on that step's card
4. At execution time, the Executor makes the server's tools available to the LLM as callable functions
5. The LLM decides which tool(s) to call and with what arguments; the Executor proxies the calls and returns the results

---

## The MCP Servers Panel

The **MCP Servers** panel lives in the left sidebar. Expand it with the chevron.

### Adding a server

1. Click **+** (plus icon) in the panel header
2. Fill in:
   - **Name** — a human-readable label (e.g. `Collaboration`, `Brave Search`)
   - **URL** — the HTTP endpoint, e.g. `http://localhost:9000/mcp`
3. Click **Save**

### Connecting a server

After saving, click the **⚡ Connect** (bolt) button next to the server. The app:
1. Sends an MCP `initialize` handshake to the server
2. Calls `tools/list` to fetch all available tools
3. Shows a green indicator and the tool count (e.g. `4 tools`)

| Status | Indicator | Meaning |
|---|---|---|
| Disconnected | Grey dot | Saved but not yet connected |
| Checking | Amber pulsing dot | Handshake in progress |
| Connected | Green dot | Tools loaded and ready |
| Error | Red dot | Connection failed — hover for reason |

### Disconnecting

Click **✕** on a connected server to disconnect. The tool list is cleared but the server entry is kept.

### Editing / Deleting

Use the **✏️ Edit** (pencil) and **🗑 Delete** (trash) icons on each server row.

---

## Attaching a Server to a Step

During **Plan Review**, each step card has an **MCP Servers** section. Check the checkbox next to any connected server to attach it to that step.

Multiple servers can be attached to the same step — the Executor will receive tools from all of them.

Steps that have no MCP server attached run as pure LLM steps (no tool-calling).

---

## Execution: What the LLM Sees

When a step runs with MCP servers attached, the Executor:

1. Loads the tool definitions from connected servers into the LangChain tool list
2. Sends the step's instruction + context to the LLM with the tool schemas
3. The LLM may call one or more tools (e.g. `GetMySquadTasks`)
4. The Executor proxies each call to the MCP server via HTTP and returns the result to the LLM
5. The LLM continues reasoning with the tool output and produces the step's final answer

### Token overflow protection

MCP tool responses can be very large (e.g. a full task list). The Executor automatically truncates any single tool response to **4 000 characters** before returning it to the LLM. A `...[response truncated]` notice is appended so the model knows data was cut.

To avoid truncation entirely, configure your MCP tool to return only the fields you need (e.g. use `fields: ["ID", "Title", "Status"]` in the tool call arguments).

---

## Collaboration MCP Server Example

The `collaboration-tasks` skill is designed to work with a DataMiner Collaboration MCP server exposing these tools:

| Tool | Purpose |
|---|---|
| `GetMyTasks` | Retrieve tasks assigned to the current user |
| `GetProjectTasks` | Retrieve tasks for a specific project |
| `GetMySquadTasks` | Retrieve tasks for the user's squad/team |
| `GetTaskDetails` | Retrieve full details for a single task by ID |

**Setup:**

1. Register the Collaboration server in the MCP Servers panel (name: `Collaboration`, URL: your server URL)
2. Click **Connect** — you should see `4 tools`
3. When running a task like _"List my squad's In Progress tasks"_, the Planner will:
   - Generate a step and automatically assign `skill_id: "collaboration-tasks"`
   - You attach the `Collaboration` server to that step in the review phase
4. The Executor calls `GetMySquadTasks` with `onlySquadMemberTasks: true` and the appropriate field filters

---

## Plans and MCP Server Names

When you **save or download** a plan, MCP server assignments are stored as **server names** (e.g. `"Collaboration"`) rather than internal IDs. This means:

- Plans are portable — IDs change on every server restart, names don't
- When a plan is uploaded on another machine, servers are re-linked by name automatically
- If no server with that name exists, the assignment is silently skipped (the step runs as a plain LLM step)

See [Saving & Uploading Plans](plans.md) for the full plan portability workflow.

---

## Troubleshooting MCP Connections

### Server shows as Error

- Check the URL — it must be a valid HTTP endpoint (e.g. `http://localhost:9000/mcp`)
- Confirm the MCP server process is running
- Check CORS if the server is on a different host
- On Windows: use `localhost` or `127.0.0.1`, not `0.0.0.0` as a destination (see note below)

> **`0.0.0.0` as destination on Windows**: `0.0.0.0` is a valid _bind_ address but not a valid _destination_ on Windows. If your MCP server is advertised as `http://0.0.0.0:PORT`, replace it with `http://localhost:PORT` in the MCP Servers panel.

### Tool calls return `"Not Found"` or similar errors

- The MCP server may require the model to be **started/loaded** before it routes requests (common with Jan.ai and similar local servers)
- Inspect the MCP server logs for unhandled routes
- Confirm the tool name used in the LLM call matches the tool name returned by `tools/list`

### Large responses cause `Request body too large`

The Executor caps tool responses at 4 000 characters. If the error still appears:

1. Assign the appropriate skill (e.g. `collaboration-tasks`) to the step so the LLM uses field filtering in its tool call arguments
2. If the skill is already assigned, check whether the skill prompt instructs field filtering (it should include `"fields": [...]` in the tool argument schema)
3. As a last resort, reduce the data returned by the MCP server itself

### MCP server disconnects after plan reload

MCP server connections are live session state — they are not persisted. After reloading a saved or uploaded plan, reconnect the servers using the **⚡ Connect** button in the MCP Servers panel before running execution.

---

## Agent-Triggered User Input

Every executor step has a built-in `request_user_input` tool available to the LLM alongside any MCP tools. The agent can call this tool at any point during execution when it determines it needs clarification or specific information that is not available in the context.

### How it works

1. The LLM decides it needs user input and calls `request_user_input` with a `question` string
2. Execution **pauses** — the step card moves from the Running column to the **Waiting** column (amber)
3. The question is displayed on the step card with a textarea and a **Submit** button
4. You type your answer and click **Submit**
5. The answer is returned into the LLM chain as a tool result
6. The LLM continues reasoning with your answer and produces the step output

### What it looks like

Waiting column card:
- Amber border and pulsing amber dot in the column header
- The agent's exact question is shown above the input area
- A textarea and **Submit** button
- Multiple steps can be waiting simultaneously — each has its own independent form

### When the agent asks for input

The `request_user_input` tool is described to the LLM as something to use **sparingly** — only when information is truly necessary and cannot be inferred from context. In practice it fires for:

- Personalisation that only the user knows (names, team, project, environment)
- Binary choices that affect the entire output direction
- Credentials or configuration the planner couldn't know at plan time
- Ambiguous instructions where the wrong assumption would waste the full step

### 5-minute timeout

If no answer is submitted within **5 minutes**, the tool returns `"(no answer — user did not respond within 5 minutes)"` and execution continues. The LLM will proceed with that notice in its context and make its best attempt to complete the step anyway.

### Triggering user input from a Skill

Skill files (`SKILL.md`) can instruct the agent to use `request_user_input` for specific situations. For example, a skill for personalised documents can begin with:

```markdown
Before drafting any content, use the request_user_input tool to ask:
"What is the recipient's name, role, and the key context I should tailor this document to?"
```

This makes user input a systematic part of the skill's methodology rather than an ad-hoc decision by the LLM.
