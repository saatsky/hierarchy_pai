# Troubleshooting

Common issues and how to resolve them.

---

## LLM & Provider Errors

### `Request timed out`

**Symptoms**: Red error banner, step moves to Failed column with `timeout` message.

**Causes & fixes**:

| Cause | Fix |
|---|---|
| Local model is slow (large model, low VRAM) | Use a smaller quantised model (e.g. 4-bit Q4 instead of Q8) |
| Jan.ai / Ollama server is not running | Start the server; check the connection indicator in the LLM Provider panel |
| WSL2 network routing issue | Enable WSL2 mode in the provider panel; the app will auto-detect the Windows host IP |
| Cloud provider rate limit | Wait 60 seconds and use **Retry failed** |

**Recovery options** (shown in the Execution Board when a step fails):
- **Retry failed** — re-runs only the failed steps
- **Skip & aggregate** — skips failed steps and synthesises what succeeded
- **Cancel** — returns to idle with your task text preserved

---

### `exceeded max failure count`

**Symptoms**: Planning fails immediately with this error.

**Cause**: The LLM returned a malformed response and the chain ran out of retries.

**Fix**: Increase **Chain retries** in the LLM Provider panel from `0` to `1` or `2`.

> Setting `max_retry_count: 0` means zero tolerance for any bad response — even a single JSON parse error will fail immediately. The minimum recommended value is `1`.

---

### `One or more steps failed in this wave`

**Cause**: At least one executor step failed (usually timeout or bad LLM response).

**What to do**: The Execution Board stays visible with the failed steps in the **Failed** column showing the error message. Use the action panel at the bottom of the board:

1. **Retry failed** — tries those steps again (possibly with a different model per step)
2. **Skip & aggregate** — aggregate with the steps that succeeded
3. **Cancel** — go back to idle

---

### `Planner LLM error: exceeded max failure count`

The Planner agent couldn't produce valid JSON after all retries.

**Fixes**:
1. Increase **Chain retries** to `2`
2. Try a different (larger or more capable) model
3. Simplify your task prompt — very long or ambiguous prompts confuse some models
4. Add explicit instructions: *"Respond only with valid JSON"* at the end of your task

---

### Provider shows as offline

**Jan.ai**:
- Open Jan.ai desktop app
- Go to **Settings → Local API Server** and confirm it shows "Running"
- Check the port (default: `1337`)
- If using WSL2, enable the WSL2 toggle in the provider panel

**Ollama**:
```bash
# Check if Ollama is running
curl http://localhost:11434/api/tags

# Start if not running
ollama serve
```

**Docker**: Local services on your host are not reachable via `localhost`. Use `http://host.docker.internal:1337` (Jan.ai) or `http://host.docker.internal:11434` (Ollama).

---

## Skills Issues

### `GitHub API returned HTTP 404` when clicking "Check for updates"

**Cause**: The `priv/skills/` directory exists locally but has not been pushed to the `main` branch of the `saatsky/hierarchy_pai` repository. The sync button fetches from the GitHub Contents API, which returns 404 if the path doesn't exist on the remote.

**Fix**: Commit and push your local `priv/skills/` directory to the repository:

```bash
git add priv/skills/
git commit -m "Add seed skills"
git push origin main
```

Once pushed, the sync button will return `N new skill(s) loaded from GitHub.`

---

### `GitHub API rate limit exceeded`

**Cause**: Unauthenticated GitHub API calls are limited to 60 requests per hour per IP address.

**Fix**: Wait approximately one hour and try again. The sync fetches each skill file as a separate API call, so repositories with many skills consume more quota.

---

## UI & Browser Issues

### `watchman: not found` in dev server output

**Symptoms**: The following appears in the terminal when running `mix phx.server`:

```
sh: 1: watchman: not found
```

**Cause**: Tailwind v4's standalone CLI checks for Facebook's optional `watchman` file-watching daemon at startup. When absent it falls back to the OS-native watcher (inotify on Linux, FSEvents on macOS) — the warning is informational only.

**Status**: Fixed in the current codebase. A stub `priv/bin/watchman` script is included and added to `PATH` via the tailwind profile's `env` config, which silences the warning without requiring a system-level install.

If you see the warning after a fresh clone, run:

```bash
chmod +x priv/bin/watchman
```

The watcher works correctly regardless — this warning never affects functionality.

---

### Theme toggle clicks but page colours don't change

**Cause**: An earlier version of the app used hardcoded Tailwind slate/gray colour classes throughout the template (`bg-slate-900`, `text-slate-300`, etc.) that don't respond to `data-theme` changes.

**Status**: Fixed — all hardcoded neutral colours have been replaced with DaisyUI semantic classes (`bg-base-100/200/300`, `text-base-content`). The theme toggle now correctly switches between light and dark modes.

**If you still see it**: Do a hard browser refresh (`Ctrl+Shift+R` / `Cmd+Shift+R`) to clear any cached assets. If running Docker, rebuild the image to pick up the updated CSS.

---

### Provider dropdown change does nothing

This was a known bug (fixed): `phx-change` on a bare `<select>` outside a `<form>` sends `%{"value" => ...}` instead of `%{"field_name" => ...}`. The fix wraps all selects in a `<form phx-change="...">`.

If you still see this, **hard-refresh the browser** (`Ctrl+Shift+R` / `Cmd+Shift+R`) to clear cached JavaScript.

---

### API key field not visible after selecting OpenAI / Anthropic

**Fix**: Ensure you are selecting from the dropdown (not typing). If the issue persists, the LiveView socket may have disconnected. Refresh the page — the issue resolves immediately on reconnect.

---

### Execution Board disappears after a step fails

This was a known issue (fixed). The board now stays visible for both `:executing` and `:step_failed` statuses, showing the Failed column with the error reason and an action panel.

---

### Step output modal won't close

Click the dark backdrop behind the modal, press **Escape**, or click the **✕** button in the modal header.

---

## Docker Issues

### `Could not resolve "phoenix-colocated/hierarchy_pai"`

**Cause**: The Docker build was running `mix assets.deploy` before `mix compile`. The `phoenix-colocated/<app>` module is generated during compilation.

**Fix**: The `Dockerfile` has been corrected — `mix compile` now runs before `mix assets.deploy`. Rebuild:

```bash
docker compose build --no-cache
```

---

### `SECRET_KEY_BASE is missing`

The app requires a secret key in production mode.

```bash
# Generate one
mix phx.gen.secret

# Add it to your .env file
echo "SECRET_KEY_BASE=<your_secret>" >> .env

# Or pass it directly
SECRET_KEY_BASE=<your_secret> docker compose up
```

---

### Can't reach Jan.ai from Docker container

Inside Docker, `localhost` refers to the container itself, not your host machine.

**Fix**: Change the **Server URL** in the LLM Provider panel to:
```
http://host.docker.internal:1337
```

On Linux, this requires Docker Engine ≥ 20.10. The `docker-compose.yml` already includes the required `extra_hosts` entry.

---

## Performance

### Tasks take a very long time (>10 minutes)

**Causes**:
1. **Large local model on limited hardware** — the model generates tokens slowly
2. **Many retries on timeout** — each timeout × retry count multiplies wait time
3. **Many accepted steps** — N+2 total LLM calls, all sequential per wave

**Optimisations**:

| Action | Effect |
|---|---|
| Use a smaller quantised model (Q4_K_M) | 2–4× faster inference |
| Set Chain retries to `1` | Prevents triple-length waits |
| Reject steps that aren't needed | Fewer executor calls |
| Use cloud provider (OpenAI / Anthropic) | 10–50× faster than local |
| Assign cheap model to research steps | Faster with similar quality |

---

### Steps run sequentially instead of in parallel

**Cause**: Every step has a `depends_on` pointing to the previous step — the planner created a linear chain.

**What happens**: The orchestrator groups steps into *waves* based on dependencies. If step 2 depends on step 1, step 3 depends on step 2, etc., all steps are in separate waves and run one at a time.

**Fix**: If your task naturally allows parallel work, ask the planner explicitly:

> *"Break this into parallel independent workstreams where possible. Minimise sequential dependencies."*

---

## Getting Help

1. Check the **browser console** (`F12 → Console`) for JavaScript errors
2. Check the **server logs** (`mix phx.server` terminal output) for Elixir errors
3. Use `iex -S mix phx.server` to inspect state interactively
4. Run `mix precommit` to catch compilation and formatting issues
