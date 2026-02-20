# ============================================================
# Trammo NH3 Trading Desk — Runtime Dockerfile
#
# This packages pre-built artifacts. Before deploying you must:
#
#   1. Cross-compile the solver for Linux x86_64 (once, or when
#      solver.zig changes). From the native/ directory:
#
#      zig build-exe solver.zig \
#        -target x86_64-linux-gnu \
#        -lhighs -lstdc++ \
#        -L./HiGHS/build/lib \
#        -I./HiGHS/src \
#        -I./HiGHS/build \
#        -lc \
#        -femit-bin=solver.linux-amd64
#
#      Then commit native/solver.linux-amd64 to git.
#
#   2. Build the Elixir release:
#      MIX_ENV=prod mix deps.get --only prod
#      MIX_ENV=prod mix release
#      Output: _build/prod/rel/trading_desk/
#
#   3. Deploy (standard — no --local-only needed if solver is committed):
#      fly deploy
#
#   OR skip step 2 and deploy with pre-built release locally:
#      fly deploy --local-only
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

# Copy the cross-compiled Linux Zig solver binary.
# Solver.Port looks for it at: Path.join([File.cwd!(), "native", "solver"])
# File.cwd!() in a release = /app, so this resolves to /app/native/solver
COPY native/solver.linux-amd64 ./native/solver
RUN chmod +x ./native/solver

EXPOSE 4111

CMD ["/app/bin/trading_desk", "start"]
