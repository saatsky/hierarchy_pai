# PBS Scoring Skill
Version: 1.0  
Purpose: Compute the Product Backlog Score (PBS) using the scoring_model.yaml configuration.

## Overview
This skill exposes a single tool — **score_pbs** — which calculates the Product Backlog Score based on weighted dimensions defined in *scoring_model.yaml*.  
The score determines the urgency and delivery expectation of a task.

---

## Skill Definition

name: Product Backlog Score (PBS)  
description: >
  Computes the Product Backlog Score (PBS) using the official scoring_model.yaml.
  It applies dimension weights, detects task attributes via field mapping,
  and returns both the numeric PBS score and the expectation band.  
type: engineering
---

## Scoring Logic

### Weighted Dimensions

| Dimension       | Weight | Maps to field       |
|----------------|--------|----------------------|
| Category        | 15     | category            |
| Customer        | 25     | customer            |
| Estimation      | 15     | estimation_days     |
| Project Type    | 10     | project_type        |
| SLA Priority    | 15     | priority            |
| Task Type       | 20     | task_type           |

---

## Dimension Values

### Category (weight 15)

| Name | Score |
|------|-------|
| Connector | 5 |
| Automation Script | 4 |
| LCA Configuration | 3 |
| Visio Configuration | 3 |
| Software | 2 |

### Customer (weight 25)

| Name | Score |
|------|-------|
| Eutelsat | 5 |
| OneWeb | 4 |
| Orange | 3 |
| SatPort | 2 |
| Skyline | 1 |
| Hellas‑Sat | 2 |

### Estimation (weight 15)

| Estimation | Score |
|------------|--------|
| < 1 day | 5 |
| < 3 days | 4 |
| < 5 days | 3 |
| < 10 days | 2 |
| ≥ 10 days | 1 |

### Project Type (weight 10)

| Type | Score |
|------|--------|
| Order | 5 |
| Maintenance | 3 |

### SLA Priority (weight 15)

| Priority | Score |
|----------|--------|
| High | 5 |
| Medium | 3 |
| Low | 1 |

### Task Type (weight 20)

| Type | Score |
|------|--------|
| Issue | 5 |
| New Feature | 4 |
| Deployment | 3 |
| Technical Writing | 3 |
| Action Item | 2 |
| Support | 2 |
| Consultancy | 2 |

---

## Field Mappings (Auto Detection)

The skill automatically detects the correct dimension value based on task fields.

### Example mapping structure:

```yaml
field_mappings:
  category:
    task_field: task_type
    fallback_field: issue_type
    type_mappings:
      Automation Script: ["Automation Script", "Automation", "Script"]
      Connector: ["Connector Development","Driver Development","Protocol Development","Connector","Driver"]
      LCA Configuration: ["DMA Installation","DMS Installation","LCA Configuration","Configuration","Installation","Upgrade"]
      Software: ["New Feature","Bug","Issue","Feature Request","Software","Development","Enhancement"]
      Visio Configuration: ["Visio","Dashboard","Visual"]

  customer:
    task_field: customer
    type_mappings:
      Eutelsat: ["Eutelsat"]
      Hellas-Sat: ["Hellas-Sat","HellasSat","Hellas Sat"]
      OneWeb: ["OneWeb","One Web"]
      Orange: ["Orange"]
      SatPort: ["SatPort","Sat Port"]
      Skyline: ["Skyline","Skyline Communications"]

  priority:
    task_field: priority
    type_mappings:
      High: ["High","Critical","P1","P2"]
      Low: ["Low","Minor","P4","P5"]
      Medium: ["Medium","Normal","P3"]

  project_type:
    task_field: task_type
    fallback_field: issue_type
    type_mappings:
      Maintenance:
        ["DMA Installation","DMS Installation","Deployment","Support","Consultancy",
         "Maintenance","Action Item","Meeting Action","Installation","Upgrade",
         "Technical Writing","Documentation"]
      Order:
        ["Issue","Bug","New Feature","Feature Request","Connector Development",
         "Driver Development","Automation Script","Enhancement","Improvement","Defect"]
```

---

## Score Formula

### Each dimension score:

```
dimension_score = (value_score / 5) * weight
```

### Final PBS score:

```
pbs_score = sum(all dimension_scores)
```

## Expectation Bands

| PBS Score Range | Expectation Band | Color  |
|-----------------|-----------------|--------|
|451–500 |Resolve within 1 week | red |
|351–400 |Resolve within 1 month | yellow |
|301–350 |Resolve within 2 months | lime |
|401–450 |Resolve within 2 weeks | orange |
|201–300 |Resolve within 3–4 months | green |
|101–200 |Resolve within 5–6 months | blue |
|1–100 |Resolve within 6+ months | gray |
|0 |Cannot pick up | slate |
|-1 |Admin-only task | purple |

## Tool Specification

```yaml
tools:
  score_pbs:
    description: Compute PBS score using scoring_model.yaml
    input_schema:
      type: object
      properties:
        task:
          type: object
    output_schema:
      type: object
      properties:
        pbs_score:
          type: number
        band:
          type: string
        color:
          type: string
```

---

## Example

### Input
```json
{
  "task": {
    "task_type": "Bug",
    "customer": "Eutelsat",
    "priority": "High",
    "estimation_days": 2
  }
}
```

### Output

```json
{
  "pbs_score": 432,
  "band": "Resolve within 2 weeks",
  "color": "orange"
}

---
