# ---- Stage 1: Builder ----
FROM hexpm/elixir:1.16.3-erlang-26.2.5-debian-bookworm-20240612 AS builder

RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    curl \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Rust (required for Wasmex NIF compilation)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar (layer cache)
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests first for layer caching
COPY mix.exs mix.lock ./
COPY apps/arca/mix.exs apps/arca/mix.exs
COPY apps/compendium/mix.exs apps/compendium/mix.exs
COPY apps/emissary/mix.exs apps/emissary/mix.exs
COPY apps/locus/mix.exs apps/locus/mix.exs
COPY apps/opus/mix.exs apps/opus/mix.exs
COPY apps/sanctum/mix.exs apps/sanctum/mix.exs
COPY apps/sanctum_arx/mix.exs apps/sanctum_arx/mix.exs

RUN mix deps.get --only prod && mix deps.compile

# Copy config files
COPY config/config.exs config/prod.exs config/

# Compile project (without full source, to cache deps compilation)
RUN mix compile || true

# Copy application source
COPY apps/ apps/

# Copy top-level guides (embedded at compile time by Compendium.MCP)
COPY component-guide.md integration-guide.md ./

# Copy runtime config
COPY config/runtime.exs config/

# Full compile + release
RUN mix compile && mix release cyfr

# ---- Stage 2: Runner ----
FROM debian:bookworm-slim AS runner

RUN apt-get update && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses6 \
    ca-certificates \
    libsqlite3-0 \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/cyfr ./

RUN mkdir -p /app/data /app/components

EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:4000/api/health || exit 1

CMD ["/app/bin/cyfr", "start"]
