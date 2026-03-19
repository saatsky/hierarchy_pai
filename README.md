# Hierarchical Planner AI

> A Hierarchical Multi-Agent AI Planner built with Elixir, Phoenix LiveView, and LangChain.

Hierarchical Planner AI decomposes a complex task into parallel, dependency-aware steps, executes them concurrently using your chosen LLM, and synthesises the results into a single final answer — all within an interactive real-time UI.

---

## ✨ Features

- **Hierarchical planning** — a Planner agent breaks any goal into 3–8 structured steps with explicit dependencies
- **Specialist AI agents** — the Planner automatically assigns one of 12 domain experts (Backend Architect, Frontend Developer, AI Engineer, etc.) to each step; fully overridable in the review phase
- **Agent Skills** — file-based system prompt packages (SKILL.md) that override a specialist's default prompt with a specific methodology; assignable per step or when redoing a step; the Planner auto-assigns the best skill when available
- **MCP Client** — attach external MCP servers to individual steps; the Executor calls real tools (APIs, databases, services) during execution; server names are portable and preserved in saved/downloaded plans
- **Save, download & upload plans** — save plans to the in-memory panel, export as self-contained JSON (includes name, task, assignments, MCP server names, provider info), and re-import on any instance; plans are version-control friendly
- **Parallel wave execution** — independent steps run concurrently; dependent steps wait only for their specific prerequisites
- **Real-time Kanban board** — watch steps move through Queue → Running → **Waiting** (user input) → Done / Failed live, with the agent specialist shown on each card
- **Agent-triggered user input** — during execution, any step's LLM can pause and ask the user a specific question via the `request_user_input` tool; the answer is injected back into the LLM chain and execution continues automatically
- **Per-step model selection** — assign a different LLM model to each step
- **Step output preview** — click any completed step card to read the full output before it reaches the aggregator
- **Redo with override** — re-run any completed step with a different specialist and/or skill to iterate towards a better output
- **Failure recovery** — retry only the failed steps, or skip them and aggregate what succeeded
- **Multiple LLM providers** — local (Jan.ai, Ollama) and cloud (OpenAI, Anthropic, Custom endpoint)
- **Light / dark theme** — toggle between light and dark mode; preference persisted in localStorage
- **Configurable retries** — tune LangChain chain-level retries to balance speed vs reliability
- **Docker-ready** — single `docker compose up --build` to run anywhere
- **MCP Server** — expose the full pipeline as an MCP endpoint (`POST /mcp`); any MCP-compatible agent (Jan.ai, VS Code, Claude Desktop) can call `run_task`, `plan_task`, `execute_plan`, `list_specialists`, and `list_skills`

---

## 🏗️ Architecture

```
User Input
    │
    ▼
┌─────────────┐
│   Planner   │  1 LLM call → structured JSON plan (steps + dependencies)
└──────┬──────┘
       │  Plan Review (user accepts/rejects steps, assigns models, specialist + skill per step)
       ▼
┌─────────────────────────────────────┐
│         Execution Waves             │
│  Wave 1: [Step A 🏗] [Step B 📝] ──►│  parallel, each with specialist/skill prompt
│  Wave 2: [Step C 🔍]           ───►│  (C depends on A or B)
│  Wave 3: [Step D 📊]           ───►│
└──────────────────┬──────────────────┘
                   │  Done step → click to view output or Redo with different specialist/skill
                   │  Failure → action panel (retry / skip / cancel)
                   ▼
┌─────────────┐
│ Aggregator  │  1 LLM call → final synthesised answer
└─────────────┘
       │  Answer Review (user accepts or regenerates)
       ▼
    Done ✓
```

Total LLM calls = **N + 2** (1 Planner + N Executors + 1 Aggregator).

---

## 📋 Requirements

| Requirement | Version |
|---|---|
| Elixir | ≥ 1.15 |
| Erlang/OTP | ≥ 26 |
| Docker & Docker Compose | ≥ 24 (for Docker install) |
| Jan.ai / Ollama | any (for local LLM) |

---

## 🚀 Quick Start

### Option A — Local development

```bash
# 1. Clone and install dependencies
git clone <repo>
cd hierarchy_pai
mix setup

# 2. Start the server
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

### Option B — Docker

```bash
# 1. Generate a secret key
mix phx.gen.secret   # copy the output

# 2. Create your .env file
cp .env.example .env
# Edit .env and paste your SECRET_KEY_BASE

# 3. Build and run
docker compose up --build
```

Open [http://localhost:4000](http://localhost:4000).

> **Jan.ai from Docker**: the container cannot reach `localhost` on your host machine.
> In the LLM Provider panel, change the Server URL to `http://host.docker.internal:1337`.

---

## ⚙️ Configuration

All LLM provider settings are configured through the **LLM Provider** panel in the UI — no config files needed.

### Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `SECRET_KEY_BASE` | Yes (prod) | — | 64-char secret. Generate with `mix phx.gen.secret` |
| `PHX_HOST` | No | `localhost` | Hostname used in URL generation |
| `PORT` | No | `4000` | HTTP port |
| `PHX_SERVER` | No | — | Set to `true` to start the HTTP server in a release |

---

## 🤖 Specialist Agents

Each step in the plan is automatically assigned a **specialist agent** by the Planner based on the nature of the work. You can override any assignment during the plan review phase.

| Agent | Icon | Best For |
|---|---|---|
| General Executor | ⚡ | Generic or uncategorised tasks |
| Backend Architect | 🏗️ | API design, DB schemas, system architecture |
| Frontend Developer | 🎨 | UI components, CSS, accessibility, web performance |
| AI Engineer | 🤖 | LLM pipelines, RAG, embeddings, ML integration |
| DevOps Automator | 🚀 | CI/CD, Docker, Kubernetes, infrastructure |
| Rapid Prototyper | ⚡ | Quick POCs, MVPs, proof-of-concept code |
| Content Creator | 📝 | Writing, copywriting, documentation |
| Trend Researcher | 🔍 | Market research, competitive analysis |
| Feedback Synthesizer | 💬 | Qualitative analysis, insight extraction |
| Data Analytics | 📊 | Metrics, KPIs, dashboards, reports |
| Sprint Prioritizer | 🎯 | Backlog management, sprint planning |
| Growth Hacker | 📈 | GTM strategy, acquisition, experiments |

See [Specialist Agents](doc/agents.md) for full details on each agent's persona and capabilities.

---

## 📦 Project Structure

```
hierarchy_pai/
├── lib/
│   ├── hierarchy_pai/
│   │   ├── agents/
│   │   │   ├── agent_registry.ex  # 12 specialist personas + system prompts
│   │   │   ├── planner.ex         # Decomposes task into JSON plan (skill-aware)
│   │   │   ├── executor.ex        # Runs a single step with specialist/skill/MCP tools
│   │   │   └── aggregator.ex      # Synthesises all step outputs
│   │   ├── orchestrator.ex        # Wave-based parallel execution
│   │   ├── mcp_client.ex          # HTTP MCP client (connect + call_tool)
│   │   ├── mcp_server_store.ex    # ETS-backed registered MCP servers
│   │   ├── plan_store.ex          # ETS-backed saved plans
│   │   ├── provider_store.ex      # ETS-backed saved LLM provider configs
│   │   ├── skill_store.ex         # ETS-backed skill loader (priv/skills/)
│   │   └── llm_provider.ex        # Builds LangChain models per provider
│   └── hierarchy_pai_web/
│       ├── live/
│       │   └── planner_live.ex    # Main LiveView (UI + state machine)
│       └── router.ex
├── assets/
│   ├── css/app.css                # Tailwind CSS v4 + DaisyUI v5
│   └── js/app.js                  # LiveView + colocated hooks
├── config/
│   ├── config.exs
│   ├── prod.exs
│   └── runtime.exs                # Reads env vars at startup
├── priv/
│   └── skills/                    # Seed SKILL.md files (one dir per skill)
│       ├── press-release/
│       ├── discovery-process/
│       ├── jobs-to-be-done/
│       └── epic-breakdown/
├── Dockerfile                     # Multi-stage Docker build
├── docker-compose.yml
└── doc/                           # Documentation
```

---

## 🛠️ Development

```bash
mix deps.get          # install dependencies
mix phx.server        # start with live reload
mix precommit         # compile + format + test (run before committing)
mix assets.deploy     # build production assets
```

---

## 📖 Documentation

| Guide | Description |
|---|---|
| [Installation](doc/installation.md) | Detailed setup for local dev, Docker, and releases |
| [LLM Provider Setup](doc/providers.md) | How to configure Jan.ai, Ollama, OpenAI, Anthropic |
| [Specialist Agents](doc/agents.md) | All 12 agent types, their expertise, and how to assign them |
| [Agent Skills](doc/skills.md) | SKILL.md format, seed skills, adding new skills via PR |
| [MCP Client](doc/mcp-client.md) | Connecting external MCP servers to steps; tool-calling; portability |
| [Plans: Save / Download / Upload](doc/plans.md) | Persisting, exporting, and importing plans; portable JSON format |
| [Task Examples](doc/examples.md) | Sample prompts with expected outputs and agent assignments |
| [Troubleshooting](doc/troubleshooting.md) | Common errors and how to fix them |
| [MCP Server API](priv/TOOLS.md) | MCP endpoint, all 5 tools, request/response schemas |

---

## 🔌 MCP Server

hierarchy_pai exposes its full planning pipeline as an MCP server at:

```
POST http://localhost:4000/mcp
```

Any MCP-compatible client (Jan.ai, VS Code Copilot, Claude Desktop, Cursor) can call the 5 tools
to delegate complex tasks: the pipeline decomposes them into parallel specialist steps, executes
them concurrently, and returns a synthesised final answer.

### Available tools

| Tool | Phase | Description |
|------|-------|-------------|
| `run_task` | Full pipeline | Plan → parallel execution → synthesised answer in one call |
| `plan_task` | Plan only | Generate a structured plan for review; execute separately with `execute_plan` |
| `execute_plan` | Execute only | Run a plan object produced by `plan_task` |
| `list_specialists` | Discovery | List the 12 available specialist agent types |
| `list_skills` | Discovery | List loaded SKILL.md methodology packs |

### Two-step workflow (recommended)

```
1. plan   = plan_task(task="...", provider="my-provider")
2. review plan.steps — check agent assignments, step count, instructions
3. result = execute_plan(task="...", plan=plan, provider="my-provider")
```

### Client setup

**Jan.ai** — Settings → MCP Servers → Add server, URL `http://localhost:4000/mcp`, Transport `Streamable HTTP`

**VS Code Copilot** — add to `.vscode/mcp.json`:
```json
{ "servers": { "hierarchy_pai": { "type": "http", "url": "http://localhost:4000/mcp" } } }
```

**Claude Desktop** — add `mcp-remote` bridge in `claude_desktop_config.json`:
```json
{ "mcpServers": { "hierarchy_pai": { "command": "npx", "args": ["-y", "mcp-remote", "http://localhost:4000/mcp"] } } }
```

See [`priv/TOOLS.md`](priv/TOOLS.md) for full schema reference, response shapes, error handling, and rate-limit guidance.

The MCP server is implemented with **ash_ai** (`AshAi.Mcp.Router`), using a Plug-based
transport (no GenServer — no timeout issues for long-running pipelines).

---

## 🗺️ Roadmap / TODO

### 🗄️ Persistence (not yet implemented)

The app is currently **stateless** — all pipeline data (plans, step outputs, final answers) lives only in the LiveView process and is lost on page refresh or server restart. There is no database layer.

Planned persistence work:

- [ ] **Pipeline history** — save each run (task, plan, step outputs, final answer, timestamp) to a database so users can browse and revisit past results
- [ ] **Resume interrupted runs** — if a run is interrupted (browser closed, timeout), allow the user to reload and continue from where it left off
- [ ] **Export results** — download the final answer and step outputs as Markdown or JSON
- [ ] **Provider config persistence** — save LLM provider settings (provider, model, endpoint) in the browser via `localStorage` so users don't have to reconfigure on every visit (API keys should never be persisted server-side)
- [ ] **Authentication** — add user accounts (Ash Authentication) so each user sees only their own pipeline history

### Other planned improvements

- [ ] **Streaming step output in modal** — the step output modal currently shows the final result; stream tokens live as the step executes
- [ ] **File/image input** — allow users to attach files or images as additional context for the task
- [x] **Custom agent personas** — add your own specialist prompts as SKILL.md files in `priv/skills/`; see [Agent Skills](doc/skills.md)
