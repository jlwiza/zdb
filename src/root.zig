//! ZDB - Zig Debugger
//! A lightweight debugging library for Zig
const std = @import("std");
const Io = std.Io;
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
        package_root: []const u8 = "src/root.zig",
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

    var threaded: std.Io.Threaded = .init(b.allocator, .{
        .environ = std.process.Environ.empty,
    });
    defer threaded.deinit();
    const io = threaded.ioBasic();

    // Check if build.zig needs preprocessing
    const build_content = std.Io.Dir.cwd().readFileAlloc(io, "build.zig", b.allocator, .limited(10 * 1024 * 1024)) catch "";
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
            "zig",
            "build",
            "--build-file",
            b.fmt("{s}/build.zig", .{options.processed_dir}),
            "--prefix",
            "zig-out",
            "--cache-dir",
            ".zig-cache",
            options.debug_step_name,
        });
        run_with_debug_build.step.dependOn(&preprocess_build.step);
        debug_step.dependOn(&run_with_debug_build.step);
        return;
    }

    // Normal flow - preprocess source files
    const main_path = exe.root_module.root_source_file.?.getPath(b);

    // Strip absolute path components to get relative path
    const relative_path = if (std.Io.Dir.path.isAbsolute(main_path)) blk: {
        const cwd: std.Io.Dir = std.Io.Dir.cwd();
        const abs_cwd = cwd.realPathFileAlloc(io, ".", b.allocator) catch break :blk std.fs.path.basename(main_path);
        defer b.allocator.free(abs_cwd);

        if (std.mem.startsWith(u8, main_path, abs_cwd)) {
            const trimmed = main_path[abs_cwd.len..];
            break :blk if (trimmed.len > 0 and trimmed[0] == '/')
                trimmed[1..]
            else
                trimmed;
        } else {
            break :blk std.fs.path.basename(main_path);
        }
    } else main_path;

    const processed_path = b.fmt("{s}/{s}", .{ options.processed_dir, relative_path });

    // Create directory for processed file
    const dir_path = std.Io.Dir.path.dirname(processed_path) orelse ".";
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
        .root_module = b.createModule(.{
            .root_source_file = b.path(processed_path),
            .target = target,
            .optimize = optimize,
        }),
    });

    // set up the main dir were gonna loop through all the other zig files
    const src_dir = std.Io.Dir.path.dirname(main_path) orelse "src";

    const src_dir_handle = std.Io.Dir.cwd().openDir(io, src_dir, .{ .iterate = true }) catch |err| {
        std.debug.print("Error: Failed to open source directory '{s}': {}\n", .{ src_dir, err });
        std.debug.print("Cannot process additional .zig files for debugging.\n", .{});
        @panic("Build failed: unable to access source directory");
    };
    defer src_dir_handle.close(io);

    var walker = src_dir_handle.walk(b.allocator) catch |err| {
        std.debug.print("Error: Failed to create directory walker: {}\n", .{err});
        @panic("Build failed: unable to walk source directory");
    };
    defer walker.deinit();

    const src_dir_name = std.Io.Dir.path.basename(src_dir);

    while (walker.next(io) catch |err| {
        std.debug.print("Error: Failed to read directory entry: {}\n", .{err});
        @panic("Build failed: error walking source directory");
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const full_entry_path = std.Io.Dir.path.join(b.allocator, &.{ src_dir, entry.path }) catch |err| {
            std.debug.print("Error: Failed to join path: {}\n", .{err});
            @panic("Build failed: path construction error");
        };
        defer b.allocator.free(full_entry_path);
        // skip the main file
        if (std.mem.eql(u8, full_entry_path, main_path)) continue;

        const input_path = std.Io.Dir.path.join(b.allocator, &.{ src_dir, entry.path }) catch |err| {
            std.debug.print("Error: Failed to construct input path for '{s}': {}\n", .{ entry.path, err });
            @panic("Build failed: path construction error");
        };
        defer b.allocator.free(input_path);

        const output_rel_path = std.Io.Dir.path.join(b.allocator, &.{ src_dir_name, entry.path }) catch |err| {
            std.debug.print("Error: Failed to construct relative output path for '{s}': {}\n", .{ entry.path, err });
            @panic("Build failed: path construction error");
        };
        defer b.allocator.free(output_rel_path);

        const output_path = std.Io.Dir.path.join(b.allocator, &.{ options.processed_dir, output_rel_path }) catch |err| {
            std.debug.print("Error: Failed to construct output path for '{s}': {}\n", .{ entry.path, err });
            @panic("Build failed: path construction error");
        };
        defer b.allocator.free(output_path);

        // Create directory for the path if needed
        if (std.Io.Dir.path.dirname(output_path)) |dir| {
            const make_subdir = b.addSystemCommand(&.{ "mkdir", "-p", dir });
            preprocess_main.step.dependOn(&make_subdir.step);
        }

        // Preprocess this file
        const preprocess_file = b.addRunArtifact(preprocessor);
        preprocess_file.addArg(input_path);
        preprocess_file.addArg(output_path);
        if (options.enable_step_mode) {
            preprocess_file.addArg("--step");
        }
        exe_debug.step.dependOn(&preprocess_file.step);
    }

    // Add zdb import
    exe_debug.root_module.addImport("zdb", zdb_dep.module("zdb"));

    // Copy ALL imports from original exe (zglfw, zmath, etc.)
    var it = exe.root_module.import_table.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const module = entry.value_ptr.*;
        if (!std.mem.eql(u8, name, "zdb")) {
            exe_debug.root_module.addImport(name, module);
        }
    }

    exe_debug.step.dependOn(&preprocess_main.step);

    const run_debug = b.addRunArtifact(exe_debug);
    debug_step.dependOn(&run_debug.step);
}
