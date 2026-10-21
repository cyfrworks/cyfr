# syntax=docker/dockerfile:1.7-labs
# (parser directive above must be the first line; needed for COPY --parents)

# ---- The release build ----
FROM hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005@sha256:fd5f8520b3836b8b1e5d5e6dd890d1fda394e4e378bbc0cbc67cd618f321e29b AS builder

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
# Mix through 1.20 can wait forever on its own build lock the second time a
# fresh lock directory is taken, and every build step starts one fresh. One
# Mix process at a time builds here, so the lock is off.
ENV MIX_OS_CONCURRENCY_LOCK=0

WORKDIR /app

# Install hex + rebar (layer cache)
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests first for layer caching. The glob picks up every
# umbrella app's mix.exs (the set of apps varies by build). --parents
# preserves apps/<name>/.
# The pinned wasm-tools every component is validated with
# (`Prima.ComponentFeatures`), its archive checked against the pinned
# sha256 by the one installer (scripts/wasm-tools.sh).
COPY scripts/wasm-tools.sh scripts/wasm-tools.sh
RUN scripts/wasm-tools.sh install /opt/wasm-tools

COPY mix.exs mix.lock ./
COPY --parents apps/*/mix.exs ./

RUN mix deps.get --only prod && mix deps.compile

# Copy all config files (extra release runtime configs are optional)
COPY config/ config/

# Copy application source
COPY apps/ apps/

# Copy top-level guides (embedded at compile time by
# Compendium.Providers.Aqua) and the WIT definitions (embedded by Prima.WIT —
# the compile fails if the tree is missing, so an image can never ship an
# empty ABI)
COPY component-guide.md tincture-guide.md integration-guide.md ./
COPY wit/ wit/

# Full compile + build assets + release
RUN mix compile && mix assets.deploy && mix release cyfr

# ---- The runtime ----
# Runtime libraries, locales and service user. Build toolchains are provided
# by Dockerfile.locus.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f AS runner

# APT_REFRESH busts the build cache for this layer so the upgrade is not
# served stale from a cached layer: CI passes the UTC date (YYYY-MM-DD), so
# the layer refreshes once a day and is shared within it; a local build may
# leave it.
ARG APT_REFRESH=0
RUN echo "apt refresh ${APT_REFRESH}" && apt-get update && apt-get upgrade -y && apt-get install -y \
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
COPY --from=builder /opt/wasm-tools/wasm-tools /usr/local/bin/wasm-tools

# License notices (Fair Source: Apache-2.0 default + FSL-1.1-Apache-2.0 on Sanctum)
COPY LICENSE FAIR_SOURCE.md /app/
COPY LICENSES/ /app/LICENSES/

# The seed tree (`:arca, :seed_path` via CYFR_SEED_PATH below), read in
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
ARG CYFR_HOST_API_PORT=4300
# The endpoint, and the host API the execution workers reach.
EXPOSE ${CYFR_PORT} ${CYFR_HOST_API_PORT}

# Readiness, not liveness: /api/health/ready answers 503 until the DB,
# cache and registries are actually up; start-period covers boot
# migrations. The probe asks the loopback listener at the address it binds
# (CYFR_BIND_ADDRESS: compose fixes cyfr's address on its default network,
# and a bare install binds 127.0.0.1, the default), an IPv6 one in
# brackets.
HEALTHCHECK --interval=10s --timeout=3s --start-period=60s --retries=3 \
    CMD addr="${CYFR_BIND_ADDRESS:-127.0.0.1}"; case "$addr" in *:*) addr="[$addr]";; esac; \
        curl -f "http://$addr:${CYFR_PORT:-4000}/api/health/ready" || exit 1

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["/app/bin/cyfr", "start"]
