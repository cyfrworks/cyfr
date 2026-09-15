# syntax=docker/dockerfile:1.7-labs
# (parser directive above must be the first line; needed for COPY --parents)

# ---- Stage 1: Builder ----
FROM hexpm/elixir:1.20.3-erlang-29.0.5-debian-bookworm-20260824 AS builder

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
# Runtime libraries, locales and service user. Build toolchains are provided
# by Dockerfile.builder.
FROM debian:bookworm-slim AS runner

RUN apt-get update && apt-get upgrade -y && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses6 \
    ca-certificates \
    libsqlite3-0 \
    curl \
    locales \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

# Non-root user for runtime (the entrypoint drops to it with setpriv)
RUN groupadd -r app && useradd -r -g app -d /app app

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

LABEL org.opencontainers.image.source="https://github.com/cyfrworks/cyfr"
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
# - seed/aqua — the AQUA tree (the soul, its roles and its scrolls), the
#   operator-editable mount. Defaults are baked at /app/aqua-defaults and
#   docker-entrypoint.sh seeds /app/seed/aqua/ from them on first start.
#   This works whether or not the user has a host volume mount at
#   /app/seed/aqua: empty mount → entrypoint seeds it; pre-populated
#   mount → entrypoint skips.
COPY seed/components/ /app/seed/components/
COPY seed/aqua/ /app/aqua-defaults/
ENV CYFR_SEED_PATH=/app/seed

# Only what the runtime user writes: the release itself stays root-owned
# and read-only to `app` (RELEASE_TMP points the release's generated
# sys.config at /tmp); the entrypoint re-chowns bind-mounted data at start.
RUN mkdir -p /app/data \
    && chown app:app /app/data
ENV RELEASE_TMP=/tmp

COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

ARG CYFR_PORT=4000
EXPOSE ${CYFR_PORT}

# Readiness, not liveness: /api/health/ready answers 503 until the DB,
# cache and registries are actually up; start-period covers boot
# migrations.
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:${CYFR_PORT:-4000}/api/health/ready || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["sh", "-c", "exec /app/bin/cyfr start"]
