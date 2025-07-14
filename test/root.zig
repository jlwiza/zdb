//! ZDB - Zig Debugger
//! A lightweight debugging library for Zig

const std = @import("std");

// Re-export all the runtime debugging functions
pub usingnamespace @import("runtime.zig");

// Build helper function that users call from their build.zig
pub fn addTo(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    options: struct {
        debug_step_name: []const u8 = "debug",
        processed_dir: []const u8 = "processed",
        enable_step_mode: bool = false,
    },
) void {
    const target = exe.root_module.resolved_target.?;
    const optimize = exe.root_module.optimize.?;

    // Get ourselves as a dependency
    const zdb_dep = b.dependency("zdb", .{
        .target = target,
        .optimize = optimize,
    });

    const debug_step = b.step(options.debug_step_name, "Run with debugging");

    // Get our preprocessor
    const preprocessor = zdb_dep.artifact("zdb-preprocessor");

    // Check if build.zig needs preprocessing
    const build_content = std.fs.cwd().readFileAlloc(b.allocator, "build.zig", 10 * 1024 * 1024) catch "";
    defer b.allocator.free(build_content);

    if (std.mem.indexOf(u8, build_content, "_ = .breakpoint;") != null) {
        // Create processed directory for build.zig
        const make_build_dir = b.addSystemCommand(&.{ "mkdir", "-p", options.processed_dir });

        // Preprocess build.zig
        const preprocess_build = b.addRunArtifact(preprocessor);
        preprocess_build.addArg("build.zig");
        preprocess_build.addArg(b.fmt("{s}/build.zig", .{options.processed_dir}));
        preprocess_build.step.dependOn(&make_build_dir.step);

        // Use preprocessed build.zig
        const run_with_debug_build = b.addSystemCommand(&.{
            "zig",                   "build",
            "--build-file",          b.fmt("{s}/build.zig", .{options.processed_dir}),
            "--prefix",              "zig-out",
            "--cache-dir",           ".zig-cache",
            options.debug_step_name,
        });
        run_with_debug_build.step.dependOn(&preprocess_build.step);
        debug_step.dependOn(&run_with_debug_build.step);
        return;
    }

    // Normal flow - preprocess source files
    const make_dir = b.addSystemCommand(&.{ "mkdir", "-p", b.fmt("{s}/src", .{options.processed_dir}) });

    // TODO: In future, walk the import tree to find all source files
    // For now, just process the main file
    const main_path = exe.root_module.root_source_file.?.getPath(b);

    // Preprocess main
    const preprocess_main = b.addRunArtifact(preprocessor);
    preprocess_main.addArg(main_path);
    preprocess_main.addArg(b.fmt("{s}/{s}", .{ options.processed_dir, main_path }));
    if (options.enable_step_mode) {
        preprocess_main.addArg("--step");
    }
    preprocess_main.step.dependOn(&make_dir.step);

    // Build debug exe
    const exe_debug = b.addExecutable(.{
        .name = b.fmt("{s}-debug", .{exe.name}),
        .root_source_file = b.path(b.fmt("{s}/{s}", .{ options.processed_dir, main_path })),
        .target = target,
        .optimize = optimize,
    });

    exe_debug.root_module.addImport("zdb", zdb_dep.module("zdb"));
    exe_debug.step.dependOn(&preprocess_main.step);

    const run_debug = b.addRunArtifact(exe_debug);
    debug_step.dependOn(&run_debug.step);
}
