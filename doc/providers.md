# LLM Provider Setup

Hierarchical Planner AI uses **Saved Providers** as the single source of LLM configuration. All provider credentials are registered once in the **Saved Providers** panel and reused throughout the pipeline — no environment variables or config files required.

> **Before running any task**, you must add at least one provider in the **Saved Providers** panel. The Run Planner button is disabled until a provider exists.

---

## Providers at a Glance

| Provider | Type | API Key | Model Selection |
|---|---|---|---|
| Jan.ai | Local | None | Auto-detected |
| Ollama | Local | None | Auto-detected |
| OpenAI | Cloud | Required | Dropdown |
| Anthropic | Cloud | Required | Dropdown |
| GitHub Models | Cloud | Fine-grained PAT | Dropdown |
| Custom endpoint | Any | Optional | Free text |

---

## Jan.ai (Recommended for local use)

[Jan.ai](https://jan.ai) is a desktop app that runs open-source LLMs locally with an OpenAI-compatible API.

### Setup

1. Download and install [Jan.ai](https://jan.ai)
2. Open Jan.ai and download a model (e.g. `llama3.2`, `mistral`, `deepseek-r1`)
3. In Jan.ai settings, enable the **Local API Server** (default port: `1337`)
4. In Hierarchical Planner AI, select **Jan.ai (local)** as the provider
5. The app will auto-detect the running models

### Server URL

| Environment | URL |
|---|---|
| Local dev | `http://localhost:1337` |
| WSL2 | Auto-detected (uses Windows host IP) |
| Docker | `http://host.docker.internal:1337` |

### Recommended Models

For best planning quality with Jan.ai, prefer instruction-tuned models:

| Model | Size | Quality | Speed |
|---|---|---|---|
| `llama3.2-3b-instruct` | 3B | Good | Fast |
| `llama3.1-8b-instruct` | 8B | Better | Medium |
| `mistral-7b-instruct` | 7B | Good | Medium |
| `deepseek-r1-7b` | 7B | Good | Medium |
| `qwen2.5-14b-instruct` | 14B | Best | Slow |

> **Tip**: Local models are slower than cloud models. Start with a small model (3B–7B) to test the pipeline, then switch to a larger one for quality results. Set **Max retries** to `1` to avoid long waits on timeouts.

---

## Ollama

[Ollama](https://ollama.com) is a lightweight CLI for running local LLMs.

### Setup

```bash
# Install (macOS/Linux)
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model
ollama pull llama3.2
ollama pull mistral

# Ollama starts automatically on port 11434
```

1. In Hierarchical Planner AI, select **Ollama (local)**
2. Available models will be auto-detected

### Server URL

| Environment | URL |
|---|---|
| Local dev | `http://localhost:11434` |
| Docker | `http://host.docker.internal:11434` |

---

## OpenAI

### Setup

1. Create an account at [platform.openai.com](https://platform.openai.com)
2. Go to **API Keys** → **Create new secret key**
3. In Hierarchical Planner AI:
   - Select **OpenAI** as the provider
   - Paste your API key (starts with `sk-...`)
   - Select a model from the dropdown

### Available Models

| Model | Best for | Cost |
|---|---|---|
| `gpt-4o` | Best quality, complex tasks | Higher |
| `gpt-4o-mini` | Good balance of quality/speed/cost | Low |
| `gpt-3.5-turbo` | Fast, simple tasks | Lowest |

> Your API key is only held in browser memory for the current session and is never stored on the server.

---

## Anthropic

### Setup

1. Create an account at [console.anthropic.com](https://console.anthropic.com)
2. Go to **API Keys** → **Create Key**
3. In Hierarchical Planner AI:
   - Select **Anthropic** as the provider
   - Paste your API key (starts with `sk-ant-...`)
   - Select a model from the dropdown

### Available Models

| Model | Best for | Cost |
|---|---|---|
| `claude-opus-4-5` | Highest quality, complex reasoning | Higher |
| `claude-sonnet-4-5` | Excellent balance | Medium |
| `claude-haiku-4-5` | Fast, lightweight tasks | Low |

---

## Custom Endpoint

Use any OpenAI-compatible API (e.g. LM Studio, vLLM, Together AI, Groq, etc.)

### Setup

1. Select **Custom endpoint**
2. Enter the **Server URL** (e.g. `http://localhost:1234`)
3. Optionally enter an **API Key** if required
4. Type the **model name** exactly as the endpoint expects it

### Example — LM Studio

```
Server URL: http://localhost:1234
Model:      lmstudio-community/Meta-Llama-3.1-8B-Instruct-GGUF
```

### Example — Groq (cloud)

```
Server URL: https://api.groq.com/openai
API Key:    gsk_...
Model:      llama-3.3-70b-versatile
```

---

## Choosing the Right Provider

| Scenario | Recommendation |
|---|---|
| Privacy-first, offline use | Jan.ai or Ollama |
| Best quality, no setup | OpenAI `gpt-4o` |
| Best reasoning | Anthropic `claude-opus-4-5` |
| Low cost, high volume | OpenAI `gpt-4o-mini` or Anthropic `claude-haiku-4-5` |
| Testing / development | Jan.ai with a 3B–7B model |

---

## Timeout & Retry Settings

Found in the **LLM Provider** panel under **Chain retries (bad response)**:

| Setting | Meaning |
|---|---|
| `0` | No retries — fail immediately on any bad response |
| `1` (default) | One retry — handles transient JSON parse errors |
| `2–3` | More resilient — recommended for cloud providers |

> **Local models**: set retries to `1`. Retries can triple your wait time if the model times out.
> **Cloud providers**: `2` is a safe default.

---

## GitHub Models

GitHub Models exposes an OpenAI-compatible inference API at `https://models.github.ai/inference`.
This is the official GitHub service for accessing AI models, not the GitHub Copilot coding assistant.

### Requirements
- A free GitHub account (rate-limited) or a **GitHub Models** subscription
- A **fine-grained Personal Access Token** with the **`models:read`** scope

### Setup

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Create a new token with the **`models:read`** permission enabled
3. In Hierarchical Planner AI, select **GitHub Models** as the provider
4. Paste the `github_pat_...` token in the API Key field
5. The endpoint (`https://models.github.ai/inference/chat/completions`) is pre-filled automatically

> **Note**: Classic PATs (`ghp_...`) do **not** work — only fine-grained PATs (`github_pat_...`) support the `models:read` scope.

### Available Models

| Model | Notes |
|---|---|
| `openai/gpt-4o` | Best quality |
| `openai/gpt-4o-mini` | Faster, lower cost |
| `openai/o3-mini` | Reasoning model |
| `anthropic/claude-3-5-sonnet` | Anthropic via GitHub Models |
| `anthropic/claude-3-5-haiku` | Faster Anthropic model |
| `meta/meta-llama-3.1-405b-instruct` | Open-source Llama |
| `mistral-ai/mistral-large-2407` | Mistral model |

> Model names must include the `{publisher}/{model}` prefix as shown above.

---

## Saved Providers

The **Saved Providers** panel is the **primary and required** way to configure LLM providers. Every saved provider is stored in ETS (shared across browser sessions on the same server node) and can be selected for:

1. **Planner & Aggregator** — chosen via the **Planner Provider** dropdown in the sidebar
2. **Individual steps** — overridable per-step in the **Review** phase

### Why use saved providers?

- **Required to run**: the planner can only execute when at least one provider is saved
- Mix providers per step — e.g. use a fast local model for research and GPT-4o for writing
- Store credentials once, reuse across the session
- Quickly switch between configurations without re-entering API keys

### Managing saved providers

| Action | How |
|---|---|
| **Add** | Click **+ Add** in the Saved Providers panel |
| **Edit** | Click the pencil icon next to any saved provider |
| **Delete** | Click the trash icon |

### Selecting the planner provider

The **Planner Provider** card (above the task input) shows a dropdown of all saved providers. The selected provider is used for:
- The **Planner** agent (generates the step plan)
- The **Aggregator** agent (synthesises the final answer)
- As the **default** for any step that has no per-step override

When a new provider is saved and no planner provider is selected yet, it is automatically selected.

### Using saved providers in Review

When you have saved providers, the per-step provider selector in the Review phase shows two dropdowns:

1. **Provider** — select a saved provider by name (e.g. "My Jan.ai", "GPT-4o")
2. **Model** — list of available models for that provider, defaulting to the model stored in the saved entry

You can override the model per-step without affecting the saved entry.

### Lifecycle

> ⚠️ **Saved providers are stored in memory (ETS).** They are shared across all browser sessions on the same server node but are **lost when the server restarts**. Persistent storage is planned — see the [Roadmap](../README.md#%EF%B8%8F-roadmap--todo).
