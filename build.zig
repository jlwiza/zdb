const std = @import("std");
pub const addTo = @import("src/root.zig").addTo;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module
    const zdb_module = b.addModule("zdb", .{
        .root_source_file = b.path("src/root.zig"),
    });

    // The preprocessor tool
    const preprocessor = b.addExecutable(.{
        .name = "zdb-preprocessor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/preprocessor.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Add runtime module to preprocessor so it can reference types if needed
    preprocessor.root_module.addImport("zdb", zdb_module);

    // Install the preprocessor so dependencies can use it
    b.installArtifact(preprocessor);

    // Unit tests
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&lib_tests.step);

    // Test executable for development
    const test_exe = b.addExecutable(.{
        .name = "test-zdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/test_program.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    _ = .breakpoint;

    const test_run = b.addRunArtifact(test_exe);
    const test_run_step = b.step("test-run", "Run test program");
    test_run_step.dependOn(&test_run.step);

    // Debug version of test program
    const debug_test_step = b.step("test-debug", "Debug the test program");

    // Create processed directories
    const make_test_dir = b.addSystemCommand(&.{ "mkdir", "-p", "processed/test/systems" });

    // List of test files to preprocess
    const test_files = [_][]const u8{
        "test/test_program.zig",
        "test/game.zig",
        "test/systems/combat.zig",
        // Add more files as needed
    };

    // When running from processed build, adjust paths
    const is_processed = std.mem.indexOf(u8, b.build_root.path orelse ".", "processed") != null;
    const base_path = if (is_processed) ".." else ".";

    // Preprocess all test files
    var last_step = &make_test_dir.step;
    for (test_files) |file| {
        const preprocess = b.addRunArtifact(preprocessor);
        preprocess.addArg(b.fmt("{s}/{s}", .{ base_path, file }));
        preprocess.addArg(b.fmt("processed/{s}", .{file}));
        preprocess.step.dependOn(last_step);
        last_step = &preprocess.step;
    }

    // Build debug version
    const test_debug = b.addExecutable(.{
        .name = "test-zdb-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("processed/test/test_program.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_debug.root_module.addImport("zdb", zdb_module);
    test_debug.step.dependOn(last_step);

    const run_test_debug = b.addRunArtifact(test_debug);
    debug_test_step.dependOn(&run_test_debug.step);

    // Clean command
    const clean_step = b.step("clean", "Clean build artifacts");
    const clean_cmd = b.addSystemCommand(&.{ "rm", "-rf", "zig-cache", "zig-out", "processed", ".zig-cache" });
    clean_step.dependOn(&clean_cmd.step);

    // Debug build.zig itself (for testing)
    const debug_build_step = b.step("debug-build", "Debug this build.zig");

    // -----------------------------
    // Test fixture (consumer-style) debug
    // -----------------------------
    const fixture_debug_step = b.step("test-fixture-debug", "Debug the test-fixture project");

    // Make processed output directories
    const make_fixture_dirs = b.addSystemCommand(&.{ "mkdir", "-p", "processed/test-fixture/src" });

    // Preprocess fixture sources
    const fixture_files = [_][]const u8{
        "test-fixture/src/main.zig",
        // add more fixture source files here if you want them preprocessed too
    };

    var fixture_last = &make_fixture_dirs.step;
    for (fixture_files) |file| {
        const p = b.addRunArtifact(preprocessor);
        p.addArg(b.fmt("{s}/{s}", .{ base_path, file }));
        p.addArg(b.fmt("processed/{s}", .{file}));
        p.step.dependOn(fixture_last);
        fixture_last = &p.step;
    }

    // IMPORTANT: Define the fixture package module exactly like `zig init` does.
    // This is what makes `@import("test_fixture")` work.
    const fixture_pkg_mod = b.addModule("test_fixture", .{
        // Use src/root.zig if you have it; otherwise point at whatever file
        // the package wants consumers to import.
        .root_source_file = b.path("test-fixture/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the processed fixture exe
    const fixture_exe = b.addExecutable(.{
        .name = "test-fixture-debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("processed/test-fixture/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "test_fixture", .module = fixture_pkg_mod },
                .{ .name = "zdb", .module = zdb_module },
            },
        }),
    });

    fixture_exe.step.dependOn(fixture_last);

    const run_fixture = b.addRunArtifact(fixture_exe);
    fixture_debug_step.dependOn(&run_fixture.step);
    // Create processed directory
    const make_processed_dir = b.addSystemCommand(&.{ "mkdir", "-p", "processed" });

    // Copy runtime.zig to processed directory
    const copy_runtime = b.addSystemCommand(&.{ "cp", "src/runtime.zig", "processed/runtime.zig" });
    copy_runtime.step.dependOn(&make_processed_dir.step);

    // Preprocess our own build.zig
    const preprocess_build = b.addRunArtifact(preprocessor);
    preprocess_build.addArg("build.zig");
    preprocess_build.addArg("processed/build.zig");
    preprocess_build.addArg("--runtime-path");
    preprocess_build.addArg("runtime.zig");
    preprocess_build.step.dependOn(&copy_runtime.step);

    // Run the preprocessed build
    const run_debug_build = b.addSystemCommand(&.{
        "zig",          "build",
        "--build-file", "processed/build.zig",
        "--prefix",     "zig-out",
        "--cache-dir",
        ".zig-cache",
        // Don't run test-debug, just process the build file
    });
    run_debug_build.step.dependOn(&preprocess_build.step);
    debug_build_step.dependOn(&run_debug_build.step);
}
