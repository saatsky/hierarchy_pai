# Hierarchical Planner AI

> A Hierarchical Multi-Agent AI Planner built with Elixir, Phoenix LiveView, and LangChain.

Hierarchical Planner AI decomposes a complex task into parallel, dependency-aware steps, executes them concurrently using your chosen LLM, and synthesises the results into a single final answer — all within an interactive real-time UI.

---

## ✨ Features

- **Hierarchical planning** — a Planner agent breaks any goal into 3–8 structured steps with explicit dependencies
- **Parallel wave execution** — independent steps run concurrently; dependent steps wait only for their specific prerequisites
- **Real-time Kanban board** — watch steps move through Queue → Running → Done / Failed live
- **Per-step model selection** — assign a different LLM model to each step
- **Step output preview** — click any completed step card to read the full output before it reaches the aggregator
- **Failure recovery** — retry only the failed steps, or skip them and aggregate what succeeded
- **Multiple LLM providers** — local (Jan.ai, Ollama) and cloud (OpenAI, Anthropic, Custom endpoint)
- **Configurable retries** — tune LangChain chain-level retries to balance speed vs reliability
- **Docker-ready** — single `docker compose up --build` to run anywhere

---

## 🏗️ Architecture

```
User Input
    │
    ▼
┌─────────────┐
│   Planner   │  1 LLM call → structured JSON plan (steps + dependencies)
└──────┬──────┘
       │  Plan Review (user accepts/rejects steps, assigns models)
       ▼
┌─────────────────────────────────────┐
│         Execution Waves             │
│  Wave 1: [Step A] [Step B]  ──────► │  parallel via Task.async_stream
│  Wave 2: [Step C]           ──────► │  (C depends on A or B)
│  Wave 3: [Step D]           ──────► │
└──────────────────┬──────────────────┘
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

## 📦 Project Structure

```
hierarchy_pai/
├── lib/
│   ├── hierarchy_pai/
│   │   ├── agents/
│   │   │   ├── planner.ex        # Decomposes task into JSON plan
│   │   │   ├── executor.ex       # Runs a single step with context
│   │   │   └── aggregator.ex     # Synthesises all step outputs
│   │   ├── orchestrator.ex       # Wave-based parallel execution
│   │   └── llm_provider.ex       # Builds LangChain models per provider
│   └── hierarchy_pai_web/
│       ├── live/
│       │   └── planner_live.ex   # Main LiveView (UI + state machine)
│       └── router.ex
├── assets/
│   ├── css/app.css               # Tailwind CSS v4
│   └── js/app.js                 # LiveView + colocated hooks
├── config/
│   ├── config.exs
│   ├── prod.exs
│   └── runtime.exs               # Reads env vars at startup
├── Dockerfile                    # Multi-stage Docker build
├── docker-compose.yml
└── doc/                          # Documentation
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
| [Task Examples](doc/examples.md) | Sample prompts with expected outputs |
| [Troubleshooting](doc/troubleshooting.md) | Common errors and how to fix them |
