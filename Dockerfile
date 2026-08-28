# syntax=docker/dockerfile:1.7-labs
# (parser directive above must be the first line; needed for COPY --parents)

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
# Runtime base inlined: shared libraries, locales and the runtime user —
# and deliberately NO toolchains (cargo/npm live in Dockerfile.builder;
# this image structurally cannot run builds). It used to be a separately
# pushed cyfr-runner-base image, which earned its keep only while it
# carried the minutes-long cargo-component compile; a 30-second apt layer
# does not justify an out-of-band artifact the build must wait on.
FROM debian:bookworm-slim AS runner

RUN apt-get update && apt-get install -y \
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

# Non-root user for runtime (the entrypoint drops to it via gosu)
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
