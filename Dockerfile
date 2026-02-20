# ============================================================
# Trammo NH3 Trading Desk — Multi-stage Dockerfile
#
# Stage 1 (zig-builder):   Download Zig, clone HiGHS, build
#                           libhighs.a, build solver binary
# Stage 2 (elixir-builder): Build Elixir release
# Stage 3 (runtime):        Minimal runtime image
# ============================================================

# ── Stage 1: Build Zig solver with HiGHS ────────────────────

FROM debian:bookworm-slim AS zig-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Zig (update ZIG_VERSION to match BUILDING_HIGHS.md requirements)
ARG ZIG_VERSION=0.14.0
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" \
      -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /usr/local \
    && mv /usr/local/zig-linux-x86_64-${ZIG_VERSION} /usr/local/zig \
    && ln -s /usr/local/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

# Clone HiGHS at the exact commit used for development
# See native/BUILDING_HIGHS.md — commit f3cf9ff of ERGO-Code/HiGHS (v1.13.1)
WORKDIR /build/HiGHS
RUN git clone --depth 1 https://github.com/ERGO-Code/HiGHS.git . \
    && git fetch --depth 1 origin f3cf9ff \
    && git checkout FETCH_HEAD

# Build HiGHS static library
# This mirrors the steps in native/BUILDING_HIGHS.md
RUN mkdir -p build && \
    INC="-I. \
      -I./highs -I./highs/interfaces -I./highs/io -I./highs/io/filereader \
      -I./highs/ipm -I./highs/ipm/ipx -I./highs/ipm/basiclu \
      -I./highs/lp_data -I./highs/mip -I./highs/model -I./highs/parallel \
      -I./highs/pdlp -I./highs/pdlp/cupdlp -I./highs/presolve \
      -I./highs/qpsolver -I./highs/simplex -I./highs/test_kkt -I./highs/util \
      -I./extern -I./extern/pdqsort -I./extern/zstr" && \
    FLAGS="-O2 -DNDEBUG -DCUPDLP_CPU" && \
    for f in $(find highs -name "*.cpp" -not -path "*/hipo/*"); do \
      zig c++ -std=c++17 $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"; \
    done && \
    for f in $(find highs/ipm/ipx -name "*.cc"); do \
      zig c++ -std=c++17 $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"; \
    done && \
    for f in $(find highs/ipm/basiclu -name "*.c") \
             $(find highs/pdlp/cupdlp -name "*.c" -not -path "*/cuda/*"); do \
      zig cc $FLAGS $INC -c "$f" -o "build/$(echo $f | tr '/' '_').o"; \
    done && \
    ar rcs build/libhighs.a build/*.o && \
    cp build/libhighs.a /usr/local/lib/ && \
    cp highs/interfaces/highs_c_api.h /usr/local/include/ && \
    cp highs/lp_data/HighsCallbackStruct.h /usr/local/include/

# Copy solver source and build
WORKDIR /build/solver
COPY native/solver.zig .
COPY native/highs_c_api.h /usr/local/include/ 2>/dev/null || true
COPY native/HighsCallbackStruct.h /usr/local/include/ 2>/dev/null || true

RUN zig build-exe solver.zig \
      -lhighs -lstdc++ \
      -L/usr/local/lib \
      -I/usr/local/include \
      -lc \
    && chmod +x solver

# ── Stage 2: Build Elixir release ───────────────────────────

FROM hexpm/elixir:1.16-erlang-26-debian-bookworm-slim AS elixir-builder

ENV MIX_ENV=prod

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

# Install Elixir dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Compile dependencies
RUN mix deps.compile

# Copy application source
COPY config config
COPY lib lib
COPY priv priv

# Compile the app and build the release
RUN mix compile
RUN mix release

# ── Stage 3: Runtime image ───────────────────────────────────

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 libssl3 openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
ENV HOME=/app
WORKDIR /app

# Copy Elixir release
COPY --from=elixir-builder /app/_build/prod/rel/trading_desk ./

# Copy solver binary — placed where Solver.Port expects it
# Port looks for: Path.join([File.cwd!(), "native", "solver"]) = /app/native/solver
COPY --from=zig-builder /build/solver/solver ./native/solver
RUN chmod +x ./native/solver

EXPOSE 4111

CMD ["/app/bin/trading_desk", "start"]
