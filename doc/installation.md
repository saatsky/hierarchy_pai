# Installation Guide

This guide covers three ways to run Hierarchical Planner AI:

1. [Local development](#local-development) — for hacking on the code
2. [Docker](#docker) — easiest way to share with others
3. [Mix Release](#mix-release) — production-grade binary

---

## Local Development

### Prerequisites

- **Elixir 1.15+** and **Erlang/OTP 26+**
  - Recommended: install via [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/)
  - macOS: `brew install elixir`
  - Ubuntu: follow [official Elixir install guide](https://elixir-lang.org/install.html)

- **Git**

### Steps

```bash
# 1. Clone the repository
git clone <repository-url>
cd hierarchy_pai

# 2. Install Elixir dependencies and set up assets
mix setup
# This runs: mix deps.get + tailwind.install + esbuild.install

# 3. Start the development server
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

The server has **live reload** — changes to Elixir files, templates, and CSS/JS will be reflected immediately without restarting.

### Running in IEx (interactive shell)

```bash
iex -S mix phx.server
```

Useful for inspecting state and calling functions interactively.

---

## Docker

Docker is the easiest way to run the app on another machine — the recipient only needs Docker installed.

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac / Windows)
- or Docker Engine + Docker Compose plugin (Linux)

### Steps

```bash
# 1. Generate a secret key base
#    If you have Elixir installed:
mix phx.gen.secret

#    Without Elixir:
docker run --rm elixir:1.18.3-otp-27-slim mix phx.gen.secret

# 2. Create your environment file
cp .env.example .env
```

Edit `.env`:

```dotenv
SECRET_KEY_BASE=paste_your_64_char_secret_here
PHX_HOST=localhost
```

```bash
# 3. Build the Docker image and start
docker compose up --build

# To run in the background
docker compose up --build -d

# To stop
docker compose down
```

Open [http://localhost:4000](http://localhost:4000).

### Using Jan.ai with Docker

Docker containers cannot reach `localhost` on your host machine directly. When running inside Docker, change the **Server URL** in the LLM Provider panel from:

```
http://localhost:1337
```

to:

```
http://host.docker.internal:1337
```

This works automatically on Docker Desktop (Mac/Windows). On Linux, the `docker-compose.yml` already includes `extra_hosts: host.docker.internal:host-gateway` to enable this.

### Building a shareable image

```bash
# Save image to a tar file
docker save hierarchy_pai:latest | gzip > hierarchy_pai.tar.gz

# On the recipient's machine
docker load < hierarchy_pai.tar.gz
docker compose up
```

---

## Mix Release

A Mix Release bundles your app with the Erlang VM into a self-contained directory. No Elixir or Erlang installation needed on the target machine — but the **OS must match** the build machine.

### Building

```bash
# 1. Set the environment
export MIX_ENV=prod

# 2. Install production dependencies
mix deps.get --only prod

# 3. Compile
mix compile

# 4. Build assets
mix assets.deploy

# 5. Build the release
mix release
# Output: _build/prod/rel/hierarchy_pai/
```

### Running

```bash
export SECRET_KEY_BASE=$(mix phx.gen.secret)
export PHX_HOST=localhost
export PORT=4000
export PHX_SERVER=true

./_build/prod/rel/hierarchy_pai/bin/hierarchy_pai start
```

### Distributing

Zip the entire `_build/prod/rel/hierarchy_pai/` directory and send it. On the target machine, unzip and run the `bin/hierarchy_pai` script with the same environment variables.

> ⚠️ **OS compatibility**: A release built on Linux will not run on macOS, and vice versa.
> For cross-platform distribution, use Docker instead.

---

## Environment Variables Reference

| Variable | Required | Default | Notes |
|---|---|---|---|
| `SECRET_KEY_BASE` | **Yes** (prod/Docker) | — | Generate with `mix phx.gen.secret`. Must be ≥ 64 chars |
| `PHX_HOST` | No | `localhost` | The hostname users access the app at |
| `PORT` | No | `4000` | HTTP port to bind on |
| `PHX_SERVER` | No | — | Set to `true` in releases to start the HTTP server |
| `DNS_CLUSTER_QUERY` | No | — | For clustering multiple nodes |

LLM API keys (OpenAI, Anthropic) are entered through the UI at runtime and are **never stored** server-side.
