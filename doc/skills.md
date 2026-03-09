# Agent Skills

**Skills** are reusable, file-based system prompt packages that override a specialist's default prompt for a specific step. Where a *Specialist* defines _how_ an agent thinks (its persona and reasoning style), a *Skill* defines _what methodology_ it applies (a structured framework, output format, and domain expertise).

---

## Skill vs Specialist

| | Specialist | Skill |
|---|---|---|
| Defined in | `AgentRegistry` (code) | `priv/skills/<id>/SKILL.md` (file) |
| Selected by | Planner automatically; override in review | User selects per-step in review or redo |
| Scope | Persona + general reasoning style | Specific methodology + output structure |
| When to use | Always (fallback when no skill selected) | When you need a documented framework applied |
| Example | Content Creator | Press Release Writer (Amazon working-backwards) |

When a skill is assigned to a step, the skill's body replaces the specialist's system prompt entirely for that LLM call. The specialist persona is still shown on the execution board card.

---

## Assigning a Skill

### During plan review

After the Planner generates a plan, each step card in the **Review Plan** section shows two dropdowns:

1. **Specialist** — the agent persona (set by the Planner, can be changed)
2. **Skill** — `— default specialist —` (no skill) or a skill from the panel

Select a skill from the dropdown to override the specialist prompt for that step.

### During redo

When you click **Redo** on a completed step card, the confirmation dialog shows the same two dropdowns under **Override for this redo**. Change the skill (or specialist) to get a different output without re-running the whole pipeline.

---

## The Agent Skills Panel

The **Agent Skills** sidebar panel lists all loaded skills. Each row shows:

- **Type badge** — colour-coded: `research` (blue), `content` (amber), `engineering` (purple)
- **Skill name** — truncated; hover the **ⓘ** icon to read the full description
- **Cloud icon** — appears on skills synced from the remote GitHub repository

Use the **Check for updates** button to pull new skills from the `saatsky/hierarchy_pai` repository. Skills already loaded locally are skipped.

---

## SKILL.md Format

Each skill lives in its own directory under `priv/skills/`:

```
priv/skills/
└── <skill-id>/
    └── SKILL.md
```

`SKILL.md` has two parts separated by `---`:

```markdown
---
name: Press Release Writer
description: Craft compelling press releases in the Amazon working-backwards style.
type: content
---

Your full system prompt goes here.

Use Markdown freely — headings, bullet lists, code blocks are all supported.
The entire body is sent verbatim as the LLM system message for this step.
```

### Frontmatter fields

| Field | Required | Values | Description |
|---|---|---|---|
| `name` | Yes | string | Human-readable display name shown in the UI |
| `description` | Yes | string | One-line summary shown in the tooltip |
| `type` | Yes | `research` · `content` · `engineering` · *(any string)* | Controls the colour badge in the panel |

### Body

The body is the complete system prompt sent to the LLM. Write it as plain Markdown — headings and lists render in the body but are sent as raw text to the model. Be explicit about:

- The role the model should adopt
- The exact output format (headings, sections, word limits)
- Any constraints (tone, length, vocabulary)

---

## Seed Skills

Four skills are included out of the box:

### 📄 press-release (`content`)
**Press Release Writer** — Produces Amazon-style "working backwards" press releases. Enforces the 10-section structure (Headline → Boilerplate) and writing guidelines (active voice, ≤800 words, no superlatives).

*Best used with*: Content Creator specialist on any step that announces a product, feature, or initiative.

---

### 🔍 discovery-process (`research`)
**Discovery Process Facilitator** — Guides structured product discovery conversations to surface user needs, pain points, and opportunity areas.

*Best used with*: Trend Researcher or Feedback Synthesizer specialist on research or discovery steps.

---

### 🎯 jobs-to-be-done (`research`)
**Jobs-to-be-Done Analyst** — Analyses and articulates customer Jobs-to-be-Done including functional, emotional, and social dimensions with opportunity scoring.

*Best used with*: Trend Researcher or Feedback Synthesizer specialist on customer insight steps.

---

### 🗂️ epic-breakdown (`engineering`)
**Epic Breakdown Specialist** — Decomposes product epics into well-formed user stories and acceptance criteria following best practices (Given/When/Then, INVEST criteria).

*Best used with*: Sprint Prioritizer or Backend Architect specialist on backlog/planning steps.

---

## Adding New Skills

Skills are community-contributed via pull request to the `saatsky/hierarchy_pai` repository.

### Steps

1. **Create the directory and file**:
   ```bash
   mkdir -p priv/skills/<your-skill-id>
   touch priv/skills/<your-skill-id>/SKILL.md
   ```

2. **Write your SKILL.md** — follow the format above. Choose a descriptive `id` (kebab-case, e.g. `competitive-analysis`).

3. **Test locally** — restart the Phoenix server; your skill should appear in the panel immediately.

4. **Open a pull request** to `saatsky/hierarchy_pai` with your new skill file. Once merged into `main`, all users can sync it via the **Check for updates** button.

### Naming conventions

- `id` (directory name): lowercase kebab-case, no spaces, concise (`press-release` not `amazon-pr-working-backwards-method`)
- `name`: title-case, ≤ 50 characters
- `description`: one sentence, ≤ 120 characters, no trailing period
- `type`: use `research`, `content`, or `engineering`; add a new type if genuinely different

---

## Syncing Skills from GitHub

The **Check for updates** button fetches the `priv/skills/` directory listing from the GitHub Contents API (`api.github.com/repos/saatsky/hierarchy_pai/contents/priv/skills`), downloads any skill IDs not already loaded, writes the files to disk, and reloads the ETS store.

### Common sync messages

| Message | Meaning |
|---|---|
| `N new skill(s) loaded from GitHub.` | Success — N skills were added |
| `No new skills found — already up to date.` | All remote skills are already loaded |
| `Skills directory not found on GitHub yet (saatsky/hierarchy_pai/priv/skills). Push your changes first.` | The `priv/skills/` directory hasn't been pushed to `main` yet |
| `GitHub API rate limit exceeded` | Unauthenticated requests are limited to 60/hour — wait and retry |

> **No API key required** for public repositories, but the rate limit is 60 requests/hour per IP. Skills sync rarely so this is unlikely to be a problem in practice.

---

## How Skills Work Internally

Skills are managed by `HierarchyPai.SkillStore`, a GenServer backed by a named ETS table:

```
SkillStore (GenServer + ETS :skill_store)
  ├── list/0       → [%{id, name, description, type, content, source}]
  ├── get/1        → skill | nil
  └── sync_remote/0 → {:ok, count} | {:error, reason}
```

At startup, `load_local_skills/0` scans `priv/skills/**/SKILL.md` and populates the ETS table. `source: :local` is set for files already on disk; synced skills get `source: :remote`.

At execution time, when a step has a `skill_id`, `Executor` calls `SkillStore.get(skill_id)` and uses `skill.content` as the system prompt instead of the specialist's default prompt from `AgentRegistry`.
