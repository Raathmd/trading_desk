# ============================================================
# Trammo NH3 Trading Desk — Runtime Dockerfile
#
# This packages a pre-built release. Before running fly deploy
# you must build locally:
#
#   1. Build HiGHS + solver (once, or when solver.zig changes):
#      See native/BUILDING_HIGHS.md
#      Output: native/solver
#
#   2. Build the Elixir release:
#      MIX_ENV=prod mix deps.get --only prod
#      MIX_ENV=prod mix release
#      Output: _build/prod/rel/trading_desk/
#
#   3. Deploy:
#      fly deploy --local-only
#
# The --local-only flag builds the image on your machine and
# pushes the result to Fly's registry, bypassing the remote builder.
# ============================================================

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 \
      libssl3 \
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

# Copy the pre-built Elixir release
COPY _build/prod/rel/trading_desk ./

# Copy the pre-built Zig solver binary.
# Solver.Port looks for it at: Path.join([File.cwd!(), "native", "solver"])
# File.cwd!() in a release = /app, so this resolves to /app/native/solver
COPY native/solver ./native/solver
RUN chmod +x ./native/solver

EXPOSE 4111

CMD ["/app/bin/trading_desk", "start"]
