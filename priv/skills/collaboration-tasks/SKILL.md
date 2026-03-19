---
name: collaboration-tasks
description: >
  Query DataMiner Collaboration tasks via the MCP "Collaboration" server
  (GetMyTasks, GetProjectTasks, GetTaskDetails, GetMySquadTasks) and return
  a filtered JSON payload suitable for downstream steps in an automated workflow.
version: 0.1.0
author: saatsky
tags:
  - dataminer
  - collaboration
  - tasks
  - mcp
  - workflow
  - json-output
---

## Skill overview

This skill teaches the agent how to use the **DataMiner Collaboration MCP server**
to retrieve task information in a consistent, workflow-friendly way.

The agent will:

1. Interpret the user's request about tasks (e.g., _my tasks_, _squad tasks_,
   _tasks for a project_, _details for task X_).
2. Choose the appropriate MCP tool from the **Collaboration** server:
   - `GetMyTasks`
   - `GetProjectTasks`
   - `GetTaskDetails`
   - `GetMySquadTasks`
3. Apply **sensible defaults** for filters:
   - `excludedStatuses`: `["Closed", "Rejected", "Completed"]`  
     unless the user explicitly asks for those statuses.
   - For squad queries, `GetMySquadTasks` can be called with `"onlySquadMemberTasks": true`.
4. Request only the necessary task fields to keep responses compact and easy to post-process. Supported filterable fields include (case-sensitive):
   - `"ID"`, `"Title"`, `"Status"`, `"Assignee"`, `"Category"`, `"Customer"`, `"Estimation"`, `"Project Type"`, `"SLA Priority"`, `"Type"`
5. Return a **strict JSON object** (no extra text, comments, or Markdown)
   containing:
   - Which tool was used
   - Which filters/parameters were applied
   - A list of tasks, each reduced to exactly the requested fields

The JSON output is designed to be **directly consumed by a next step** in a
multi-step workflow (e.g., summarization, reporting, notifications, or further
automation).

---

## When to use this skill

Use this skill whenever the user:

- Wants to **see or process tasks** stored in DataMiner Collaboration, such as:
  - “Show me my open tasks.”
  - “List squad tasks due this week.”
  - “Get tasks for project XYZ with high priority.”
  - “Give me the details for task ID 12345.”
- Needs a **machine-readable** representation of tasks (JSON) for:
  - Dashboards or reports
  - Routing into another tool or skill
  - Automated decision-making or triaging

Do **not** use this skill when:

- The user wants to **create, update, or delete** tasks (this skill is
  read-only).
- The request is about **other DataMiner entities** (alarms, tickets, metrics)
  that are not represented as Collaboration tasks.

If the user asks both to _retrieve_ tasks and to _take actions_ on them
(e.g., “show my tasks and close all completed ones”), use this skill purely
for the **retrieval and JSON output**. Any mutation logic should be handled
by a different specialized skill or tool.

---

## Inputs the agent should collect

Before calling any MCP tool, the agent should translate the user request into
a **task retrieval intent** with these dimensions:

1. **Task scope** (choose exactly one)
   - `"myTasks"` → use `GetMyTasks`
   - `"projectTasks"` → use `GetProjectTasks`
   - `"squadTasks"` → use `GetMySquadTasks`
   - `"taskDetails"` → use `GetTaskDetails` for a specific task ID

2. **Identifiers (when relevant)**
   - For `GetProjectTasks`: a project identifier from the user (e.g., name,
     key, or ID).  
     - Inspect the MCP tool schema in your environment to decide whether to
       pass `projectId`, `projectKey`, or any other required argument name.
   - For `GetTaskDetails`: the **task ID**.

3. **Status filters**
   - Default:
     ```json
     ["Closed", "Rejected", "Completed"]
     ```
     passed as `excludedStatuses`.
   - Only override the default when the user explicitly asks for:
     - Closed/completed tasks (include them by removing them from
       `excludedStatuses`), or
     - A specific set of statuses to include/exclude.

4. **Field selection**
   - Supported filterable fields:
     ```json
        ["ID", "Title", "Status", "Assignee", "Category", "Customer", "Estimation", "Project Type", "SLA Priority", "Type"]
     ```
   - If the user does **not** specify fields, use a compact default:
     ```json
     ["ID", "Title", "Status", "Assignee", "Category", "Customer", "Estimation", "Project Type", "SLA Priority", "Type"]
     ```
     (i.e., all the fields listed above).
   - If the user specifies one or more fields, only use those.

5. **Optional refinement (if the user provides it)**
   - Assignee (e.g., “only tasks assigned to me” is already covered by
     `GetMyTasks`; if they specify another person, pass it if supported by the tool).
   - Priority (e.g., “only high priority”).
   - Due date constraints (e.g., “due today”, “this week”, “overdue”) — map
     these into the appropriate parameters supported by the tool schemas.

If any critical parameter is missing (e.g., project identifier for
`GetProjectTasks`, task ID for `GetTaskDetails`), ask **one concise
clarifying question** before calling the tool.

---

## Tools this skill can use

All tools are exposed by the **MCP Server "Collaboration"**.

> ⚠️ The exact parameter names and return schemas may vary by implementation.
> Always inspect the tool definitions provided by your environment and adapt
> argument names accordingly. The behavior rules below are normative: follow
> them even if local names differ.

### 1. `GetMyTasks`

**Purpose**  
Retrieve tasks assigned to the current user.

**Required behavior**

- Always include:
  ```json
  "excludedStatuses": ["Closed", "Rejected", "Completed"]
  ```
  unless the user explicitly wants closed/rejected/completed tasks.

- If the user specifies fields, pass them as:

```json
"fields": ["ID", "Title", "Status", "Assignee", "Category", "Customer", "Estimation", "Project Type", "SLA Priority", "Type"]
```
(subset only, as requested).

- If the user does not specify fields, request all supported fields above.

### 2. GetProjectTasks

**Purpose**  
Retrieve tasks for a specific project.

**Required behavior**

- Require a project identifier (e.g., name, key, or ID).
- Use the parameter name expected by the tool schema (e.g. projectId or projectKey).

- Always include:
```json
"excludedStatuses": ["Closed", "Rejected", "Completed"]
```

unless the user explicitly wants closed/rejected/completed tasks.

- Handle fields exactly as in GetMyTasks.

### 3. GetMySquadTasks

**Purpose**  

Retrieve tasks for the user’s squad/team.

**Required behavior**

- Always set:
```json
"onlySquadMemberTasks": true
```

- Always include:
```json
"excludedStatuses": ["Closed", "Rejected", "Completed"]
```
unless the user explicitly wants closed/rejected/completed tasks.

- Handle fields exactly as in GetMyTasks.

### 4. GetTaskDetails

**Purpose**  

Retrieve detailed information for a single task by ID.

**Required behavior**

- Require the task ID from the user.
- When supported by the tool, you may still pass:

```json
"excludedStatuses": ["Closed", "Rejected", "Completed"]
```

but in most implementations, the task ID by itself should be sufficient.
- Use fields to reduce output to the user’s requested subset when possible;
otherwise, retrieve full details and then filter locally before returning.

---

## Step-by-step agent instructions
Follow this decision-making flow on every user request that involves task retrieval:

- Classify the user's intent
 - If they mention “my tasks” or ask generally for tasks without specifying project/squad, use GetMyTasks (scope = "myTasks").
 - If they mention a specific project, use GetProjectTasks (scope = "projectTasks").
 - If they mention squad/team/tribe tasks, use GetMySquadTasks (scope = "squadTasks").
 - If they mention a specific task ID, use GetTaskDetails (scope = "taskDetails").
- Determine filters
 - Initialize:

```json
"excludedStatuses": ["Closed", "Rejected", "Completed"]
```

- If the user asks for “all tasks including closed/completed/rejected”, then set:

```json
"excludedStatuses": []
```

- If they specify particular statuses to include or exclude, map their request accordingly (e.g., if they want “only completed tasks”, then you must not exclude "Completed").
- Determine fields
 - If the user specifies fields, intersect their requested list with:
```json
["ID", "Title", "Status", "Assignee", "Category", "Customer", "Estimation", "Project Type", "SLA Priority", "Type"]
```
and use the intersection as fields.
 - If the user does not specify fields, use all the supported fields above.

- Collect identifiers if needed
 - For **GetProjectTasks**, ensure you have a project identifier in the format required by the tool. Ask one clarifying question if needed.
 - For **GetTaskDetails**, ensure you have the task ID. Ask one clarifying question if needed.
- Call the appropriate MCP tool
 - Populate the arguments according to the tool schema (names may differ):
  - Always pass **excludedStatuses** for list-style tools.
  - For squad tasks, always pass **onlySquadMemberTasks: true**.
  - Pass **fields** when supported to limit data volume.
- Post-process the tool response
 - Normalize the response into a list of task objects.
 - For each task:
  - Include only the requested fields (or default field set).
  - Preserve field names exactly as: ID, Title, Status, Assignee, Priority, DueDate.
 - Do not add narrative explanations or commentary in the response; the next step in the workflow will handle interpretation.
- Return strictly valid JSON
The response must be a single JSON object with this structure:

```json
{
  "scope": "myTasks | projectTasks | squadTasks | taskDetails",
  "toolUsed": "GetMyTasks | GetProjectTasks | GetMySquadTasks | GetTaskDetails",
  "parameters": {
    "projectIdentifier": "optional string, when scope = projectTasks",
    "taskId": "optional string, when scope = taskDetails",
    "excludedStatuses": ["Closed", "Rejected"],
    "onlySquadMemberTasks": true,
    "fields": ["ID", "Title", "Status", "Assignee", "Category", "Customer", "Estimation", "Project Type", "SLA Priority", "Type"]
  },
  "tasks": [
    {
      "ID": "TASK-123",
      "Title": "Example task",
      "Status": "In Progress",
      "Assignee": "user@example.com",
      "Priority": "High",
      "DueDate": "2026-03-31"
    }
  ]
}
```

- Rules for output:
 - No Markdown (no backticks, no headings).
 - No comments or trailing commas.
 - No extra keys beyond scope, toolUsed, parameters, and tasks.
 - If no tasks match the filters, return:

```json
{
  "scope": "...",
  "toolUsed": "...",
  "parameters": { ... },
  "tasks": []
}
```