# TraderDesk Mobile App

Native iOS and Android app for on-device LP solving using the Zig HiGHS solver.

## Architecture

```
Elixir Server (Phoenix)
  │
  ├── GET  /api/v1/mobile/model          ← fetch model payload (variables + descriptor)
  ├── POST /api/v1/mobile/solves         ← save device-side solve result
  ├── GET  /api/v1/mobile/thresholds     ← fetch current delta thresholds
  └── WS   /mobile/websocket             ← live alerts + variable updates
       ├── alerts:<product_group>         ← threshold breach events
       └── variables:<product_group>      ← live variable values

React Native App (TraderDesk/)
  ├── ModelScreen   — displays model structure, variables, route layout
  ├── SolveResultScreen — shows LP result or Monte Carlo distribution
  ├── AlertsScreen  — threshold breach notifications from server
  └── SettingsScreen — server URL, token, alert subscriptions

Zig Solver (native/solver_mobile.zig)
  ├── trading_solve()        — runs single LP solve on-device
  ├── trading_monte_carlo()  — runs stochastic analysis on-device
  └── trading_solver_version() — version string
```

## Solver binary protocol

The app fetches a **binary model descriptor** from the server (`descriptor` field in the model response, base64-encoded). This descriptor encodes the full LP topology:
- Number of variables, routes, constraints
- Objective mode (max_profit / min_cost / max_roi / cvar_adjusted / min_risk)
- Route definitions (sell/buy/freight variable indices, transit costs, unit capacity)
- Constraint definitions (supply/demand/fleet/capital/custom)
- Perturbation specs for Monte Carlo

The app passes this descriptor + current variable values directly to the Zig solver via native FFI. No LP library is needed in JS — all solving happens in compiled Zig + HiGHS.

## Building the solver library

### Prerequisites
- [Zig 0.15.2+](https://ziglang.org/download/)
- HiGHS static library for each target (see `native/BUILDING_HIGHS.md`)

### iOS (arm64)
```bash
# Build HiGHS for iOS arm64 first, then:
cd trading_desk
zig build --build-file native/build_mobile.zig ios \
  -Dtarget=aarch64-macos \
  -Doptimize=ReleaseFast

# Copy output to Xcode project:
cp zig-out/lib/libtrading_solver.a mobile/TraderDesk/ios/Frameworks/
```

### Android (arm64-v8a)
```bash
zig build --build-file native/build_mobile.zig android \
  -Dtarget=aarch64-linux-android \
  -Doptimize=ReleaseFast

cp zig-out/lib/libtrading_solver.so \
  mobile/TraderDesk/android/src/main/jniLibs/arm64-v8a/
```

### Android (x86_64 — for emulator)
```bash
zig build --build-file native/build_mobile.zig android \
  -Dtarget=x86_64-linux-android \
  -Doptimize=ReleaseFast

cp zig-out/lib/libtrading_solver.so \
  mobile/TraderDesk/android/src/main/jniLibs/x86_64/
```

## Setting up the React Native project

```bash
cd mobile/TraderDesk
npm install

# iOS
npx pod-install ios
npx react-native run-ios

# Android
npx react-native run-android
```

## Authentication

The mobile app uses Bearer token auth. In development, use:
```
Authorization: Bearer dev-token-<your-email>
```

In production, create tokens via the admin UI (or seed them in the DB).

## WebSocket channels

Connect to `wss://<server>/mobile/websocket?token=<token>` then join:

- `alerts:ammonia_domestic` — receive threshold breach events
- `variables:ammonia_domestic` — receive live variable updates

Threshold breach event payload:
```json
{
  "variable": "nola_buy",
  "current": 328.5,
  "baseline": 320.0,
  "delta": 8.5,
  "threshold": 2.0,
  "product_group": "ammonia_domestic",
  "timestamp": "2026-02-22T10:30:00Z"
}
```

## Offline mode

- The app caches the last fetched model in MMKV (available offline)
- Solve results are saved locally first, then synced to the server
- If the server is unreachable, saves queue in `offline_save_queue`
- The queue is flushed automatically on reconnect, or manually via Settings → Sync Now
