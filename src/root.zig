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
pub const configureSidecar = runtime.configureSidecar;
pub const beginSidecarHandoff = runtime.beginSidecarHandoff;
pub const reloadSidecarHandoff = runtime.reloadSidecarHandoff;
pub const runSidecarContinuation = runtime.runSidecarContinuation;
pub const sidecar_abi = @import("sidecar_abi.zig");

pub const canAddress = runtime.canAddress;
pub const capture = runtime.capture;
pub const captureRef = runtime.captureRef;
pub const captureCopy = runtime.captureCopy;
pub const localRef = runtime.localRef;
pub const isStepping = runtime.isStepping;
pub const addWatch = runtime.addWatch;
pub const checkWatches = runtime.checkWatches;

// Live breakpoint system
pub const live = @import("live.zig");

// Generations: emitted code calls zdb.gen.redirect / crossReturn / hostGlobal / formatInto
pub const gen = @import("gen.zig");
// Shared with the preprocessor (it imports it through this module)
pub const fn_index = @import("fn_index.zig");

/// Instrument a dedicated, fully configured executable in place. Call after
/// adding all imports, native sources and link settings. The normal executable
/// must have its own module. Generated sources and adjacent assets live in cache.
pub fn addTo(b: *std.Build, exe: *std.Build.Step.Compile, options: struct {
    debug_step_name: []const u8 = "debug",
    check_step_name: []const u8 = "debug-check",
    enable_step_mode: bool = false,
    enable_live_mode: bool = false,
    /// Instrument only these source-relative files or directory prefixes.
    /// An empty list preserves the original behavior and instruments the tree.
    include: []const []const u8 = &.{},
    exclude: []const []const u8 = &.{},
    /// Hook only these functions in every instrumented file (one preprocessor --fn each).
    /// The initial build passes exactly one; generations get theirs from -Dzdb-gen.
    functions: []const []const u8 = &.{},
    /// Prefer the first source file containing `_ = .breakpoint;` over the
    /// include fallback. Explicit callers can leave this disabled.
    discover_breakpoint: bool = false,
    announce_discovery: bool = true,
    /// Build and load a real debugger sidecar dynamic library.
    enable_sidecar: bool = false,
    /// Move the direct post-marker suffix of a supported function into the reloadable library.
    enable_continuation_split: bool = false,
    sidecar_step_name: []const u8 = "debug-sidecar",
    /// Every non-excluded file gets redirect wrappers; the debugger builds generation
    /// dylibs through `gen_step_name` and loads them. Declares -Dzdb-gen, -Dzdb-gen-name,
    /// -Dzdb-inspect, so enable it on one addTo per build.zig.
    enable_generations: bool = false,
    gen_step_name: []const u8 = "debug-gen",
}) void {
    const dep = b.dependency("zdb", .{
        .target = exe.root_module.resolved_target.?,
        .optimize = exe.root_module.optimize.?,
    });
    const main_path = exe.root_module.root_source_file.?.getPath(b);
    const source_dir = std.fs.path.dirname(main_path).?;
    var threaded: std.Io.Threaded = .init(b.allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    const io = threaded.io();
    const discovered = if (options.discover_breakpoint)
        discoverBreakpoint(b, io, source_dir, options.exclude)
    else
        null;
    const live_breakpoint_files = if (options.discover_breakpoint and options.enable_live_mode)
        discoverLiveBreakpointFiles(b, io, source_dir, options.exclude)
    else
        &.{};
    if (options.announce_discovery) if (discovered) |path| {
        std.debug.print("[zdb] selected first breakpoint marker: {s}\n", .{path});
    };
    if (options.announce_discovery) for (live_breakpoint_files) |path| {
        std.debug.print("[zdb] selected live breakpoint file: {s}\n", .{path});
    };

    // Generation requests come from the running debugger, never by hand
    const generations = options.enable_generations;
    const gen_batch: []const []const u8 = if (generations)
        b.option([]const []const u8, "zdb-gen", "Generation batch, file:fn (repeatable); the debugger passes these") orelse &.{}
    else
        &.{};
    const gen_name: []const u8 = if (generations)
        b.option([]const u8, "zdb-gen-name", "Generation dylib name") orelse "zdb-gen"
    else
        "zdb-gen";
    const gen_inspect: []const []const u8 = if (generations)
        b.option([]const []const u8, "zdb-inspect", "Inspector: file:fn:line:local:path (repeatable)") orelse &.{}
    else
        &.{};
    const gen_files: ?*std.Build.Step.WriteFile = if (gen_batch.len > 0) b.addWriteFiles() else null; // only in a generation build
    var gen_roots: std.ArrayList([]const u8) = .empty; // files with targets; the generation root imports them

    const dir = std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true }) catch @panic("zdb: open source directory");
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("zdb: walk source directory");
    defer walker.deinit();
    const files = b.addWriteFiles();
    var continuation_source: ?std.Build.LazyPath = null;
    while (walker.next(io) catch @panic("zdb: read source directory")) |entry| {
        if (entry.kind != .file) continue;
        const rel = b.dupe(entry.path); // walker reuses entry.path's buffer
        const path = b.fmt("{s}/{s}", .{ source_dir, rel });
        const original: std.Build.LazyPath = .{ .cwd_relative = path };
        const is_zig = std.mem.endsWith(u8, rel, ".zig");
        const excluded = matchesAny(rel, options.exclude);
        const selected_by_live_breakpoint = matchesAny(rel, live_breakpoint_files);
        const selected = is_zig and !excluded and
            if (discovered) |selected_path|
                (std.mem.eql(u8, rel, selected_path) or selected_by_live_breakpoint)
            else if (live_breakpoint_files.len > 0)
                selected_by_live_breakpoint
            else
                (options.include.len == 0 or matchesAny(rel, options.include));
        const wrapped = generations and is_zig and !excluded; // every function redirectable, hooks or not

        // ── host tree: wrappers everywhere, hooks only in the selected file(s) ──
        const output = if (selected or wrapped) blk: {
            const process = b.addRunArtifact(dep.artifact("zdb-preprocessor"));
            process.addFileArg(original);
            const result = process.addOutputFileArg(rel);
            if (wrapped) process.addArgs(&.{ "--rel", rel, "--prologue" });
            if (selected) {
                if (options.enable_step_mode) process.addArg("--step");
                if (options.enable_live_mode) process.addArg("--live");
                if (options.functions.len > 0) {
                    for (options.functions) |name| process.addArgs(&.{ "--fn", name }); // named functions only
                } else if (selected_by_live_breakpoint) {
                    process.addArg("--whole-file");
                }
                const continuation_input = if (options.enable_continuation_split and continuation_source == null)
                    std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(10 * 1024 * 1024)) catch null
                else
                    null;
                if (continuation_input != null and std.mem.indexOf(u8, continuation_input.?, "_ = .breakpoint;") != null) {
                    process.addArg("--split-continuation");
                    const generate = b.addRunArtifact(dep.artifact("zdb-continuation-codegen"));
                    generate.addFileArg(original);
                    continuation_source = generate.addOutputFileArg("zdb_generated_continuation.zig");
                }
            }
            break :blk result;
        } else original;
        _ = files.addCopyFile(output, rel);

        // ── generation tree: host globals everywhere, hooks only on the batch ──
        if (gen_files) |gen_tree| {
            const gen_output = if (is_zig and !excluded) blk: {
                const process = b.addRunArtifact(dep.artifact("zdb-preprocessor"));
                process.addFileArg(original);
                const result = process.addOutputFileArg(rel);
                process.addArgs(&.{ "--rel", rel, "--prologue", "--gen" });
                var targeted = false;
                for (gen_batch) |key| {
                    const split = splitKey(key) orelse continue;
                    if (!std.mem.eql(u8, split.file, rel)) continue;
                    process.addArgs(&.{ "--fn", split.rest });
                    targeted = true;
                }
                for (gen_inspect) |key| { // order kept: the Nth --inspect exports zdb_inspect_N / zdb_level_N
                    const split = splitKey(key) orelse continue;
                    if (std.mem.eql(u8, split.file, rel)) process.addArgs(&.{ "--inspect", split.rest });
                }
                if (targeted) {
                    if (options.enable_step_mode) process.addArg("--step");
                    if (options.enable_live_mode) process.addArg("--live");
                    gen_roots.append(b.allocator, rel) catch @panic("OOM");
                }
                break :blk result;
            } else original;
            _ = gen_tree.addCopyFile(gen_output, rel);
        }
    }
    exe.root_module.root_source_file = files.getDirectory().path(b, std.fs.path.basename(main_path));
    exe.root_module.addImport("zdb", dep.module("zdb"));
    if (gen_files) |gen_tree| addGeneration(b, exe, gen_tree, gen_roots.items, gen_name, options.gen_step_name);

    var sidecar_install: ?*std.Build.Step.InstallArtifact = null;
    var sidecar_path: ?[]const u8 = null;
    if (options.enable_sidecar) {
        const generation = b.option(u64, "zdb-sidecar-generation", "Generation reported by the reloadable ZDB sidecar") orelse 1;
        const sidecar = addSidecarFromSource(b, dep, exe.root_module.resolved_target.?, continuation_source, .{
            .generation = generation,
            .name = "zdb-sidecar",
        });
        const sidecar_filename = b.fmt("zdb-sidecar{s}", .{exe.root_module.resolved_target.?.result.dynamicLibSuffix()});
        const install = b.addInstallArtifact(sidecar, .{
            .dest_dir = .{ .override = .prefix },
            .dest_sub_path = sidecar_filename,
            .pdb_dir = .disabled,
            .h_dir = .disabled,
            .implib_dir = .disabled,
        });
        sidecar_install = install;
        sidecar_path = b.getInstallPath(.prefix, sidecar_filename);
        b.step(options.sidecar_step_name, "Rebuild the reloadable ZDB debugger sidecar").dependOn(&install.step);
        exe.root_module.link_libc = true;
    }
    b.step(options.check_step_name, "Compile the instrumented executable without running it").dependOn(&exe.step);
    const run = b.addRunArtifact(exe);
    if (sidecar_install) |install| run.step.dependOn(&install.step);
    if (sidecar_path) |path| run.setEnvironmentVariable("ZDB_SIDECAR_PATH", path);
    if (generations) {
        exe.rdynamic = true; // generations bind glfw/objc/app C symbols to the host's instead of failing at dlopen
        exe.root_module.link_libc = true; // gen.zig uses system(), dladdr, dyld
        run.setEnvironmentVariable("ZDB_ZIG_EXE", b.graph.zig_exe);
        run.setEnvironmentVariable("ZDB_BUILD_ROOT", b.build_root.path orelse ".");
        run.setEnvironmentVariable("ZDB_SOURCE_DIR", source_dir);
        run.setEnvironmentVariable("ZDB_GEN_STEP", options.gen_step_name);
        run.setEnvironmentVariable("ZDB_GEN_DIR", b.getInstallPath(.prefix, ""));
        run.setEnvironmentVariable("ZDB_GEN_ARGS", passthroughArgs(b)); // same -D options ⇒ same code as the exe
        run.setEnvironmentVariable("ZDB_EXCLUDE", std.mem.join(b.allocator, ",", options.exclude) catch @panic("OOM"));
    }
    if (b.args) |args| run.addArgs(args);
    b.step(options.debug_step_name, "Run with ZDB instrumentation").dependOn(&run.step);
}

/// A generation: dylib whose root imports every file holding batch targets and
/// exports their addresses and ids (`zdb_gen_entries` / `zdb_gen_ids`, emitted by
/// the preprocessor), the bind hook, and error-name lookup for crossReturn.
fn addGeneration(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    files: *std.Build.Step.WriteFile,
    target_paths: []const []const u8,
    name: []const u8,
    step_name: []const u8,
) void {
    var root: std.ArrayList(u8) = .empty;
    const a = b.allocator;
    root.appendSlice(a, "// AUTO-GENERATED zdb generation root\nconst zdb = @import(\"zdb\");\n") catch @panic("OOM");
    for (target_paths, 0..) |path, i| root.print(a, "const file_{d} = @import(\"{s}\");\n", .{ i, path }) catch @panic("OOM");
    root.appendSlice(a, "const files = .{ ") catch @panic("OOM");
    for (target_paths, 0..) |_, i| root.print(a, "file_{d}, ", .{i}) catch @panic("OOM");
    root.appendSlice(a, "};\n" ++ generation_exports) catch @panic("OOM");
    _ = files.add("zdb_gen_root.zig", root.items); // beside the tree, so the relative @imports resolve

    const mod = b.createModule(.{
        .root_source_file = files.getDirectory().path(b, "zdb_gen_root.zig"),
        .target = exe.root_module.resolved_target,
        .optimize = exe.root_module.optimize,
        .link_libc = true,
    });
    var clones: std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module) = .empty;
    var imports = exe.root_module.import_table.iterator(); // zdb, build_options, vk, spv blobs, ...
    while (imports.next()) |import| mod.addImport(import.key_ptr.*, codeOnly(b, import.value_ptr.*, &clones));

    const lib = b.addLibrary(.{ .linkage = .dynamic, .name = name, .root_module = mod });
    lib.linker_allow_shlib_undefined = true; // C symbols resolve from the host (rdynamic) at load
    const install = b.addInstallArtifact(lib, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = b.fmt("{s}{s}", .{ name, exe.root_module.resolved_target.?.result.dynamicLibSuffix() }),
        .pdb_dir = .disabled,
        .h_dir = .disabled,
        .implib_dir = .disabled,
    });
    b.step(step_name, "Build a generation dylib (the debugger runs this)").dependOn(&install.step);
}

/// Same Zig modules without their C/C++/ObjC objects and libraries: those symbols
/// resolve from the host (rdynamic), so glfw, dawn, stbi keep ONE copy of their state.
fn codeOnly(
    b: *std.Build,
    module: *std.Build.Module,
    clones: *std.AutoHashMapUnmanaged(*std.Build.Module, *std.Build.Module),
) *std.Build.Module {
    if (clones.get(module)) |clone| return clone;
    if (module.root_source_file == null) return module; // pure C module: nothing Zig to copy
    const clone = b.createModule(.{
        .root_source_file = module.root_source_file,
        .target = module.resolved_target,
        .optimize = module.optimize,
    });
    clones.put(b.allocator, module, clone) catch @panic("OOM");
    for (module.include_dirs.items) |dir| clone.include_dirs.append(b.allocator, dir) catch @panic("OOM"); // @cImport still needs headers
    var imports = module.import_table.iterator();
    while (imports.next()) |import| clone.addImport(import.key_ptr.*, codeOnly(b, import.value_ptr.*, clones));
    return clone;
}

const generation_exports =
    \\
    \\export fn zdb_gen_bind(api: *const anyopaque) callconv(.c) void {
    \\    zdb.gen.bindHost(@ptrCast(@alignCast(api))); // breakpoints, stepping, redirects, globals → host
    \\}
    \\
    \\export fn zdb_gen_error_name(code: u16) callconv(.c) [*:0]const u8 {
    \\    return @errorName(@errorFromInt(code)).ptr; // this image's numbering; crossReturn maps it back by name
    \\}
    \\
    \\export fn zdb_gen_entry_count() callconv(.c) usize {
    \\    var count: usize = 0;
    \\    _ = &count;
    \\    inline for (files) |file| count += file.zdb_gen_entries.len;
    \\    return count;
    \\}
    \\
    \\export fn zdb_gen_entry(index: usize) callconv(.c) ?*const anyopaque {
    \\    var n: usize = 0;
    \\    _ = &n;
    \\    inline for (files) |file| {
    \\        inline for (file.zdb_gen_entries) |entry| { // referencing each one forces it to compile
    \\            if (n == index) return @ptrCast(entry);
    \\            n += 1;
    \\        }
    \\    }
    \\    return null;
    \\}
    \\
    \\export fn zdb_gen_entry_id(index: usize) callconv(.c) u64 {
    \\    var n: usize = 0;
    \\    _ = &n;
    \\    inline for (files) |file| {
    \\        inline for (file.zdb_gen_ids) |id| {
    \\            if (n == index) return id;
    \\            n += 1;
    \\        }
    \\    }
    \\    return 0;
    \\}
    \\
;

pub const SidecarBuildOptions = struct {
    generation: u64,
    name: []const u8,
    read_u32_name: []const u8 = "",
    mutate_u32_name: []const u8 = "",
    mutate_u32_value: u32 = 0,
    outcome: u8 = 0,
};

pub fn addSidecar(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    options: SidecarBuildOptions,
) *std.Build.Step.Compile {
    return addSidecarFromSource(b, dep, target, null, options);
}

pub fn addSidecarFromSource(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    source: ?std.Build.LazyPath,
    options: SidecarBuildOptions,
) *std.Build.Step.Compile {
    const sidecar_options = b.addOptions();
    sidecar_options.addOption(u64, "generation", options.generation);
    sidecar_options.addOption([]const u8, "read_u32_name", options.read_u32_name);
    sidecar_options.addOption([]const u8, "mutate_u32_name", options.mutate_u32_name);
    sidecar_options.addOption(u32, "mutate_u32_value", options.mutate_u32_value);
    sidecar_options.addOption(u8, "outcome", options.outcome);
    const module = b.createModule(.{
        .root_source_file = source orelse dep.path("src/sidecar.zig"),
        .target = target,
        .optimize = .Debug,
    });
    module.addOptions("zdb_sidecar_options", sidecar_options);
    module.addImport("zdb", dep.module("zdb"));
    return b.addLibrary(.{ .linkage = .dynamic, .name = options.name, .root_module = module });
}

fn discoverLiveBreakpointFiles(
    b: *std.Build,
    io: std.Io,
    source_dir: []const u8,
    exclude: []const []const u8,
) []const []const u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(io, "zdb_breakpoints.zon", b.allocator, .limited(1024 * 1024)) catch return &.{};
    defer b.allocator.free(source);

    var result: std.ArrayList([]const u8) = .empty;
    const source_name = std.fs.path.basename(source_dir);
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, ".file")) |field_pos| {
        const after_field = source[field_pos + ".file".len ..];
        const open_rel = std.mem.indexOfScalar(u8, after_field, '"') orelse break;
        const after_open = after_field[open_rel + 1 ..];
        const close_rel = std.mem.indexOfScalar(u8, after_open, '"') orelse break;
        const configured = after_open[0..close_rel];
        cursor = field_pos + ".file".len + open_rel + 1 + close_rel + 1;

        var relative = configured;
        if (std.fs.path.isAbsolute(configured)) {
            if (!std.mem.startsWith(u8, configured, source_dir) or configured.len <= source_dir.len or configured[source_dir.len] != std.fs.path.sep) continue;
            relative = configured[source_dir.len + 1 ..];
        } else if (std.mem.startsWith(u8, configured, source_name) and configured.len > source_name.len and configured[source_name.len] == '/') {
            relative = configured[source_name.len + 1 ..];
        }
        if (!std.mem.endsWith(u8, relative, ".zig")) continue;

        var excluded = false;
        for (exclude) |pattern| {
            if (matches(relative, pattern)) {
                excluded = true;
                break;
            }
        }
        if (excluded or matchesAny(relative, result.items)) continue;
        result.append(b.allocator, b.allocator.dupe(u8, relative) catch continue) catch continue;
    }
    return result.toOwnedSlice(b.allocator) catch &.{};
}

fn discoverBreakpoint(
    b: *std.Build,
    io: std.Io,
    source_dir: []const u8,
    exclude: []const []const u8,
) ?[]const u8 {
    const dir = std.Io.Dir.cwd().openDir(io, source_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch return null;
    defer walker.deinit();

    var first: ?[]const u8 = null;
    while (walker.next(io) catch return first) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var excluded = false;
        for (exclude) |pattern| {
            if (matches(entry.path, pattern)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        const source = dir.readFileAlloc(io, entry.path, b.allocator, .limited(10 * 1024 * 1024)) catch continue;
        defer b.allocator.free(source);
        if (std.mem.indexOf(u8, source, "_ = .breakpoint;") == null) continue;
        if (first == null or std.mem.order(u8, entry.path, first.?) == .lt) {
            first = b.allocator.dupe(u8, entry.path) catch return first;
        }
    }
    return first;
}

fn matchesAny(path: []const u8, patterns: []const []const u8) bool {
    for (patterns) |pattern| {
        if (matches(path, pattern)) return true;
    }
    return false;
}

fn matches(path: []const u8, pattern: []const u8) bool {
    return std.mem.eql(u8, path, pattern) or
        (std.mem.startsWith(u8, path, pattern) and
            path.len > pattern.len and path[pattern.len] == '/');
}

/// "timeline.zig:frameForTraversal" → file + everything after the first ':'.
fn splitKey(key: []const u8) ?struct { file: []const u8, rest: []const u8 } {
    const colon = std.mem.indexOfScalar(u8, key, ':') orelse return null;
    return .{ .file = key[0..colon], .rest = key[colon + 1 ..] };
}

/// The user's -D options, shell-quoted, minus the per-generation ones — the
/// debugger replays them so a generation compiles the same code as the exe.
fn passthroughArgs(b: *std.Build) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = b.user_input_options.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.startsWith(u8, name, "zdb-gen") or std.mem.eql(u8, name, "zdb-inspect")) continue;
        switch (entry.value_ptr.value) {
            .flag => out.print(b.allocator, "'-D{s}' ", .{name}) catch @panic("OOM"),
            .scalar => |value| out.print(b.allocator, "'-D{s}={s}' ", .{ name, value }) catch @panic("OOM"),
            .list => |list| for (list.items) |value| out.print(b.allocator, "'-D{s}={s}' ", .{ name, value }) catch @panic("OOM"),
            else => {}, // maps / lazy paths: none in this build
        }
    }
    return out.items;
}

test {
    _ = @import("runtime.zig");
}
