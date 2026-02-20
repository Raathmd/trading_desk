# ============================================================
# Trammo NH3 Trading Desk — Multi-stage Dockerfile
#
# Stage 1: Build the Elixir release on Fly's remote builder
# Stage 2: Minimal runtime image with release + Zig solver
#
# Deploy with:  fly deploy
# ============================================================

# --- Build stage ---
FROM elixir:1.18-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      git \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency manifests first (layer caching)
COPY mix.exs mix.lock ./
COPY config/config.exs config/runtime.exs config/
RUN mix deps.get --only prod && mix deps.compile

# Copy application source
COPY lib lib
COPY priv priv

# Build the release
RUN mix compile && mix release

# --- Runtime stage ---
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 \
      libssl3 \
      libncurses6 \
      openssl \
      ca-certificates \
      locales \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV MIX_ENV=prod
ENV HOME=/app
WORKDIR /app

# Copy the built release from the build stage
COPY --from=build /app/_build/prod/rel/trading_desk ./

# Copy the pre-compiled Linux Zig solver binary.
# Solver.Port looks for it at: Path.join([File.cwd!(), "native", "solver"])
COPY native/solver ./native/solver
RUN chmod +x ./native/solver

EXPOSE 4111

CMD ["/app/bin/trading_desk", "start"]
