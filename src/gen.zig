//! Generations — one pipeline for the ring and for inspection:
//!   `zig build <gen step> -Dzdb-gen=file:fn...` → dylib → load → bind → activate
//! Host code enters generated code only through redirect wrappers; generated code
//! reaches host state only through the HostApi table and hostGlobal.
const std = @import("std");
const builtin = @import("builtin");
const sidecar_abi = @import("sidecar_abi.zig");
const generation_loader = @import("dylib_generation");
const fn_index = @import("fn_index.zig");
const host_symbols = @import("host_symbols.zig");
const runtime = @import("runtime.zig");
const live = @import("live.zig");

const LocalRef = sidecar_abi.LocalRef;
const Function = fn_index.Function;
const gpa = std.heap.page_allocator; // debugger lifetime; nothing here is freed

extern "c" fn system(command: [*:0]const u8) c_int;
extern "c" fn usleep(microseconds: c_uint) c_int;

// ═══ Host table — generated code calls these instead of its own zdb copy ═══

pub const HostApi = struct {
    shouldBreak: *const fn (u32, u32, usize) bool, // file hash, line, hook frame
    onBreak: *const fn ([]const u8, []const u8, u32, u32, []const LocalRef) void,
    handleStepBefore: *const fn ([]const u8, []const u8, []const u8, usize, []const LocalRef) void,
    handleBreakpoint: *const fn ([]const u8, []const u8, usize, []const LocalRef) void,
    isStepping: *const fn () bool,
    redirect: *const fn (u64) ?*const anyopaque,
    resolveGlobal: *const fn (usize) usize,
    errorName: *const fn (*const anyopaque, u16) []const u8,
};

const local_api: HostApi = .{
    .shouldBreak = &live.breakAt,
    .onBreak = &live.onBreak,
    .handleStepBefore = &runtime.handleStepBefore,
    .handleBreakpoint = &runtime.handleBreakpoint,
    .isStepping = &runtime.isStepping,
    .redirect = &hostRedirect,
    .resolveGlobal = &resolveGlobal,
    .errorName = &hostErrorName,
};

var host_api: ?*const HostApi = null; // set only inside a generation, by its exported zdb_gen_bind

/// CALLED BY: a generation's exported zdb_gen_bind, right after the host loads it.
pub fn bindHost(api: *const HostApi) void {
    host_api = api;
}

/// Non-null only inside a generation: zdb's entry points forward here, so
/// breakpoints and step state exist once, in the host.
pub fn remote() ?*const HostApi {
    return host_api;
}

// ═══ Redirects — the wrapper at the top of every redirectable function ═══

var armed = std.atomic.Value(bool).init(false); // false until the first stop: wrappers cost one load
var poll_tick: u32 = 0;

/// CALLED BY: every redirect wrapper. Null ⇒ run the local body.
pub inline fn redirect(id: u64) ?*const anyopaque {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return null;
    if (@inComptime()) return null; // wrappers also run in comptime calls
    if (host_api) |api| return api.redirect(id); // generated code: the host owns the table
    if (!armed.load(.monotonic)) return null;
    return hostRedirect(id);
}

fn ReturnOf(comptime FnPointer: type) type {
    return @typeInfo(@typeInfo(FnPointer).pointer.child).@"fn".return_type.?;
}

/// CALLED BY: every redirect wrapper, when `redirect` returned a target.
/// Errors are numbered per compilation, so an error coming back from another
/// image is re-created here by name, in this image's numbering.
pub fn crossReturn(comptime FnPointer: type, callee: *const anyopaque, args: anytype) ReturnOf(FnPointer) {
    const function: FnPointer = @ptrCast(@alignCast(callee));
    const R = ReturnOf(FnPointer);
    if (comptime @typeInfo(R) != .error_union) return @call(.auto, function, args);
    const result = @call(.auto, function, args);
    if (result) |value| return value else |foreign| {
        const name = errorNameIn(callee, @intCast(@intFromError(foreign))); // foreign's bits are the callee image's code
        return errorByName(@typeInfo(R).error_union.error_set, name);
    }
}

fn errorByName(comptime Set: type, name: []const u8) Set {
    const members = @typeInfo(Set).error_set orelse
        std.debug.panic("[zdb] error.{s} crossed a generation as anyerror; it can't be re-numbered", .{name});
    inline for (members) |member| {
        if (std.mem.eql(u8, member.name, name)) return @field(Set, member.name);
    }
    std.debug.panic("[zdb] generation returned error.{s}, which {s} doesn't contain", .{ name, @typeName(Set) });
}

fn errorNameIn(callee: *const anyopaque, code: u16) []const u8 {
    if (host_api) |api| return api.errorName(callee, code);
    return hostErrorName(callee, code);
}

const ErrorNameFn = *const fn (u16) callconv(.c) [*:0]const u8;
const Active = struct { id: u64, entry: *const anyopaque };
const Known = struct { entry: *const anyopaque, error_name: ErrorNameFn };

var active: [512]Active = undefined; // id → newest generation's entry
var active_len: usize = 0;
var known: [4096]Known = undefined; // every entry ever loaded; superseded ones may still be running
var known_len: usize = 0;

fn lookupActive(id: u64) ?*const anyopaque {
    for (active[0..active_len]) |slot| {
        if (slot.id == id) return slot.entry;
    }
    return null;
}

fn activate(id: u64, entry: *const anyopaque, error_name: ErrorNameFn) void {
    if (known_len < known.len) {
        known[known_len] = .{ .entry = entry, .error_name = error_name };
        known_len += 1;
    }
    for (active[0..active_len]) |*slot| {
        if (slot.id == id) {
            slot.entry = entry; // newer generation wins; frames already in the old one finish there
            return;
        }
    }
    if (active_len == active.len) {
        std.debug.print("[zdb] redirect table full; function {x} stays on its previous code\n", .{id});
        return;
    }
    active[active_len] = .{ .id = id, .entry = entry };
    active_len += 1;
}

fn hostErrorName(callee: *const anyopaque, code: u16) []const u8 {
    for (known[0..known_len]) |entry| {
        if (entry.entry == callee) return std.mem.span(entry.error_name(code));
    }
    return "ZdbUnknownGenerationError";
}

/// Host side of `redirect`. A step-in into a function no generation covers
/// builds one on the spot and waits — it stops, or it says why it can't.
fn hostRedirect(id: u64) ?*const anyopaque {
    poll_tick +%= 1;
    if (poll_tick % 4096 == 0) pollPending(); // a background ring may have finished
    if (lookupActive(id)) |entry| return entry;
    if (!live.stepInPending()) return null;
    const idx = ensureIndex() orelse return null;
    const func = idx.byId(id) orelse {
        std.debug.print("[zdb] step-in: function {x} isn't in the index; running it uninstrumented\n", .{id});
        return null;
    };
    std.debug.print("[zdb] step-in {s}:{s} — building its generation…\n", .{ func.file, func.path });
    waitPending();
    if (lookupActive(id)) |entry| return entry;
    buildRing(func, .blocking);
    return lookupActive(id);
}

// ═══ Globals — generated code reads and writes the host's, by symbol name ═══

var lock_flag = std.atomic.Value(bool).init(false);
var global_cache: std.AutoHashMapUnmanaged(usize, usize) = .empty; // generation address → host address
var first_copies: std.StringHashMapUnmanaged(usize) = .empty; // globals the host never compiled
var host_names: ?std.StringHashMapUnmanaged(usize) = null;
var image_names: std.AutoHashMapUnmanaged(usize, std.AutoHashMapUnmanaged(usize, []const u8)) = .empty;

fn lock() void {
    while (lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock() void {
    lock_flag.store(false, .release);
}

/// Emitted in generation code for every global access: `zdb.gen.hostGlobal(&x).*`.
pub fn hostGlobal(pointer: anytype) @TypeOf(pointer) {
    const api = host_api orelse return pointer; // in the host it already is the real one
    return @ptrFromInt(api.resolveGlobal(@intFromPtr(pointer)));
}

fn resolveGlobal(address: usize) usize {
    lock();
    defer unlock();
    if (global_cache.get(address)) |mapped| return mapped;
    const mapped = mapGlobal(address);
    global_cache.put(gpa, address, mapped) catch {};
    return mapped;
}

fn mapGlobal(address: usize) usize {
    const name = symbolAt(address) orelse {
        std.debug.print("[zdb] generation global at 0x{x} has no symbol; it keeps its own copy (NOT shared with the host)\n", .{address});
        return address;
    };
    const host = hostSymbols() orelse {
        std.debug.print("[zdb] host symbol table unreadable; {s} keeps the generation's copy (NOT shared with the host)\n", .{name});
        return address;
    };
    if (host.get(name)) |host_address| return host_address;
    // The host never compiled it, so no host code touches it: the first generation's copy is the only one.
    const slot = first_copies.getOrPut(gpa, name) catch return address;
    if (!slot.found_existing) slot.value_ptr.* = address;
    return slot.value_ptr.*;
}

fn symbolAt(address: usize) ?[]const u8 {
    const base = host_symbols.imageBase(address) orelse return null;
    const slot = image_names.getOrPut(gpa, @intFromPtr(base)) catch return null;
    if (!slot.found_existing) {
        slot.value_ptr.* = .empty;
        const image = host_symbols.Image.open(base) orelse return null;
        for (image.symbols) |symbol| {
            if (!host_symbols.isDefined(symbol)) continue;
            slot.value_ptr.put(gpa, image.address(symbol), image.name(symbol)) catch {};
        }
    }
    return slot.value_ptr.get(address);
}

fn hostSymbols() ?*const std.StringHashMapUnmanaged(usize) {
    if (host_names == null) {
        const image = host_symbols.hostImage() orelse return null;
        var names: std.StringHashMapUnmanaged(usize) = .empty;
        for (image.symbols) |symbol| {
            if (!host_symbols.isDefined(symbol)) continue;
            names.put(gpa, image.name(symbol), image.address(symbol)) catch {};
        }
        host_names = names;
    }
    return &host_names.?;
}

// ═══ Configuration — set on the run step by addTo ═══

const Config = struct {
    zig_exe: []const u8,
    build_root: []const u8,
    source_dir: []const u8,
    gen_step: []const u8,
    gen_args: []const u8, // the user's -D options, pre-quoted, so the generation matches the exe
    gen_dir: []const u8,
    exclude: []const u8, // comma-separated, same patterns addTo skipped
};

var config_reported = false;

fn env(name: [*:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn config() ?Config {
    return .{
        .zig_exe = env("ZDB_ZIG_EXE") orelse return null,
        .build_root = env("ZDB_BUILD_ROOT") orelse return null,
        .source_dir = env("ZDB_SOURCE_DIR") orelse return null,
        .gen_step = env("ZDB_GEN_STEP") orelse return null,
        .gen_args = env("ZDB_GEN_ARGS") orelse "",
        .gen_dir = env("ZDB_GEN_DIR") orelse return null,
        .exclude = env("ZDB_EXCLUDE") orelse "",
    };
}

fn configOrReport() ?Config {
    if (config()) |found| return found;
    if (!config_reported) {
        std.debug.print("[zdb] generations unavailable: start the app with `zig build debug` (it sets ZDB_* for the debugger)\n", .{});
        config_reported = true;
    }
    return null;
}

fn relative(source_dir: []const u8, path: []const u8) []const u8 {
    if (path.len > source_dir.len and std.mem.startsWith(u8, path, source_dir) and path[source_dir.len] == '/')
        return path[source_dir.len + 1 ..];
    return std.fs.path.basename(path);
}

fn isExcluded(exclude: []const u8, path: []const u8) bool {
    var patterns = std.mem.splitScalar(u8, exclude, ',');
    while (patterns.next()) |pattern| {
        if (pattern.len == 0) continue;
        if (std.mem.eql(u8, path, pattern)) return true;
        if (std.mem.startsWith(u8, path, pattern) and path.len > pattern.len and path[pattern.len] == '/') return true;
    }
    return false;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(runtime.runtime.io(), path, .{}) catch return false;
    return true;
}

// ═══ Index — every redirectable function, parsed from the source tree once ═══

const Index = struct {
    functions: []const Function,
    by_id: std.AutoHashMapUnmanaged(u64, u32),
    by_name: std.StringHashMapUnmanaged(std.ArrayList(u32)),

    fn byId(self: *const Index, id: u64) ?*const Function {
        const i = self.by_id.get(id) orelse return null;
        return &self.functions[i];
    }

    fn named(self: *const Index, name: []const u8) []const u32 {
        const list = self.by_name.get(name) orelse return &.{};
        return list.items;
    }

    fn inFile(self: *const Index, file: []const u8, name: []const u8) ?*const Function {
        for (self.named(name)) |i| {
            if (std.mem.eql(u8, self.functions[i].file, file)) return &self.functions[i];
        }
        return null;
    }
};

var index_state: enum { unbuilt, ready, failed } = .unbuilt;
var function_index: Index = undefined;

fn ensureIndex() ?*const Index {
    switch (index_state) {
        .ready => return &function_index,
        .failed => return null,
        .unbuilt => {},
    }
    const cfg = configOrReport() orelse {
        index_state = .failed;
        return null;
    };
    function_index = buildIndex(cfg) catch |err| {
        std.debug.print("[zdb] couldn't index {s}: {s}\n", .{ cfg.source_dir, @errorName(err) });
        index_state = .failed;
        return null;
    };
    index_state = .ready;
    return &function_index;
}

fn buildIndex(cfg: Config) !Index {
    const io = runtime.runtime.io();
    var functions: std.ArrayList(Function) = .empty;
    const dir = try std.Io.Dir.cwd().openDir(io, cfg.source_dir, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        if (isExcluded(cfg.exclude, entry.path)) continue;
        const source = dir.readFileAlloc(io, entry.path, gpa, .limited(10 * 1024 * 1024)) catch continue;
        const source_z = try gpa.dupeZ(u8, source);
        const file = try gpa.dupe(u8, entry.path); // walker reuses its path buffer
        try functions.appendSlice(gpa, try fn_index.indexFile(gpa, file, source_z));
    }
    var result: Index = .{ .functions = functions.items, .by_id = .empty, .by_name = .empty };
    for (functions.items, 0..) |func, i| {
        try result.by_id.put(gpa, func.id, @intCast(i));
        const slot = try result.by_name.getOrPut(gpa, func.name);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(gpa, @intCast(i));
    }
    return result;
}

// ═══ Ring — up to 7 functions, 2 hops: callers first, then callees ═══

const ring_budget = 7;
const ring_hops = 2;

fn containsFunction(list: []const *const Function, func: *const Function) bool {
    for (list) |candidate| {
        if (candidate == func) return true;
    }
    return false;
}

fn ringAround(idx: *const Index, center: *const Function, out: *[ring_budget]*const Function) usize {
    out[0] = center;
    var len: usize = 1;
    var frontier: [ring_budget]*const Function = undefined;
    frontier[0] = center;
    var frontier_len: usize = 1;
    for (0..ring_hops) |_| {
        var next: [ring_budget]*const Function = undefined;
        var next_len: usize = 0;
        for (frontier[0..frontier_len]) |func| { // up the stack: anything whose body calls it by name
            for (idx.functions) |*caller| {
                if (len == ring_budget) return len;
                if (!fn_index.containsName(caller.callees, func.name) or containsFunction(out[0..len], caller)) continue;
                out[len] = caller;
                len += 1;
                next[next_len] = caller;
                next_len += 1;
            }
        }
        for (frontier[0..frontier_len]) |func| { // then around: what it calls
            for (func.callees) |name| {
                for (idx.named(name)) |i| {
                    if (len == ring_budget) return len;
                    const callee = &idx.functions[i];
                    if (containsFunction(out[0..len], callee)) continue;
                    out[len] = callee;
                    len += 1;
                    next[next_len] = callee;
                    next_len += 1;
                }
            }
        }
        frontier = next;
        frontier_len = next_len;
    }
    return len;
}

fn allActive(ring: []const *const Function) bool {
    for (ring) |func| {
        if (lookupActive(func.id) == null) return false;
    }
    return true;
}

// ═══ Builds ═══

var next_serial: u32 = 1;
var pending: ?u32 = null; // serial of the background ring build, if one is running

/// `zig build` in a shell; markers say how it ended. Background runs return at once.
/// Serials restart every session, so this serial's old markers/dylib are cleared first —
/// a stale .done would otherwise load a previous session's build as if it were this one.
fn launch(cfg: Config, serial: u32, batch: []const *const Function, inspect_keys: []const []const u8, background: bool) bool {
    var clear: std.ArrayList(u8) = .empty;
    clear.print(gpa, "rm -f '{s}/zdb-gen-{d}.done' '{s}/zdb-gen-{d}.failed' '{s}/zdb-gen-{d}.log' '{s}/zdb-gen-{d}{s}'", .{
        cfg.gen_dir, serial, cfg.gen_dir, serial, cfg.gen_dir, serial, cfg.gen_dir, serial, builtin.target.dynamicLibSuffix(),
    }) catch return false;
    clear.append(gpa, 0) catch return false;
    _ = system(@ptrCast(clear.items.ptr)); // blocking: done before anyone polls this serial

    var cmd: std.ArrayList(u8) = .empty;
    cmd.print(gpa, "mkdir -p '{s}' && cd '{s}' && '{s}' build {s} {s} '-Dzdb-gen-name=zdb-gen-{d}'", .{
        cfg.gen_dir, cfg.build_root, cfg.zig_exe, cfg.gen_step, cfg.gen_args, serial,
    }) catch return false;
    for (batch) |func| cmd.print(gpa, " '-Dzdb-gen={s}:{s}'", .{ func.file, func.name }) catch return false;
    for (inspect_keys) |key| cmd.print(gpa, " '-Dzdb-inspect={s}'", .{key}) catch return false;
    cmd.print(gpa, " > '{s}/zdb-gen-{d}.log' 2>&1 && touch '{s}/zdb-gen-{d}.done' || touch '{s}/zdb-gen-{d}.failed'", .{
        cfg.gen_dir, serial, cfg.gen_dir, serial, cfg.gen_dir, serial,
    }) catch return false;
    if (background) cmd.appendSlice(gpa, " &") catch return false;
    cmd.append(gpa, 0) catch return false;
    _ = system(@ptrCast(cmd.items.ptr));
    return true;
}

fn marker(cfg: Config, serial: u32, kind: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}/zdb-gen-{d}.{s}", .{ cfg.gen_dir, serial, kind }) catch "";
}

fn buildRing(center: *const Function, mode: enum { background, blocking }) void {
    const cfg = configOrReport() orelse return;
    const idx = ensureIndex() orelse return;
    var ring_buf: [ring_budget]*const Function = undefined;
    const ring = ring_buf[0..ringAround(idx, center, &ring_buf)];
    if (mode == .background and (pending != null or allActive(ring))) return;
    const serial = next_serial;
    next_serial += 1;
    if (!launch(cfg, serial, ring, &.{}, mode == .background)) return;
    if (mode == .background) {
        pending = serial;
        return;
    }
    _ = finish(cfg, serial, .ring, &.{});
}

fn finish(cfg: Config, serial: u32, kind: LoadKind, wants: []const Want) ?*Loaded {
    if (!exists(marker(cfg, serial, "done"))) {
        std.debug.print("[zdb] generation {d} failed to build — see {s}\n", .{ serial, marker(cfg, serial, "log") });
        return null;
    }
    return loadGeneration(cfg, serial, kind, wants);
}

/// Ring first, then background inspectors: stepping matters more than looking.
fn pollPending() void {
    const cfg = config() orelse return;
    if (pending) |serial| {
        if (exists(marker(cfg, serial, "done"))) {
            pending = null;
            _ = loadGeneration(cfg, serial, .ring, &.{});
        } else if (exists(marker(cfg, serial, "failed"))) {
            pending = null;
            std.debug.print("[zdb] ring generation {d} failed to build — see {s}\n", .{ serial, marker(cfg, serial, "log") });
        }
    }
    if (inspect_pending) |job| {
        if (exists(marker(cfg, job.serial, "done"))) {
            inspect_pending = null;
            _ = loadGeneration(cfg, job.serial, .inspect, job.wants);
        } else if (exists(marker(cfg, job.serial, "failed"))) {
            inspect_pending = null;
            std.debug.print("[zdb] background inspectors {d} failed to build — see {s}\n", .{ job.serial, marker(cfg, job.serial, "log") });
        }
    }
    startQueuedInspectors(cfg);
}

fn waitPending() void {
    while (pending != null) {
        pollPending();
        if (pending != null) _ = usleep(50_000);
    }
}

// ═══ Loading ═══

const LoadKind = enum { ring, inspect };
const InspectFn = *const fn (*anyopaque, [*]u8, usize) callconv(.c) usize;
const LevelFn = *const fn (*anyopaque, [*]const u8, usize, [*]u8, usize) callconv(.c) usize;
const BindFn = *const fn (*const anyopaque) callconv(.c) void;
const CountFn = *const fn () callconv(.c) usize;
const EntryFn = *const fn (usize) callconv(.c) ?*const anyopaque;
const IdFn = *const fn (usize) callconv(.c) u64;

const Loaded = struct {
    generation: generation_loader.Generation, // never unloaded: frames may still be running in it
};

fn loadGeneration(cfg: Config, serial: u32, kind: LoadKind, wants: []const Want) ?*Loaded {
    const path = std.fmt.allocPrint(gpa, "{s}/zdb-gen-{d}{s}", .{ cfg.gen_dir, serial, builtin.target.dynamicLibSuffix() }) catch return null;
    const live_dir = std.fmt.allocPrint(gpa, "{s}/.zdb-live", .{cfg.gen_dir}) catch return null;
    const loaded = gpa.create(Loaded) catch return null;
    loaded.* = .{
        .generation = generation_loader.open(gpa, runtime.runtime.io(), path, live_dir, serial) catch |err| {
            std.debug.print("[zdb] couldn't load generation {d} ({s}): {s}\n", .{ serial, path, @errorName(err) });
            return null;
        },
    };
    const dl = &loaded.generation.dl;
    const bind = dl.lookup(BindFn, "zdb_gen_bind") orelse return missing(serial, "zdb_gen_bind");
    const error_name = dl.lookup(ErrorNameFn, "zdb_gen_error_name") orelse return missing(serial, "zdb_gen_error_name");
    bind(&local_api); // from here on its zdb calls, globals and errors resolve in the host
    switch (kind) {
        .inspect => for (wants, 0..) |want, slot| { // slot i ⇒ zdb_inspect_i / zdb_level_i
            var print_buf: [32]u8 = undefined;
            var level_buf: [32]u8 = undefined;
            const print_name = std.fmt.bufPrintZ(&print_buf, "zdb_inspect_{d}", .{slot}) catch continue;
            const level_name = std.fmt.bufPrintZ(&level_buf, "zdb_level_{d}", .{slot}) catch continue;
            const print = dl.lookup(InspectFn, print_name) orelse continue;
            const level = dl.lookup(LevelFn, level_name) orelse continue;
            inspectors.put(gpa, want.cache_key, .{ .print = print, .level = level }) catch {};
        },
        .ring => {
            const count = dl.lookup(CountFn, "zdb_gen_entry_count") orelse return missing(serial, "zdb_gen_entry_count");
            const entry = dl.lookup(EntryFn, "zdb_gen_entry") orelse return missing(serial, "zdb_gen_entry");
            const id_of = dl.lookup(IdFn, "zdb_gen_entry_id") orelse return missing(serial, "zdb_gen_entry_id");
            for (0..count()) |i| {
                if (entry(i)) |target_entry| activate(id_of(i), target_entry, error_name);
            }
            armed.store(true, .monotonic);
            std.debug.print("[zdb] generation {d}: {d} function(s) live\n", .{ serial, count() });
        },
    }
    return loaded;
}

fn missing(serial: u32, symbol: []const u8) ?*Loaded {
    std.debug.print("[zdb] generation {d} has no {s}; not activated\n", .{ serial, symbol });
    return null;
}

// ═══ Stops — the ring recenters at inflections; locals get their first level queued ═══

const Stop = struct { file: []const u8, function: []const u8, line: usize };
var stop: ?Stop = null;
var last_stop_function: []const u8 = "";

/// CALLED BY: live.onBreak, runtime.handleStepBefore and runtime.handleBreakpoint,
/// host side, once execution is actually paused.
pub fn onStop(file_path: []const u8, function_name: []const u8, line: usize, locals: []const LocalRef) void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return;
    const cfg = config() orelse return;
    const file = relative(cfg.source_dir, file_path);
    const here: Stop = .{ .file = file, .function = function_name, .line = line };
    stop = here;
    armed.store(true, .monotonic); // stepping from here may enter functions no generation covers
    pollPending();
    const idx = ensureIndex() orelse return;
    const func = idx.inFile(file, function_name) orelse return;
    if (!std.mem.eql(u8, function_name, last_stop_function)) {
        last_stop_function = function_name; // entered or returned into another function: recenter
        buildRing(func, .background);
    }
    for (locals) |ref| { // gravy: every struct-ish local's first level, built quietly behind the ring
        if (!wantsInspector(ref)) continue;
        queueInspector(func, cacheKey(ref, ""), buildKey(here, ref, ""));
    }
    startQueuedInspectors(cfg);
}

// ═══ Inspection — printers per type+path, each with a level printer one field down ═══

const Printer = struct { print: InspectFn, level: LevelFn };
const Want = struct { cache_key: []const u8, build_key: []const u8 };
const Job = struct { serial: u32, wants: []const Want };

var inspectors: std.StringHashMapUnmanaged(Printer) = .empty; // "<@typeName of local><path>"
var inspect_queue: std.ArrayList(Want) = .empty; // background wants, all compiled in inspect_context
var inspect_context: ?*const Function = null;
var inspect_pending: ?Job = null; // at most one background inspector build

const inspect_queue_max = 16;

/// Same rule as the REPLs: scalars print from bytes, everything else needs a printer.
fn wantsInspector(ref: LocalRef) bool {
    if (ref.bytes_len == 0) return false;
    const type_name = ref.type_name_ptr[0..ref.type_name_len];
    if (type_name.len > 0 and (type_name[0] == '*' or type_name[0] == '[')) return true;
    var scratch: [96]u8 = undefined;
    return runtime.formatScalar(&scratch, type_name, ref.bytes_ptr[0..ref.bytes_len]) == null;
}

fn cacheKey(ref: LocalRef, rest: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ ref.type_name_ptr[0..ref.type_name_len], rest }) catch "";
}

fn buildKey(here: Stop, ref: LocalRef, rest: []const u8) []const u8 {
    return std.fmt.allocPrint(gpa, "{s}:{s}:{d}:{s}:{s}", .{ here.file, here.function, here.line, ref.name_ptr[0..ref.name_len], rest }) catch "";
}

fn wanted(list: []const Want, cache_key: []const u8) bool {
    for (list) |want| {
        if (std.mem.eql(u8, want.cache_key, cache_key)) return true;
    }
    return false;
}

fn queueInspector(func: *const Function, cache_key: []const u8, build_key: []const u8) void {
    if (cache_key.len == 0 or build_key.len == 0 or inspectors.contains(cache_key)) return;
    if (inspect_pending) |job| {
        if (wanted(job.wants, cache_key)) return;
    }
    if (inspect_context != func) { // one build compiles in one function: a new one replaces the queue
        inspect_queue.clearRetainingCapacity();
        inspect_context = func;
    }
    if (wanted(inspect_queue.items, cache_key) or inspect_queue.items.len >= inspect_queue_max) return;
    inspect_queue.append(gpa, .{ .cache_key = cache_key, .build_key = build_key }) catch {};
}

fn startQueuedInspectors(cfg: Config) void {
    if (pending != null or inspect_pending != null or inspect_queue.items.len == 0) return; // ring first; one at a time
    const func = inspect_context orelse return;
    const wants = gpa.dupe(Want, inspect_queue.items) catch return;
    inspect_queue.clearRetainingCapacity();
    const keys = gpa.alloc([]const u8, wants.len) catch return;
    for (wants, keys) |want, *key| key.* = want.build_key;
    const serial = next_serial;
    next_serial += 1;
    if (!launch(cfg, serial, &.{func}, keys, true)) return;
    inspect_pending = .{ .serial = serial, .wants = wants };
}

/// "x.a.b" → parent "x.a", field "b". Only a trailing `.name` qualifies (not [i], not a range).
fn parentPath(rest: []const u8) ?struct { parent: []const u8, field: []const u8 } {
    const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
    const field_name = rest[dot + 1 ..];
    if (field_name.len == 0 or std.mem.indexOfAny(u8, field_name, "[]") != null) return null;
    if (dot > 0 and rest[dot - 1] == '.') return null; // inside a..b
    return .{ .parent = rest[0..dot], .field = field_name };
}

fn run(printer: InspectFn, ref: LocalRef, out: []u8) []const u8 {
    const written = printer(@ptrCast(ref.bytes_ptr), out.ptr, out.len);
    return out[0..@min(written, out.len)];
}

/// CALLED BY: the REPLs, for a non-scalar local or a path on one. Order:
/// built → instant; one field below something built → its level printer, instant
/// (and this path's own level queued behind); covered by a background build → wait
/// for that one; otherwise build now.
pub fn inspect(ref: LocalRef, rest: []const u8, out: []u8) []const u8 {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return "generations unavailable on this OS";
    const here = stop orelse return "no stop to inspect from";
    const cfg = configOrReport() orelse return "generations unavailable (start the app with `zig build debug`)";
    if (ref.bytes_len == 0) return "<no runtime bytes>";
    for (rest) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '[' or c == ']'))
            return "paths may only use names, '.', [index] and [a..b]";
    }
    const key = cacheKey(ref, rest);
    if (inspectors.get(key)) |printer| return run(printer.print, ref, out);

    const idx = ensureIndex() orelse return "no function index";
    const func = idx.inFile(here.file, here.function) orelse return "this function can't be regenerated (generic or nested), so it can't be inspected";

    if (parentPath(rest)) |split| {
        if (inspectors.get(cacheKey(ref, split.parent))) |parent| {
            queueInspector(func, key, buildKey(here, ref, rest)); // stay one level ahead
            startQueuedInspectors(cfg);
            const written = parent.level(@ptrCast(ref.bytes_ptr), split.field.ptr, split.field.len, out.ptr, out.len);
            return out[0..@min(written, out.len)];
        }
    }

    if (inspect_pending) |job| {
        if (wanted(job.wants, key)) {
            while (inspect_pending != null and inspect_pending.?.serial == job.serial) {
                pollPending();
                if (inspect_pending != null and inspect_pending.?.serial == job.serial) _ = usleep(50_000);
            }
            if (inspectors.get(key)) |printer| return run(printer.print, ref, out);
        }
    }

    std.debug.print("[zdb] building inspector for {s}{s}…\n", .{ ref.name_ptr[0..ref.name_len], rest });
    const want: Want = .{ .cache_key = key, .build_key = buildKey(here, ref, rest) };
    const serial = next_serial;
    next_serial += 1;
    if (!launch(cfg, serial, &.{func}, &.{want.build_key}, false)) return "couldn't start the inspector build";
    _ = finish(cfg, serial, .inspect, &.{want}) orelse return "inspector build failed (log path printed above)";
    const printer = inspectors.get(key) orelse return "inspector generation has no zdb_inspect_0";
    return run(printer.print, ref, out);
}

// ═══ Inspector printing — runs inside the inspector dylib, trusts no pointer ═══

extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn write(fd: c_int, buf: *const anyopaque, n: usize) isize;
extern "c" fn read(fd: c_int, buf: *anyopaque, n: usize) isize;

var probe_pipe: ?[2]c_int = null;
const probe_page = 4096; // probe granularity; valid on both supported OSes

/// Every page in [address, address+len) is mapped. write(2) returns EFAULT for an
/// unmapped source instead of faulting, so a pipe is a crash-free probe.
pub fn readable(address: usize, len: usize) bool {
    if (address == 0) return false;
    const fds = probe_pipe orelse blk: {
        var fresh: [2]c_int = undefined;
        if (pipe(&fresh) != 0) return false;
        probe_pipe = fresh;
        break :blk fresh;
    };
    const last = address +| (if (len == 0) 0 else len - 1);
    var at = address;
    for (0..64) |_| { // huge ranges: the first 64 pages decide
        if (write(fds[1], @ptrFromInt(at), 1) != 1) return false;
        var sink: u8 = undefined;
        _ = read(fds[0], &sink, 1); // keep the pipe empty
        const next = (at / probe_page + 1) * probe_page;
        if (next > last) return true;
        at = next;
    }
    return true;
}

var path_error: []const u8 = "";
var path_error_buf: [96]u8 = undefined;

fn followable(comptime info: std.builtin.Type.Pointer) bool {
    return info.size == .one and @typeInfo(info.child) != .@"opaque" and @typeInfo(info.child) != .@"fn";
}

/// P = *X: the type reached by following X's single pointers.
fn Target(comptime P: type) type {
    const Child = @typeInfo(P).pointer.child;
    return switch (@typeInfo(Child)) {
        .pointer => |info| if (followable(info)) Target(*info.child) else Child,
        else => Child,
    };
}

fn Elem(comptime C: type) type {
    return switch (@typeInfo(C)) {
        .array => |info| info.child,
        .pointer => |info| info.child,
        else => void,
    };
}

/// Follow single pointers from `p`, probing each hop.
pub fn target(p: anytype) ?*Target(@TypeOf(p)) {
    const Child = @typeInfo(@TypeOf(p)).pointer.child;
    if (comptime @typeInfo(Child) == .pointer and followable(@typeInfo(Child).pointer)) {
        const Next = @typeInfo(Child).pointer.child;
        const address = @intFromPtr(p.*);
        if (address % @alignOf(Next) != 0 or !readable(address, @sizeOf(Next))) {
            path_error = std.fmt.bufPrint(&path_error_buf, "pointer 0x{x} isn't readable", .{address}) catch "pointer isn't readable";
            return null;
        }
        return target(@as(*Next, @ptrFromInt(address)));
    }
    return @constCast(p);
}

/// Emitted per `.name` segment of an inspector path.
pub fn field(p: anytype, comptime name: []const u8) ?*@FieldType(Target(@TypeOf(p)), name) {
    const t = target(p) orelse return null;
    return &@field(t.*, name);
}

/// Emitted per `[i]` segment: bounds-checked, element memory probed.
pub fn index(p: anytype, i: usize) ?*Elem(Target(@TypeOf(p))) {
    const C = Target(@TypeOf(p));
    const t = target(p) orelse return null;
    if (comptime @typeInfo(C) == .array) {
        if (i >= t.len) {
            outOfRange(i, t.len);
            return null;
        }
        return &t.*[i];
    } else if (comptime @typeInfo(C) == .pointer and @typeInfo(C).pointer.size == .slice) {
        const items = t.*;
        if (i >= items.len) {
            outOfRange(i, items.len);
            return null;
        }
        if (!readable(@intFromPtr(items.ptr) + i * @sizeOf(Elem(C)), @sizeOf(Elem(C)))) {
            path_error = "slice memory isn't readable";
            return null;
        }
        return @constCast(&items[i]);
    } else {
        @compileError("zdb: [i] needs an array or slice, got " ++ @typeName(C));
    }
}

/// Emitted for a final `[a..b]` segment (the panel's pages).
pub fn range(p: anytype, a: usize, b: usize) ?[]const Elem(Target(@TypeOf(p))) {
    const E = Elem(Target(@TypeOf(p)));
    const t = target(p) orelse return null;
    const all: []const E = t.*[0..];
    if (a > b or b > all.len) {
        path_error = std.fmt.bufPrint(&path_error_buf, "range {d}..{d} out of bounds (len {d})", .{ a, b, all.len }) catch "range out of bounds";
        return null;
    }
    if (b > a and !readable(@intFromPtr(all.ptr) + a * @sizeOf(E), (b - a) * @sizeOf(E))) {
        path_error = "slice memory isn't readable";
        return null;
    }
    return all[a..b];
}

fn outOfRange(i: usize, len: usize) void {
    path_error = std.fmt.bufPrint(&path_error_buf, "index {d} out of range (len {d})", .{ i, len }) catch "index out of range";
}

/// Emitted when a path step returned null: the reason instead of a value.
pub fn pathFailed(buffer: []u8) usize {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print("<{s}>\n", .{path_error}) catch {};
    return writer.end;
}

/// Emitted in each level printer: one field of the path's target, chosen by name at run time.
pub fn formatField(buffer: []u8, p: anytype, name: []const u8) usize {
    const T = Target(@TypeOf(p));
    if (comptime @typeInfo(T) != .@"struct") {
        path_error = "no fields here";
        return pathFailed(buffer);
    } else {
        const t = target(p) orelse return pathFailed(buffer);
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (!f.is_comptime and std.mem.eql(u8, f.name, name)) return formatInto(buffer, &@field(t.*, f.name));
        }
        path_error = "no such field";
        return pathFailed(buffer);
    }
}

/// Level printer of a path ending in [a..b]: a range has no fields.
pub fn noFields(buffer: []u8) usize {
    path_error = "a range has no fields";
    return pathFailed(buffer);
}

/// Emitted by inspector code; compiled once per inspected type. Shaped for the
/// panel: structs one `.field = value` per line (clickable), slices as a
/// `[](N items)` header plus `[i]` rows (pageable). Pointers show their target.
pub fn formatInto(buffer: []u8, value: anytype) usize {
    var writer: std.Io.Writer = .fixed(buffer);
    writeValue(&writer, value) catch {}; // full buffer ⇒ truncated output, still shown
    return writer.end;
}

const line_max = 160; // one field/item row; longer values end in …
const slice_rows_max = 64; // the panel pages bigger slices through [a..b] paths
const text_max = 120;

fn writeValue(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (comptime followable(pointer)) {
                if (!readable(@intFromPtr(value), @sizeOf(pointer.child)))
                    return writer.print("<pointer 0x{x} isn't readable>\n", .{@intFromPtr(value)});
                return writeValue(writer, value.*);
            }
            if (pointer.size == .slice) {
                if (pointer.child == u8) {
                    try writeText(writer, value);
                    return writer.writeAll("\n");
                }
                const rows: usize = @min(value.len, slice_rows_max); // explicit: @min would narrow to u7
                if (rows > 0 and !readable(@intFromPtr(value.ptr), rows * @sizeOf(pointer.child))) {
                    try writer.print("{s}\n[]({d} items)\n", .{ @typeName(T), value.len });
                    return writer.writeAll("<items aren't readable>\n");
                }
                return writeRows(writer, @typeName(T), value);
            }
        },
        .array => |info| {
            if (info.child == u8) {
                try writeText(writer, value[0..]);
                return writer.writeAll("\n");
            }
            return writeRows(writer, @typeName(T), value[0..]); // same rows as a slice: [i] clickable, pageable
        },
        .optional => return if (value) |inner| writeValue(writer, inner) else writer.writeAll("null\n"),
        .@"struct" => |info| {
            if (!info.is_tuple) {
                try writer.print("{s} {{\n", .{@typeName(T)});
                inline for (info.fields) |f| {
                    if (f.is_comptime) continue;
                    try writer.print("  .{s} = ", .{f.name});
                    try writeLine(writer, @field(value, f.name));
                }
                return writer.writeAll("}\n");
            }
        },
        else => {},
    }
    try writeLine(writer, value);
}

/// `[](N items)` header (the panel pages on it) + one `[i]` row per element, first slice_rows_max.
fn writeRows(writer: *std.Io.Writer, type_name: []const u8, items: anytype) std.Io.Writer.Error!void {
    try writer.print("{s}\n[]({d} items)\n", .{ type_name, items.len });
    const rows: usize = @min(items.len, slice_rows_max);
    for (items[0..rows], 0..) |item, i| {
        try writer.print("  [{d}] ", .{i});
        try writeLine(writer, item);
    }
}

fn writeLine(writer: *std.Io.Writer, value: anytype) std.Io.Writer.Error!void {
    var buf: [line_max]u8 = undefined;
    var line: std.Io.Writer = .fixed(&buf);
    writeCompact(&line, value, 1) catch {}; // full ⇒ cut, marked below
    try writer.writeAll(buf[0..line.end]);
    if (line.end == buf.len) try writer.writeAll("…");
    try writer.writeAll("\n");
}

fn writeText(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const shown = @min(text.len, text_max);
    if (shown > 0 and !readable(@intFromPtr(text.ptr), shown)) return writer.writeAll("<text isn't readable>");
    try writer.print("\"{s}\"", .{text[0..shown]});
    if (text.len > shown) try writer.writeAll("…");
}

/// One-line value that never follows a pointer (shown as @0x…; click the field to follow).
fn writeCompact(writer: *std.Io.Writer, value: anytype, depth: u8) std.Io.Writer.Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum", .vector => return writer.print("{any}", .{value}),
        .void => return writer.writeAll("{}"),
        .optional => return if (value) |inner| writeCompact(writer, inner, depth) else writer.writeAll("null"),
        .error_union => return if (value) |inner| writeCompact(writer, inner, depth) else |err| writer.print("error.{s}", .{@errorName(err)}),
        .error_set => return writer.print("error.{s}", .{@errorName(value)}),
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                if (pointer.child == u8) return writeText(writer, value);
                return writer.print("[]({d} items)", .{value.len});
            }
            return writer.print("@0x{x}", .{@intFromPtr(value)});
        },
        .array => |info| {
            if (depth == 0 or info.len > 8) return writer.print("[{d}]{{…}}", .{info.len});
            try writer.writeAll("{ ");
            for (value, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeCompact(writer, item, depth - 1);
            }
            return writer.writeAll(" }");
        },
        .@"struct" => |info| {
            if (depth == 0) return writer.writeAll("{…}");
            try writer.writeAll(".{ ");
            inline for (info.fields, 0..) |f, i| {
                if (f.is_comptime) continue;
                if (i > 0) try writer.writeAll(", ");
                if (!info.is_tuple) try writer.print(".{s} = ", .{f.name});
                try writeCompact(writer, @field(value, f.name), depth - 1);
            }
            return writer.writeAll(" }");
        },
        .@"union" => |info| {
            if (info.tag_type == null) return writer.writeAll("<untagged union>");
            switch (value) {
                inline else => |payload, tag| {
                    try writer.print(".{s}", .{@tagName(tag)});
                    if (@TypeOf(payload) != void) {
                        try writer.writeAll(" = ");
                        try writeCompact(writer, payload, depth -| 1);
                    }
                },
            }
        },
        else => return writer.print("<{s}>", .{@typeName(T)}),
    }
}
