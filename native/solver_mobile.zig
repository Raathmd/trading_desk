// ============================================================
// solver_mobile.zig — C ABI export for iOS/Android FFI
//
// This wraps the same LP solver logic as solver.zig but exposes
// a plain C function instead of using the Erlang port protocol.
//
// React Native (or Swift/Kotlin directly) calls these functions via FFI.
//
// Compile targets:
//   iOS (arm64):
//     zig build-lib solver_mobile.zig -lc -target aarch64-macos
//       -I. -L/path/to/highs/lib -lhighs
//       (Xcode wraps as a static lib in the iOS framework)
//
//   Android (arm64-v8a):
//     zig build-lib solver_mobile.zig -lc -target aarch64-linux-android
//       -I. -L/path/to/highs/android/arm64 -lhighs
//       (NDK packages as .so, placed in jniLibs/arm64-v8a/)
//
// See mobile/native/build.zig for the cross-compilation build script.
// ============================================================

const std = @import("std");
const solver = @import("solver.zig");  // re-uses all logic from the main solver

// ── Status codes returned to the caller ─────────────────────
pub const MOBILE_OK          : c_int = 0;
pub const MOBILE_INFEASIBLE  : c_int = 1;
pub const MOBILE_ERROR       : c_int = 2;
pub const MOBILE_BAD_INPUT   : c_int = 3;

// ── C-compatible result struct ───────────────────────────────
//
// Laid out to be trivially readable from Swift (via UnsafePointer) and
// Kotlin/JNI (via ByteBuffer). All f64 values are native-endian.
// The caller allocates this struct; we fill it in.
pub const MobileSolveResult = extern struct {
    status: c_int,          // MOBILE_OK / MOBILE_INFEASIBLE / MOBILE_ERROR

    // Summary
    profit:  f64,
    tons:    f64,
    cost:    f64,
    roi:     f64,

    // Per-route detail (up to 16 routes)
    n_routes:      c_int,
    route_tons:    [16]f64,
    route_profits: [16]f64,
    margins:       [16]f64,

    // Shadow prices per constraint (up to 32)
    n_constraints:  c_int,
    shadow_prices: [32]f64,
};

pub const MobileMonteCarloResult = extern struct {
    status:       c_int,
    n_scenarios:  c_uint,
    n_feasible:   c_uint,
    n_infeasible: c_uint,

    mean:   f64,
    stddev: f64,
    p5:     f64,
    p25:    f64,
    p50:    f64,
    p75:    f64,
    p95:    f64,
    min:    f64,
    max:    f64,

    // Top-6 sensitivity values (variable index + Pearson correlation)
    // (remaining slots are 0)
    n_sensitivity:  c_int,
    sensitivity_idx:  [64]c_int,
    sensitivity_corr: [64]f64,
};

// ── Single solve ─────────────────────────────────────────────
//
// Parameters:
//   model_descriptor  — binary blob (base64-decoded) from GET /api/v1/mobile/model
//   model_len         — byte length of model_descriptor
//   variables         — array of f64 in frame order (from the same model response)
//   n_vars            — number of variables
//   out               — caller-allocated MobileSolveResult, filled on return
//
// Returns MOBILE_OK on success, MOBILE_INFEASIBLE if infeasible, MOBILE_ERROR otherwise.
export fn trading_solve(
    model_descriptor: [*]const u8,
    model_len:        usize,
    variables:        [*]const f64,
    n_vars:           usize,
    out:              *MobileSolveResult,
) callconv(.C) c_int {
    if (model_len == 0 or n_vars == 0) {
        out.status = MOBILE_BAD_INPUT;
        return MOBILE_BAD_INPUT;
    }

    const model_slice = model_descriptor[0..model_len];
    var off: usize = 0;
    const model = solver.parse_model(model_slice, &off);

    // Safety check: n_vars must match model
    const expected_n = @as(usize, model.n_vars);
    const safe_n = @min(n_vars, expected_n);

    var vars: [solver.MAX_VARS]f64 = [_]f64{0} ** solver.MAX_VARS;
    for (0..safe_n) |i| vars[i] = variables[i];

    const result = solver.solve_one(&model, vars[0..expected_n]);

    out.status = switch (result.status) {
        0 => MOBILE_OK,
        1 => MOBILE_INFEASIBLE,
        else => MOBILE_ERROR,
    };

    out.profit  = result.profit;
    out.tons    = result.tons;
    out.cost    = result.cost;
    out.roi     = result.roi;

    out.n_routes = @intCast(result.n_routes);
    for (0..result.n_routes) |i| {
        out.route_tons[i]    = result.route_tons[i];
        out.route_profits[i] = result.route_profits[i];
        out.margins[i]       = result.margins[i];
    }

    out.n_constraints = @intCast(result.n_constraints);
    for (0..result.n_constraints) |i| {
        out.shadow_prices[i] = result.shadow[i];
    }

    return out.status;
}

// ── Monte Carlo ──────────────────────────────────────────────
//
// Parameters:
//   model_descriptor — same as above
//   model_len
//   center           — center-point variable values
//   n_vars
//   n_scenarios      — number of MC scenarios to run (recommend 500-2000 on device)
//   out              — caller-allocated MobileMonteCarloResult
export fn trading_monte_carlo(
    model_descriptor: [*]const u8,
    model_len:        usize,
    center:           [*]const f64,
    n_vars:           usize,
    n_scenarios:      c_uint,
    out:              *MobileMonteCarloResult,
) callconv(.C) c_int {
    if (model_len == 0 or n_vars == 0) {
        out.status = MOBILE_BAD_INPUT;
        return MOBILE_BAD_INPUT;
    }

    const model_slice = model_descriptor[0..model_len];
    var off: usize = 0;
    const model = solver.parse_model(model_slice, &off);

    const expected_n = @as(usize, model.n_vars);
    const safe_n = @min(n_vars, expected_n);

    var center_arr: [solver.MAX_VARS]f64 = [_]f64{0} ** solver.MAX_VARS;
    for (0..safe_n) |i| center_arr[i] = center[i];

    const mc = solver.run_monte_carlo(&model, center_arr[0..expected_n], n_scenarios);

    out.status       = MOBILE_OK;
    out.n_scenarios  = mc.n_scenarios;
    out.n_feasible   = mc.n_feasible;
    out.n_infeasible = mc.n_infeasible;
    out.mean         = mc.mean;
    out.stddev       = mc.stddev;
    out.p5           = mc.p5;
    out.p25          = mc.p25;
    out.p50          = mc.p50;
    out.p75          = mc.p75;
    out.p95          = mc.p95;
    out.min          = mc.min;
    out.max          = mc.max;

    // Copy top sensitivity values (already sorted by abs correlation in the solver)
    const n_sens = @min(@as(usize, @intCast(mc.n_vars)), 64);
    out.n_sensitivity = @intCast(n_sens);
    for (0..n_sens) |i| {
        out.sensitivity_idx[i]  = @intCast(i);
        out.sensitivity_corr[i] = mc.sensitivity[i];
    }

    return MOBILE_OK;
}

// ── Version string ───────────────────────────────────────────
// Allows the mobile app to verify it is running the right solver version.
export fn trading_solver_version() callconv(.C) [*:0]const u8 {
    return "trading_desk_solver_v2_mobile";
}
