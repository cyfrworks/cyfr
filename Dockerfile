# syntax=docker/dockerfile:1.7-labs
# (parser directive above must be the first line; needed for COPY --parents)

ARG RUNNER_BASE=ghcr.io/cyfrworks/cyfr-runner-base:1.0.0

# ---- Stage 1: Builder ----
FROM hexpm/elixir:1.20.0-erlang-29.0.2-debian-bookworm-20260610 AS builder

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
# umbrella app's mix.exs (the set of apps varies by build). --parents
# preserves apps/<name>/.
COPY mix.exs mix.lock ./
COPY --parents apps/*/mix.exs ./

RUN mix deps.get --only prod && mix deps.compile

# Copy all config files (extra release runtime configs are optional)
COPY config/ config/

# Copy application source
COPY apps/ apps/

# Copy top-level guides (embedded at compile time by Compendium.MCP) and the
# WIT definitions (embedded by Compendium.WITSource — the compile fails if
# the tree is missing, so an image can never ship an empty ABI)
COPY component-guide.md tincture-guide.md integration-guide.md ./
COPY wit/ wit/

# Full compile + build assets + release
RUN mix compile && mix assets.deploy && mix release cyfr

# ---- Stage 2: Runner ----
# Pre-built base with Rust + cargo-component (see Dockerfile.runner-base)
# Rebuild with: scripts/build-runner-base.sh
ARG RUNNER_BASE
FROM ${RUNNER_BASE} AS runner

LABEL org.opencontainers.image.licenses="Apache-2.0 AND FSL-1.1-Apache-2.0"

ENV ELIXIR_ERL_OPTIONS="+fnu"

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/cyfr ./

# License notices (Fair Source: Apache-2.0 default + FSL-1.1-Apache-2.0 on Sanctum)
COPY LICENSE FAIR_SOURCE.md /app/
COPY LICENSES/ /app/LICENSES/

# The seed tree (`:cyfr, :seed_path` via CYFR_SEED_PATH below), read in
# place — one root, two kinds of media:
#
# - seed/components — the bundle every athanor is provisioned from. Baked
#   into the image, no first-boot copy, no bind mount: a bare image boot
#   can always mint athanors.
# - seed/aqua — the AQUA agent template (manifest + prompts), the
#   operator-editable mount. Defaults are baked at /app/aqua-defaults and
#   docker-entrypoint.sh seeds /app/seed/aqua/ from them on first start.
#   This works whether or not the user has a host volume mount at
#   /app/seed/aqua: empty mount → entrypoint seeds it; pre-populated
#   mount → entrypoint skips.
COPY seed/components/ /app/seed/components/
COPY seed/aqua/ /app/aqua-defaults/
ENV CYFR_SEED_PATH=/app/seed

# gosu for entrypoint privilege drop (standard Docker pattern). Checksum-
# pinned: `gosu nobody true` is a liveness check, not an integrity check,
# and this binary runs as root at every container start.
RUN set -eux; \
    dpkgArch="$(dpkg --print-architecture)"; \
    case "$dpkgArch" in \
      amd64) gosuSha="bbc4136d03ab138b1ad66fa4fc051bafc6cc7ffae632b069a53657279a450de3" ;; \
      arm64) gosuSha="c3805a85d17f4454c23d7059bcb97e1ec1af272b90126e79ed002342de08389b" ;; \
      *) echo "unsupported architecture: $dpkgArch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tianon/gosu/releases/download/1.17/gosu-$dpkgArch" \
      -o /usr/local/bin/gosu; \
    echo "$gosuSha  /usr/local/bin/gosu" | sha256sum -c -; \
    chmod +x /usr/local/bin/gosu; \
    gosu nobody true

RUN mkdir -p /app/data \
    && chown -R app:app /app /app/data

COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:${CYFR_PORT:-4000}/api/health || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["sh", "-c", "exec /app/bin/cyfr start"]
