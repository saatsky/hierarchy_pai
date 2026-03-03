# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM elixir:1.18.3-otp-27-slim AS build

# Install build tools
RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Set build env
ENV MIX_ENV=prod

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Fetch dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Copy config so compile can resolve compile-time config
COPY config config

# Compile dependencies
RUN mix deps.compile

# Copy application source
COPY lib lib
COPY priv priv
COPY assets assets

# Compile the app FIRST — this generates the phoenix-colocated/<app> module
# that assets/js/app.js imports (esbuild will fail without it)
RUN mix compile

# Build assets (downloads esbuild/tailwind binaries, then minifies)
RUN mix assets.deploy

# Build the release
RUN mix release

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS app

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV PHX_SERVER=true

WORKDIR /app

# Copy release from build stage
COPY --from=build /app/_build/prod/rel/hierarchy_pai ./

# Create non-root user for security
RUN useradd --create-home appuser && chown -R appuser /app
USER appuser

EXPOSE 4000

CMD ["bin/hierarchy_pai", "start"]
