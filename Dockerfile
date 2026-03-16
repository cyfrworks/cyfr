ARG RUNNER_BASE=ghcr.io/cyfrworks/cyfr-runner-base:0.21.1

# ---- Stage 1: Builder ----
FROM hexpm/elixir:1.19.0-erlang-27.3.4-debian-bookworm-20250428 AS builder

ARG RELEASE=cyfr

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar (layer cache)
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests first for layer caching
COPY mix.exs mix.lock ./
COPY apps/cyfr/mix.exs apps/cyfr/mix.exs
COPY apps/locus/mix.exs apps/locus/mix.exs
COPY apps/opus/mix.exs apps/opus/mix.exs

RUN mix deps.get --only prod && mix deps.compile

# Copy config files
COPY config/config.exs config/prod.exs config/

# Copy application source
COPY apps/ apps/

# Copy top-level guides (embedded at compile time by Compendium.MCP)
COPY component-guide.md integration-guide.md agent-guide.md ./

# Copy runtime config (including arx_runtime.exs for enterprise release)
COPY config/runtime.exs config/
COPY config/arx_runtime.exs config/

# Full compile + build assets + release
RUN mix compile && mix assets.deploy && mix release ${RELEASE}

# ---- Stage 2: Runner ----
# Pre-built base with Rust + cargo-component (see Dockerfile.runner-base)
# Rebuild with: scripts/build-runner-base.sh
ARG RUNNER_BASE
FROM ${RUNNER_BASE} AS runner

ARG RELEASE=cyfr
ENV RELEASE=${RELEASE}

ENV ELIXIR_ERL_OPTIONS="+fnu"

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/${RELEASE} ./

# Copy WIT interface definitions (needed by scaffolding and compilation)
COPY wit/ wit/

RUN mkdir -p /app/data /app/components \
    && chown -R app:app /app /app/data /app/components

USER app

EXPOSE 4000 4001

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:4000/api/health || exit 1

CMD ["sh", "-c", "exec /app/bin/$RELEASE start"]
