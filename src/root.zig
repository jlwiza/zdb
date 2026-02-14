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

    // Add zdb import
    exe_debug.root_module.addImport("zdb", zdb_dep.module("zdb"));

    // Auto-detect self-imports from source
    const source_content = std.Io.Dir.cwd().readFileAlloc(io, main_path, b.allocator, .limited(10 * 1024 * 1024)) catch "";
    defer b.allocator.free(source_content);

    // Scan for @import("name") patterns that aren't std, zdb, or .zig files
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, source_content[search_start..], "@import(\"")) |rel_pos| {
        const pos = search_start + rel_pos;
        const after = source_content[pos + 9 ..];

        if (std.mem.indexOf(u8, after, "\")")) |end| {
            const import_name = after[0..end];

            // Skip std, zdb, and file imports (.zig extension)
            const is_std = std.mem.eql(u8, import_name, "std");
            const is_zdb = std.mem.eql(u8, import_name, "zdb");
            const is_file = std.mem.endsWith(u8, import_name, ".zig");

            if (!is_std and !is_zdb and !is_file) {
                // Found a package import - add it
                exe_debug.root_module.addImport(
                    b.dupe(import_name),
                    b.addModule(b.dupe(import_name), .{
                        .root_source_file = b.path(options.package_root),
                        .target = target,
                        .optimize = optimize,
                    }),
                );
            }

            search_start = pos + 9 + end;
        } else {
            break;
        }
    }

    exe_debug.step.dependOn(&preprocess_main.step);

    const run_debug = b.addRunArtifact(exe_debug);
    debug_step.dependOn(&run_debug.step);
}
