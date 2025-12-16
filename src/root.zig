//! ZDB - Zig Debugger
//! A lightweight debugging library for Zig
const std = @import("std");
// Re-export all the runtime debugging functions
const runtime = @import("runtime.zig");
pub const breakpoint = runtime.breakpoint;
pub const debugPrint = runtime.debugPrint;
pub const debugPrintWithPage = runtime.debugPrintWithPage;
pub const debugPrintRange = runtime.debugPrintRange;

pub const handleBreakpoint = runtime.handleBreakpoint;
pub const handleStepBefore = runtime.handleStepBefore;
pub const handleStep = runtime.handleStep;

pub const addWatch = runtime.addWatch;
pub const checkWatches = runtime.checkWatches;
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
    // TODO: In future, walk the import tree to find all source files
    // For now, just process the main file
    const main_path = exe.root_module.root_source_file.?.getPath(b);

    // Strip absolute path components to get relative path
    const relative_path = if (std.fs.path.isAbsolute(main_path)) blk: {
        // Find the project root (where build.zig is)
        const cwd = std.fs.cwd();
        const abs_cwd = cwd.realpathAlloc(b.allocator, ".") catch ".";
        defer b.allocator.free(abs_cwd);

        // If main_path starts with cwd, strip it
        if (std.mem.startsWith(u8, main_path, abs_cwd)) {
            const trimmed = main_path[abs_cwd.len..];
            // Remove leading slash
            break :blk if (trimmed.len > 0 and trimmed[0] == '/')
                trimmed[1..]
            else
                trimmed;
        } else {
            // Fallback: just use the basename
            break :blk std.fs.path.basename(main_path);
        }
    } else main_path;

    const processed_path = b.fmt("{s}/{s}", .{ options.processed_dir, relative_path });

    // Create directory for processed file
    const dir_path = std.fs.path.dirname(processed_path) orelse ".";
    const make_dir = b.addSystemCommand(&.{ "mkdir", "-p", dir_path });

    // Preprocess main
    const preprocess_main = b.addRunArtifact(preprocessor);
    preprocess_main.addArg(main_path);
    preprocess_main.addArg(processed_path);
    if (options.enable_step_mode) {
        preprocess_main.addArg("--step");
    }
    preprocess_main.step.dependOn(&make_dir.step);

    // Build debug exe
    const exe_debug = b.addExecutable(.{
        .name = b.fmt("{s}-debug", .{exe.name}),
        .root_source_file = b.path(processed_path),
        .target = target,
        .optimize = optimize,
    });
    exe_debug.root_module.addImport("zdb", zdb_dep.module("zdb"));
    exe_debug.step.dependOn(&preprocess_main.step);
    const run_debug = b.addRunArtifact(exe_debug);
    debug_step.dependOn(&run_debug.step);
}
