// build_mobile.zig — cross-compile the solver as a shared library for iOS and Android
//
// Usage:
//   zig build --build-file native/build_mobile.zig -Dtarget=aarch64-linux-android
//   zig build --build-file native/build_mobile.zig -Dtarget=aarch64-macos          (iOS sim dev)
//
// The output shared libraries are placed in:
//   mobile/TraderDesk/ios/Frameworks/libtrading_solver.a       (iOS — static)
//   mobile/TraderDesk/android/src/main/jniLibs/<abi>/libtrading_solver.so  (Android)
//
// HiGHS must be pre-built for each target and its lib + headers placed in:
//   native/highs/<target>/lib/libhighs.a
//   native/highs/<target>/include/highs_c_api.h

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Determine output directory ───────────────────────────────────────────
    const target_triple = b.fmt("{s}", .{target.result.zigTriple(b.allocator) catch "unknown"});
    const highs_lib_path = b.fmt("native/highs/{s}/lib", .{target_triple});
    const highs_inc_path = b.fmt("native/highs/{s}/include", .{target_triple});

    // ── Shared library (Android .so) ─────────────────────────────────────────
    const shared = b.addSharedLibrary(.{
        .name = "trading_solver",
        .root_source_file = b.path("native/solver_mobile.zig"),
        .target = target,
        .optimize = optimize,
    });

    shared.addIncludePath(b.path(highs_inc_path));
    shared.addLibraryPath(b.path(highs_lib_path));
    shared.linkSystemLibrary("highs");
    shared.linkLibC();

    b.installArtifact(shared);

    // ── Static library (iOS .a) ──────────────────────────────────────────────
    const static = b.addStaticLibrary(.{
        .name = "trading_solver",
        .root_source_file = b.path("native/solver_mobile.zig"),
        .target = target,
        .optimize = optimize,
    });

    static.addIncludePath(b.path(highs_inc_path));
    static.addLibraryPath(b.path(highs_lib_path));
    static.linkSystemLibrary("highs");
    static.linkLibC();

    const ios_step = b.step("ios", "Build static lib for iOS");
    ios_step.dependOn(&b.addInstallArtifact(static, .{}).step);

    // ── Android packaging step ───────────────────────────────────────────────
    // Maps target arch to Android ABI directory name
    const abi_map = .{
        .{ "aarch64-linux-android", "arm64-v8a" },
        .{ "arm-linux-android", "armeabi-v7a" },
        .{ "x86_64-linux-android", "x86_64" },
        .{ "x86-linux-android", "x86" },
    };
    _ = abi_map;

    const android_step = b.step("android", "Build shared lib for Android");
    android_step.dependOn(&b.addInstallArtifact(shared, .{}).step);
}
