# These examples are for the agent to understand the pattern.
They are not shown to the user as-is.

## Example 1 – “Show me my open tasks”
### User request

Show me my tasks, I don't care about closed ones. Just basic info.

### Agent behavior

- Scope: myTasks
- Tool: GetMyTasks
- excludedStatuses remains default: ["Closed", "Rejected", "Completed"]
- Fields: default set (["ID", "Title", "Status", "Assignee", "Priority", "DueDate"])

- Expected output shape
```json
{  "scope": "myTasks",  "toolUsed": "GetMyTasks",  "parameters": {    "excludedStatuses": ["Closed", "Rejected", "Completed"],    "onlySquadMemberTasks": null,    "fields": ["ID", "Title", "Status", "Assignee", "Priority", "DueDate"]  },  "tasks": [    {      "ID": "TASK-001",      "Title": "Investigate customer issue",      "Status": "In Progress",      "Assignee": "me@example.com",      "Priority": "High",      "DueDate": "2026-03-20"    }  ]}
```
(Values are illustrative; the agent will use real data from the MCP server.)

## Example 2 – “Project tasks including completed”

### User request

For project DMA-123, give me all tasks including completed ones, but I only
need ID, title and status.

### Agent behavior

- Scope: projectTasks
- Tool: GetProjectTasks
- excludedStatuses: [] (because user explicitly wants completed)
- Fields: ["ID", "Title", "Status"]

- Expected output shape

```json
{  "scope": "projectTasks",  "toolUsed": "GetProjectTasks",  "parameters": {    "projectIdentifier": "DMA-123",    "taskId": null,    "excludedStatuses": [],    "onlySquadMemberTasks": null,    "fields": ["ID", "Title", "Status"]  },  "tasks": [    {      "ID": "DMA-123-45",      "Title": "Implement OAuth client secret rotation",      "Status": "Completed"    }  ]}
```
## Example 3 – “Squad tasks, high priority only”

### User request

Get my squad's high-priority tasks that are still open. I only need ID,
title, assignee, and due date.

### Agent behavior

- Scope: squadTasks
- Tool: GetMySquadTasks
- onlySquadMemberTasks: true
- excludedStatuses: default, because the user asked for “still open”
- Fields: ["ID", "Title", "Assignee", "DueDate"]
 - If the MCP schema allows priority filters, the agent should use them.
 - If not, the agent may post-filter results before returning JSON.

- Expected output shape
```json
{  "scope": "squadTasks",  "toolUsed": "GetMySquadTasks",  "parameters": {    "projectIdentifier": null,    "taskId": null,    "excludedStatuses": ["Closed", "Rejected", "Completed"],    "onlySquadMemberTasks": true,    "fields": ["ID", "Title", "Assignee", "DueDate"]  },  "tasks": [    {      "ID": "SQUAD-789",      "Title": "Migrate authentication to Azure AD",      "Assignee": "colleague@example.com",      "DueDate": "2026-03-25"    }  ]}
```
## Example 4 – “Details for a specific task”

### User request

Show me the details of task 4567 and include all basic fields.

### Agent behavior

- Scope: taskDetails
- Tool: GetTaskDetails
- taskId: "4567"
- Fields: default field set, unless the tool already returns a richer object, in which case the agent filters locally.

- Expected output shape
```json
{  "scope": "taskDetails",  "toolUsed": "GetTaskDetails",  "parameters": {    "projectIdentifier": null,    "taskId": "4567",    "excludedStatuses": ["Closed", "Rejected", "Completed"],    "onlySquadMemberTasks": null,    "fields": ["ID", "Title", "Status", "Assignee", "Priority", "DueDate"]  },  "tasks": [    {      "ID": "4567",      "Title": "Review POC with PwC architect",      "Status": "In Progress",      "Assignee": "you@example.com",      "Priority": "Medium",      "DueDate": "2026-03-19"    }  ]}
```

---