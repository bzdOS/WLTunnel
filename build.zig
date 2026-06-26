// START_AI_HEADER
// MODULE: wayland-tunnel/build.zig
// PURPOSE: Zig build definition for wayland-tunnel — FreeBSD daemon binary.
// INTENT: Standard Zig build.zig with libc linkage for FreeBSD syscalls.
// DEPENDENCIES: std.Build.
// PUBLIC_API: build (pub fn).
// END_AI_HEADER

const std = @import("std");

// build:start
//   purpose: Define build targets, modules, run/test steps for this Zig binary. Registers shared modules (c, wl_shm, stream, etc.) and test targets (test-input, test-stream). Accepts -Dplatform=<str> and injects it as build_options for forward-compat platform capability flags.
//   input:  b: standard Build object from zig build.
//   output: void (registers targets in b).
//   sideEffects: Registers executable, run step, test step in the Zig build graph.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dplatform=<str>  — comptime platform selector, threaded from the Makefile
    // cross-squirrel targets via $(ZIG_PLATFORM_FLAG) (set by squirrel-build.sh).
    // wayland-tunnel does not yet branch on platform; the option is accepted and
    // injected as build_options for forward-compat so callers can pass it
    // uniformly alongside sys-daemon-zig without a hard "unknown option" error.
    // Valid values: qemu_amd64 | qemu_aarch64 | bpi_m64 | pinephone
    const platform = b.option(
        []const u8,
        "platform",
        "Target platform: qemu_amd64|qemu_aarch64|bpi_m64|pinephone",
    ) orelse "qemu_aarch64";

    // Build options module — importable as @import("build_options") once any
    // source file needs to read the platform string at comptime.
    const platform_options = b.addOptions();
    platform_options.addOption([]const u8, "platform", platform);

    // Cross-compile sysroot: pass --sysroot=<path> to zig build (not -Dsysroot=).
    // When --sysroot is set, lld automatically prefixes all absolute library
    // search paths, so we use bare /usr/local/{include,lib} here and the linker
    // resolves them relative to the sysroot for cross builds.
    // The -Dsysroot option is kept for backward compat but is now a no-op.
    _ = b.option([]const u8, "sysroot", "Deprecated: use zig build --sysroot instead") orelse "";
    const inc_dir = "/usr/local/include";
    const lib_dir = "/usr/local/lib";

    // Vendored lz4 — compiled as a static C object so cross-compile never
    // depends on liblz4 being present in the sysroot.  BSD-2-Clause.
    const lz4_src = b.path("vendor/lz4/lz4.c");
    const lz4_inc = b.path("vendor/lz4");

    // Shared C import module (avoids duplicate @cImport in every file)
    const c_mod = b.addModule("c", .{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_mod.addIncludePath(.{ .cwd_relative = inc_dir });
    c_mod.addIncludePath(lz4_inc);

    // Shared Wayland tracker modules
    const wl_shm_mod = b.addModule("wl_shm", .{
        .root_source_file = b.path("src/wl_shm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wl_registry_mod = b.addModule("wl_registry", .{
        .root_source_file = b.path("src/wl_registry.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Stream protocol module
    const stream_mod = b.addModule("stream", .{
        .root_source_file = b.path("src/stream.zig"),
        .target = target,
        .optimize = optimize,
    });
    stream_mod.addImport("c", c_mod);

    // Socket helpers module
    const socket_mod = b.addModule("socket", .{
        .root_source_file = b.path("src/socket.zig"),
        .target = target,
        .optimize = optimize,
    });
    socket_mod.addImport("c", c_mod);
    socket_mod.addImport("stream", stream_mod);

    // Input injection module
    const input_mod = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    input_mod.addImport("c", c_mod);
    input_mod.addImport("stream", stream_mod);

    const input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/input.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    input_tests.root_module.addImport("c", c_mod);
    input_tests.root_module.addImport("stream", stream_mod);
    input_tests.linkLibC();
    const run_input_tests = b.addRunArtifact(input_tests);
    const input_test_step = b.step("test-input", "Run input framing tests");
    input_test_step.dependOn(&run_input_tests.step);

    // Stream header encoding tests
    const stream_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_stream.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stream_tests.root_module.addImport("c", c_mod);
    stream_tests.root_module.addImport("stream", stream_mod);
    stream_tests.linkLibC();
    stream_tests.addCSourceFile(.{ .file = lz4_src, .flags = &.{"-O2"} });
    stream_tests.addIncludePath(lz4_inc);
    const run_stream_tests = b.addRunArtifact(stream_tests);
    const stream_test_step = b.step("test-stream", "Run stream header encoding tests");
    stream_test_step.dependOn(&run_stream_tests.step);

    // Wayland protocol parsing module
    const protocol_mod = b.addModule("protocol", .{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_mod.addImport("c", c_mod);
    protocol_mod.addImport("wl_shm", wl_shm_mod);
    protocol_mod.addImport("wl_registry", wl_registry_mod);

    // Relay thread module
    const relay_mod = b.addModule("relay", .{
        .root_source_file = b.path("src/relay.zig"),
        .target = target,
        .optimize = optimize,
    });
    relay_mod.addImport("c", c_mod);
    relay_mod.addImport("stream", stream_mod);
    relay_mod.addImport("socket", socket_mod);
    relay_mod.addImport("protocol", protocol_mod);
    relay_mod.addImport("input", input_mod);
    relay_mod.addImport("wl_shm", wl_shm_mod);
    relay_mod.addImport("wl_registry", wl_registry_mod);

    // Main executable
    const main_mod = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("c", c_mod);
    main_mod.addImport("stream", stream_mod);
    main_mod.addImport("socket", socket_mod);
    main_mod.addImport("relay", relay_mod);
    // Inject platform build_options (forward-compat — see -Dplatform above).
    main_mod.addOptions("build_options", platform_options);

    const exe = b.addExecutable(.{
        .name = "wl-tunnel",
        .root_module = main_mod,
    });
    exe.linkLibC();
    exe.addIncludePath(.{ .cwd_relative = inc_dir });
    exe.addLibraryPath(.{ .cwd_relative = lib_dir });
    exe.addCSourceFile(.{ .file = lz4_src, .flags = &.{"-O2"} });
    exe.addIncludePath(lz4_inc);
    b.installArtifact(exe);

    // Protocol wire-format tests (frame encode/decode + pool dedup logic)
    // Run: zig build test-protocol
    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_protocol.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    protocol_tests.linkLibC();
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const protocol_test_step = b.step("test-protocol", "Run v1 protocol frame encode/decode and pool dedup tests");
    protocol_test_step.dependOn(&run_protocol_tests.step);

    // Reconnect / EOF detection tests (pipe-based poll + read-0 semantics)
    // Run: zig build test-reconnect
    const reconnect_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_reconnect.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    reconnect_tests.linkLibC();
    const run_reconnect_tests = b.addRunArtifact(reconnect_tests);
    const reconnect_test_step = b.step("test-reconnect", "Run relay EOF detection and stream readability tests");
    reconnect_test_step.dependOn(&run_reconnect_tests.step);

    // wl-keepalive
    const keepalive_mod = b.addModule("keepalive", .{
        .root_source_file = b.path("src/wl_keepalive.zig"),
        .target = target,
        .optimize = optimize,
    });
    const keepalive = b.addExecutable(.{
        .name = "wl-keepalive",
        .root_module = keepalive_mod,
    });
    keepalive.linkLibC();
    b.installArtifact(keepalive);

    // stream-reader
    const reader_mod = b.addModule("stream-reader", .{
        .root_source_file = b.path("src/stream-reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stream_reader = b.addExecutable(.{
        .name = "stream-reader",
        .root_module = reader_mod,
    });
    stream_reader.linkLibC();
    b.installArtifact(stream_reader);
}
// build:end
