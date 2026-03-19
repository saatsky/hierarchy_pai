---
name: Product Backlog Score (PBS)
version: 1.1
description: >
  Compute a Product Backlog Score (PBS) for a task based on weighted dimensions:
  Category, Customer, Estimation, Project Type, SLA Priority, and Task Type.
  Returns a numeric score (0–500), an expectation band, and a color.
type: workflow
tags:
  - prioritization
  - backlog
  - scoring
  - product-owner
---

## Overview

This skill computes the **Product Backlog Score (PBS)** for a single task.

The PBS is a **weighted score** across six dimensions:

- **Category** (weight 15)
- **Customer** (weight 25)
- **Estimation** (weight 15)
- **Project Type** (weight 10)
- **SLA Priority** (weight 15)
- **Task Type** (weight 20)

For each dimension:

    dimension_score = value_score * weight

Where `value_score` is an integer from 1 to 5.

The **final PBS score** is:

    pbs_score = sum(all dimension_scores)

This yields a range from **100 to 500** when all six dimensions are present and scored between 1 and 5.

The skill then maps this PBS score to an **expectation band** (resolution timeframe) and a **color**.

---

## When to use this skill

Use this skill whenever you need to:

- **Prioritize** items in a product or engineering backlog.
- **Standardize urgency** and delivery expectations across teams.
- Decide which tasks should be **picked up first** based on a consistent scoring model.

This skill is especially useful when:

- You have multiple tasks competing for limited capacity.
- You want to justify prioritization decisions with a transparent, repeatable method.
- You are preparing sprint planning, PI planning, or roadmap refinement.

---

## Inputs

Call the `score_pbs` tool with a single `task` object.

### Required fields

- `task.task_type` (string)  
  Example: `"Bug"`, `"New Feature"`, `"Deployment"`, `"Support"`

- `task.customer` (string)  
  Example: `"Eutelsat"`, `"Orange"`, `"SatPort"`

- `task.priority` (string)  
  Example: `"High"`, `"Medium"`, `"Low"`, `"P1"`, `"Critical"`

- `task.estimation_days` (number)  
  Estimated implementation effort in **working days** (can be fractional).

### Optional fields

- `task.category` (string)  
  If provided, use this directly; otherwise, infer from `task_type` / `issue_type`.

- `task.project_type` (string)  
  If provided, use this directly normally `Order`; otherwise, it's `Maintenance` infer from `project_type` Title if includes the text `(Continuity)`.

- `task.issue_type` (string)  
  Optional alternate field used for inferring category and project type.

---

## Outputs

The tool returns an object with:

- `pbs_score` (number)  
  The total Product Backlog Score (0–500).

- `band` (string)  
  A human-readable expectation band such as `"Resolve within 2 weeks"`.

- `color` (string)  
  A simple color code for visualization (e.g., `"orange"`).

You may optionally include intermediate details (dimension scores) in your natural language response, but the tool response **must** at minimum contain `pbs_score`, `band`, and `color`.

---

## Scoring tables

### Weights by dimension

| Dimension     | Weight | Field name        |
|---------------|--------|-------------------|
| Category      | 15     | `category`        |
| Customer      | 25     | `customer`        |
| Estimation    | 15     | `estimation_days` |
| Project Type  | 10     | `project_type`    |
| SLA Priority  | 15     | `priority`        |
| Task Type     | 20     | `task_type`       |

### Category (weight 15)

| Name                | Value score |
|---------------------|------------|
| Connector           | 5          |
| Automation Script   | 4          |
| LCA Configuration   | 3          |
| Visio Configuration | 3          |
| Software            | 2          |

### Customer (weight 25)

| Name       | Value score |
|------------|-------------|
| Eutelsat   | 5           |
| OneWeb     | 4           |
| Orange     | 3           |
| SatPort    | 2           |
| Skyline    | 1           |
| Hellas‑Sat | 2           |

### Estimation (weight 15)

Map the numeric `estimation_days` to a value score:

| Estimation (days) | Condition                     | Value score |
|-------------------|------------------------------|------------|
| `< 1`             | estimation_days < 1          | 5          |
| `< 3`             | 1 ≤ estimation_days < 3      | 4          |
| `< 5`             | 3 ≤ estimation_days < 5      | 3          |
| `< 10`            | 5 ≤ estimation_days < 10     | 2          |
| `≥ 10`            | estimation_days ≥ 10         | 1          |

### Project Type (weight 10)

| Type        | Value score |
|-------------|------------|
| Order       | 5          |
| Maintenance | 3          |

### SLA Priority (weight 15)

| Priority | Value score |
|----------|-------------|
| High     | 5           |
| Medium   | 3           |
| Low      | 1           |

### Task Type (weight 20)

| Type              | Value score |
|-------------------|------------|
| Issue             | 5          |
| New Feature       | 4          |
| Deployment        | 3          |
| Technical Writing | 3          |
| Action Item       | 2          |
| Support           | 2          |
| Consultancy       | 2          |

---

## Field mappings (auto-detection rules)

When a dimension is not explicitly provided, infer it from the task fields as follows.

### Category

1. Prefer `task.category` if present.
2. Otherwise, infer from `task.task_type`, falling back to `task.issue_type`.

Use case-insensitive substring or exact match against these mappings:

- **Automation Script**  
  `["Automation Script", "Automation", "Script"]`

- **Connector**  
  `["Connector Development", "Driver Development", "Protocol Development", "Connector", "Driver"]`

- **LCA Configuration**  
  `["DMA Installation", "DMS Installation", "LCA Configuration", "Configuration", "Installation", "Upgrade"]`

- **Software**  
  `["New Feature", "Bug", "Issue", "Feature Request", "Software", "Development", "Enhancement"]`

- **Visio Configuration**  
  `["Visio", "Dashboard", "Visual"]`

If nothing matches, you may:

- Assign a conservative default category (e.g., `Software`), **or**
- Ask the user to clarify before scoring.

### Customer

Match the `task.customer` string against:

- **Eutelsat**: `["Eutelsat"]`
- **Hellas-Sat**: `["Hellas-Sat", "HellasSat", "Hellas Sat"]`
- **OneWeb**: `["OneWeb", "One Web"]`
- **Orange**: `["Orange"]`
- **SatPort**: `["SatPort", "Sat Port"]`
- **Skyline**: `["Skyline", "Skyline Communications"]`

Use case-insensitive matching. If no mapping matches, you may assign a neutral default (e.g., `Skyline` with score 1) and note this assumption in your explanation.

### Priority (SLA)

Match `task.priority` against:

- **High**: `["High", "Critical", "P1", "P2"]`
- **Medium**: `["Medium", "Normal", "P3"]`
- **Low**: `["Low", "Minor", "P4", "P5"]`

If no match, ask the user to clarify or default to `Medium`.

### Project Type

1. Prefer `task.project_type` if present.
2. Otherwise, infer from `task.task_type`, falling back to `task.issue_type`.

Map using:

- **Maintenance**:  
  `["DMA Installation","DMS Installation","Deployment","Support","Consultancy",
    "Maintenance","Action Item","Meeting Action","Installation","Upgrade",
    "Technical Writing","Documentation"]`

- **Order**:  
  `["Issue","Bug","New Feature","Feature Request","Connector Development",
    "Driver Development","Automation Script","Enhancement","Improvement","Defect"]`

If neither bucket matches, choose `Maintenance` as a safe default and explain the assumption.

---

## Expectation bands

After computing `pbs_score`, map it to an expectation band and color:

| PBS Score Range | Expectation Band          | Color   |
|-----------------|---------------------------|---------|
| 451–500         | Resolve within 1 week     | red     |
| 401–450         | Resolve within 2 weeks    | orange  |
| 351–400         | Resolve within 1 month    | yellow  |
| 301–350         | Resolve within 2 months   | lime    |
| 201–300         | Resolve within 3–4 months | green   |
| 101–200         | Resolve within 5–6 months | blue    |
| 1–100           | Resolve within 6+ months  | gray    |
| 0               | Cannot pick up            | slate   |
| -1              | Admin-only task           | purple  |

Note: `pbs_score` will typically be in the 100–500 range when all dimensions have scores. Use `0` only if the task cannot be scored and must not be picked up. Use `-1` for admin/internal tasks that should be excluded from prioritization.

---

## Step-by-step process the agent must follow

When the user calls `score_pbs` with a `task` object:

1. **Parse and normalize inputs**
   - Read `task_type`, `customer`, `priority`, `estimation_days`, and optional fields.
   - Trim whitespace and treat strings as case-insensitive.

2. **Determine each dimension’s value**
   - **Category**: use `task.category` if present; otherwise infer using the Category mapping rules above.
   - **Customer**: match `task.customer` against the Customer mapping table.
   - **Estimation**: convert `estimation_days` into a value score using the Estimation table.
   - **Project Type**: use `task.project_type` if present; otherwise infer using the Project Type mapping.
   - **SLA Priority**: map `task.priority` using the SLA Priority table.
   - **Task Type**: directly use `task.task_type` to look up the value score.

3. **Convert dimension values to value scores**
   - For each dimension, look up the **value score (1–5)** from the corresponding table.
   - If you cannot determine a value score, either:
     - Ask the user for clarification, or
     - Apply a conservative default and explicitly mention it in your explanation.

4. **Compute dimension scores**
   - For each dimension:  
     `dimension_score = value_score * weight`

5. **Compute total PBS score**
   - Sum all dimension scores:  
     `pbs_score = sum(dimension_score for all dimensions)`

6. **Assign expectation band and color**
   - Use the Expectation Bands table to map `pbs_score` to `band` and `color`.

7. **Return structured output**
   - Return a JSON object with:
     
        {
          "pbs_score": <number>,
          "band": "<string>",
          "color": "<string>"
        }
     
   - In any natural-language explanation to the user, briefly summarize:
     - The main drivers (e.g., “High priority customer Eutelsat + High SLA priority”)
     - Any assumptions or defaults you had to make.

---

## Examples

### Example input

    {
      "task": {
        "task_type": "Bug",
        "customer": "Eutelsat",
        "priority": "High",
        "estimation_days": 2
      }
    }

### Example output

    {
      "pbs_score": 432,
      "band": "Resolve within 2 weeks",
      "color": "orange"
    }

(Exact score may vary slightly depending on inferred category and project type, but it should remain in the same expectation band unless the dimension mappings are materially different.)

---

## Tool API specification

    tools:
      score_pbs:
        description: Compute PBS score, expectation band, and color using the PBS scoring model.
        input_schema:
          type: object
          properties:
            task:
              type: object
              properties:
                task_type:
                  type: string
                customer:
                  type: string
                priority:
                  type: string
                estimation_days:
                  type: number
                category:
                  type: string
                project_type:
                  type: string
                issue_type:
                  type: string
              required:
                - task_type
                - customer
                - priority
                - estimation_days
          required:
            - task
        output_schema:
          type: object
          properties:
            pbs_score:
              type: number
            band:
              type: string
            color:
              type: string
          required:
            - pbs_score
            - band
            - color
```