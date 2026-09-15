# syntax=docker/dockerfile:1.7-labs
# The builder container: the toolchain half of Locus and nothing else.
# The app image (Dockerfile) carries no compilers; this one carries no
# endpoint, no database and no tenant state — sources arrive in the
# request, artifacts leave in the response.
#
# Process model: cyfr-spawn runs as root holding only SETUID, SETGID and
# KILL (it refuses to start with any other capability), starts the builder
# release as cyfr-builder, and runs every build under a pooled uid of its
# own (cyfr-build01…cyfr-build16) with a 0700 home under
# /var/lib/cyfr-builder/homes. When a build ends every process of its uid
# is killed and everything the uid left is removed before another build
# gets it; the builder release refuses to serve builds without cyfr-spawn.

# ---- cyfr-spawn, the process helper: a static Go binary, pinned to the Go
# release apps/spawn/go.mod names ----
FROM golang:1.26.5-alpine AS spawn
WORKDIR /src
COPY apps/spawn/go.mod apps/spawn/go.sum ./
RUN go mod download
COPY apps/spawn/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cyfr-spawn .

# ---- Stage 1: release build ----
FROM hexpm/elixir:1.20.3-erlang-29.0.5-debian-bookworm-20260824 AS relbuilder

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY --parents apps/*/mix.exs ./

RUN mix deps.get --only prod && mix deps.compile

COPY config/ config/
COPY apps/ apps/
COPY component-guide.md tincture-guide.md integration-guide.md ./
COPY wit/ wit/

RUN mix compile && mix release builder

# ---- Stage 2: toolchain runtime ----
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/cyfrworks/cyfr"
# The release loads (never starts) the cyfr app, which carries lib/sanctum's
# FSL-licensed modules.
LABEL org.opencontainers.image.licenses="Apache-2.0 AND FSL-1.1-Apache-2.0"

RUN apt-get update && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses6 \
    ca-certificates \
    libsqlite3-0 \
    curl \
    locales \
    build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen

ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH="/usr/local/cargo/bin:$PATH"

# rustup-init is version- and checksum-pinned (hashes from
# static.rust-lang.org's own .sha256 files) instead of `curl | sh` of a
# moving script that runs as root at build time.
ARG RUSTUP_VERSION=1.28.2
ARG CARGO_COMPONENT_VERSION=0.21.1
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) RUST_TRIPLE=x86_64-unknown-linux-gnu; RUSTUP_SHA=20a06e644b0d9bd2fbdbfd52d42540bdde820ea7df86e92e533c073da0cdd43c ;; \
         arm64) RUST_TRIPLE=aarch64-unknown-linux-gnu; RUSTUP_SHA=e3853c5a252fca15252d07cb23a1bdd9377a8c6f3efa01531109281ae47f841c ;; \
         *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
       esac \
    && curl --proto '=https' --tlsv1.2 -fsSL \
       "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUST_TRIPLE}/rustup-init" \
       -o /tmp/rustup-init \
    && echo "${RUSTUP_SHA}  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal \
    && rm /tmp/rustup-init \
    && rustup target add wasm32-wasip1 wasm32-wasip2 \
    && cargo install --locked cargo-component@${CARGO_COMPONENT_VERSION} \
    && rm -rf /usr/local/cargo/registry /usr/local/cargo/git \
    && mkdir -p /usr/local/cargo/registry /usr/local/cargo/git

# Node.js LTS for tincture builds (npm + Vite). Direct binary install,
# checksum-pinned against nodejs.org's SHASUMS256.txt for this version.
ARG NODE_VERSION=24.21.0
RUN ARCH=$(dpkg --print-architecture) \
    && case "$ARCH" in \
         amd64) NODE_ARCH=x64; NODE_SHA=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6 ;; \
         arm64) NODE_ARCH=arm64; NODE_SHA=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2 ;; \
         *) echo "Unsupported architecture: $ARCH" && exit 1 ;; \
       esac \
    && curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
       -o /tmp/node.tar.xz \
    && echo "${NODE_SHA}  /tmp/node.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# The toolchains stay root-owned: a build reads them and writes only its
# own home, so no build can alter what the next one compiles with. A build
# runs with cyfr-spawn's fixed PATH, so the Rust toolchain's commands are
# linked into /usr/local/bin.
RUN ln -s /usr/local/cargo/bin/* /usr/local/bin/

# The builder release's user and the build pool: each user is alone in its
# own group and belongs to no other. /run/cyfr-builder holds the release's
# temporary files and the attach socket builds' relays connect to.
RUN groupadd -r -g 10001 cyfr-builder \
    && useradd -r -u 10001 -g cyfr-builder -d /nonexistent -M -s /usr/sbin/nologin cyfr-builder \
    && for i in $(seq 1 16); do \
         name="$(printf 'cyfr-build%02d' "$i")"; uid=$((30000 + i)); \
         groupadd -r -g "$uid" "$name" \
         && useradd -r -u "$uid" -g "$name" -d /nonexistent -M -s /usr/sbin/nologin "$name" || exit 1; \
       done \
    && install -d -m 1733 -o root -g root /var/lib/cyfr-builder/homes \
    && install -d -m 0700 -o cyfr-builder -g cyfr-builder /run/cyfr-builder

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8
ENV ELIXIR_ERL_OPTIONS="+fnu"

WORKDIR /app

COPY --from=spawn /out/cyfr-spawn /usr/local/bin/cyfr-spawn
COPY --from=relbuilder /app/_build/prod/rel/builder ./
COPY LICENSE FAIR_SOURCE.md /app/
COPY LICENSES/ /app/LICENSES/

# The crates every scaffolded Rust component depends on, fetched once into
# a root-owned Cargo home; each build copies its registry cache into the
# build's own Cargo home (`CYFR_BUILD_CARGO_SEED`). The manifests are the
# release's own templates, so the seed follows the scaffold.
ENV CYFR_BUILD_CARGO_SEED=/opt/cyfr/cargo-seed
RUN /app/bin/builder eval ' \
      for type <- [:reagent, :catalyst, :formula] do \
        dir = Path.join("/tmp/cargo-seed", Atom.to_string(type)); \
        File.mkdir_p!(Path.join(dir, "src")); \
        File.write!(Path.join(dir, "src/lib.rs"), ""); \
        File.write!(Path.join(dir, "Cargo.toml"), Locus.Builder.cargo_toml_for(type)) \
      end' \
    && for manifest in /tmp/cargo-seed/*/Cargo.toml; do \
         CARGO_HOME="$CYFR_BUILD_CARGO_SEED" cargo fetch --manifest-path "$manifest" || exit 1; \
       done \
    && rm -rf /tmp/cargo-seed

# No `COPY wit/` here: Compendium.WITSource embeds the whole WIT tree at
# COMPILE time (stage 1 copies it for that), and the runtime never reads
# it from disk — a release without its ABI fails the build instead.

# The release starts no Erlang distribution: a listener any build could
# reach, authenticated by a cookie any build could read. Its temporary
# files go where only its own user can reach them.
ENV RELEASE_DISTRIBUTION=none \
    RELEASE_TMP=/run/cyfr-builder

ARG CYFR_BUILDER_PORT=4100
EXPOSE ${CYFR_BUILDER_PORT}

HEALTHCHECK --interval=10s --timeout=3s --start-period=20s --retries=3 \
    CMD curl -f http://localhost:${CYFR_BUILDER_PORT:-4100}/health || exit 1

# Run with `cap_drop: [ALL]`, `cap_add: [SETUID, SETGID, KILL]`,
# `no-new-privileges`, a read-only root, `ipc: none` and the homes and
# /run/cyfr-builder tmpfs mounts (docker-compose.yml's builder service).
ENTRYPOINT ["cyfr-spawn", "serve", "--pool", "build:30001-30016", "--home-root", "/var/lib/cyfr-builder/homes", "--client-user", "cyfr-builder", "--", "/app/bin/builder", "start"]
