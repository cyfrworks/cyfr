# syntax=docker/dockerfile:1.7-labs
# (parser directive above must be the first line; needed for COPY --parents)

ARG RUNNER_BASE=ghcr.io/cyfrworks/cyfr-runner-base:1.0.0

# ---- Stage 1: Builder ----
FROM hexpm/elixir:1.19.5-erlang-28.4.1-debian-bookworm-20260223 AS builder

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

# Copy dependency manifests first for layer caching. The glob picks up every
# umbrella app's mix.exs whether or not apps/arx/ is present (FOSS mirror
# strips it; private repo includes it). --parents preserves apps/<name>/.
COPY mix.exs mix.lock ./
COPY --parents apps/*/mix.exs ./

RUN mix deps.get --only prod && mix deps.compile

# Copy all config files (arx_runtime.exs only present in hosted builds)
COPY config/ config/

# Copy application source
COPY apps/ apps/

# Copy top-level guides (embedded at compile time by Compendium.MCP)
COPY component-guide.md tincture-guide.md integration-guide.md ./
COPY aqua/ aqua/

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

# Copy bundled AQUA orchestrator manifest + prompts to a defaults location.
# Compendium.MCP @aqua_root resolves to /app/aqua at compile time
# (apps/cyfr/lib/compendium/mcp.ex), and docker-entrypoint.sh seeds
# /app/aqua/ from this defaults dir on first start. This pattern works
# whether or not the user has a host volume mount at /app/aqua: empty
# mount → entrypoint seeds it; pre-populated mount → entrypoint skips.
COPY --from=builder /app/aqua /app/aqua-defaults

# gosu for entrypoint privilege drop (standard Docker pattern)
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-$dpkgArch" \
      -o /usr/local/bin/gosu; \
    chmod +x /usr/local/bin/gosu; \
    gosu nobody true

RUN mkdir -p /app/data /app/components \
    && chown -R app:app /app /app/data /app/components

COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 4000 4001

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${CYFR_PORT:-4000}/api/health || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["sh", "-c", "exec /app/bin/$RELEASE start"]
