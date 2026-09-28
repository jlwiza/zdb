const std = @import("std");
const builtin = @import("builtin");
const sidecar_abi = @import("sidecar_abi.zig");
const generation_loader = @import("dylib_generation");
const gen = @import("gen.zig");

// Global state for debugging
pub var step_mode: bool = false;
// FIXED: Now using a stack of functions instead of single function
pub var step_functions: [32]?[]const u8 = [_]?[]const u8{null} ** 32;
pub var step_function_count: usize = 0;
var watch_expressions: []const WatchExpr = &.{};
var breakpoint_count: usize = 0;
var breakpoint_timestamp: ?std.Io.Timestamp = null;

const Sidecar = struct {
    generation: generation_loader.Generation,
    on_pause: sidecar_abi.OnPauseFn,
    continue_fn: ?sidecar_abi.ContinueFn,
};

var loaded_sidecar: ?Sidecar = null;
var configured_sidecar_path: ?[]const u8 = null;
var sidecar_load_serial: usize = 0;

/// Overrides `ZDB_SIDECAR_PATH`. The caller must keep `path` alive for the
/// duration of the process. This is useful for embedders and test fixtures.
pub fn configureSidecar(path: []const u8) void {
    configured_sidecar_path = path;
}

fn environmentSidecarPath() ?[]const u8 {
    if (comptime builtin.os.tag == .windows) return null;
    const value = std.c.getenv("ZDB_SIDECAR_PATH") orelse return null;
    return std.mem.span(value);
}

fn sidecarPath() ?[]const u8 {
    return configured_sidecar_path orelse environmentSidecarPath();
}

fn unloadSidecar() void {
    if (loaded_sidecar) |*sidecar| {
        sidecar.generation.deinit(std.heap.page_allocator, runtime.io());
    }
    loaded_sidecar = null;
}

fn openSidecar(path: []const u8) !Sidecar {
    const parent = std.fs.path.dirname(path) orelse ".";
    const live_dir = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "{s}/.zdb-live",
        .{parent},
    );
    defer std.heap.page_allocator.free(live_dir);
    var candidate = try generation_loader.open(
        std.heap.page_allocator,
        runtime.io(),
        path,
        live_dir,
        sidecar_load_serial,
    );
    errdefer candidate.deinit(std.heap.page_allocator, runtime.io());
    const version_fn = candidate.dl.lookup(sidecar_abi.VersionFn, "zdb_sidecar_abi_version") orelse {
        std.debug.print("[zdb sidecar] {s} has no ABI version symbol\n", .{path});
        return error.MissingVersion;
    };
    if (version_fn() != sidecar_abi.version) {
        std.debug.print("[zdb sidecar] ABI mismatch: executable={d}, library={d}\n", .{ sidecar_abi.version, version_fn() });
        return error.AbiMismatch;
    }
    const on_pause = candidate.dl.lookup(sidecar_abi.OnPauseFn, "zdb_sidecar_on_pause") orelse {
        std.debug.print("[zdb sidecar] {s} has no pause callback\n", .{path});
        return error.MissingPauseCallback;
    };
    const continue_fn = candidate.dl.lookup(sidecar_abi.ContinueFn, "zdb_sidecar_continue");
    return .{ .generation = candidate, .on_pause = on_pause, .continue_fn = continue_fn };
}

fn loadSidecar() bool {
    const path = sidecarPath() orelse return false;
    const candidate = openSidecar(path) catch |err| {
        std.debug.print("[zdb sidecar] could not load {s}: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    sidecar_load_serial += 1;
    unloadSidecar();
    loaded_sidecar = candidate;
    return true;
}

fn pauseEvent(function_name: []const u8, locals: []const sidecar_abi.LocalRef) sidecar_abi.PauseEvent {
    return .{
        .function_name_ptr = function_name.ptr,
        .function_name_len = function_name.len,
        .breakpoint_count = breakpoint_count,
        .locals_ptr = if (locals.len == 0) null else @constCast(locals.ptr), // ABI field is mutable; records are read-only by contract
        .locals_len = locals.len,
    };
}

fn notifySidecar(function_name: []const u8, locals: []const sidecar_abi.LocalRef) sidecar_abi.ContinuationOutcome {
    if (loaded_sidecar == null and !loadSidecar()) return .remain_paused;
    var reply: sidecar_abi.PauseReply = .{
        .generation = 0,
        .message_len = 0,
        .message = undefined,
        .outcome = .remain_paused,
    };
    const event = pauseEvent(function_name, locals);
    loaded_sidecar.?.on_pause(&event, &reply);
    const message_len = @min(reply.message_len, reply.message.len);
    std.debug.print("[zdb sidecar] {s}\n", .{reply.message[0..message_len]});
    return switch (reply.outcome) {
        .remain_paused, .continue_execution => reply.outcome,
        .return_from_function => blk: {
            std.debug.print("[zdb sidecar] return_from_function is not supported at this boundary; remaining paused\n", .{});
            break :blk .remain_paused;
        },
        .fail => blk: {
            std.debug.print("[zdb sidecar] continuation reported failure; remaining paused\n", .{});
            break :blk .remain_paused;
        },
    };
}

/// Invoke the post-marker function exported by a generated continuation
/// library. The host owns every byte in the frame; the dylib only borrows it
/// synchronously and must finish before its generation can be retired.
pub fn runSidecarContinuation(function_name: []const u8, locals: []const sidecar_abi.LocalRef) bool {
    if (loaded_sidecar == null and !loadSidecar()) return false;
    const continue_fn = loaded_sidecar.?.continue_fn orelse {
        std.debug.print("[zdb sidecar] loaded generation has no generated continuation\n", .{});
        return false;
    };
    const event = pauseEvent(function_name, locals);
    return switch (continue_fn(&event)) {
        .return_from_function, .continue_execution => true,
        .remain_paused, .fail => false,
    };
}

pub fn reloadSidecarHandoff(function_name: []const u8, locals: []const sidecar_abi.LocalRef) sidecar_abi.ContinuationOutcome {
    if (!loadSidecar()) {
        std.debug.print("[zdb sidecar] reload failed; prior generation remains active\n", .{});
        return .remain_paused;
    }
    return notifySidecar(function_name, locals);
}

pub fn beginSidecarHandoff(function_name: []const u8, locals: []const sidecar_abi.LocalRef) bool {
    breakpoint_count += 1;
    return notifySidecar(function_name, locals) == .continue_execution;
}

// ============================================================================
// Type-erased locals — what every hook emits
// ============================================================================

var no_bytes: [0]u8 = .{}; // bytes_ptr is non-optional; comptime-only locals point here

/// One hooked local: name, type name, pointer, size. Nothing about T is walked
/// for printing; inspection beyond scalars is built on demand, per type.
pub fn localRef(name: []const u8, ptr: anytype) sidecar_abi.LocalRef {
    const pointer = @typeInfo(@TypeOf(ptr)).pointer;
    const T = pointer.child;
    const type_name = @typeName(T);
    if (comptime !runtimeType(T)) return .{ // e.g. `const n = 5;` — no runtime bytes to point at
        .name_ptr = name.ptr,
        .name_len = name.len,
        .type_name_ptr = type_name.ptr,
        .type_name_len = type_name.len,
        .storage = .read_only_pointer,
        .bytes_ptr = &no_bytes,
        .bytes_len = 0,
    };
    return .{
        .name_ptr = name.ptr,
        .name_len = name.len,
        .type_name_ptr = type_name.ptr,
        .type_name_len = type_name.len,
        .storage = if (pointer.is_const) .read_only_pointer else .mutable_pointer, // const local ⇒ &x is *const T
        .bytes_ptr = @ptrCast(@constCast(ptr)),
        .bytes_len = @sizeOf(T),
    };
}

fn localName(ref: sidecar_abi.LocalRef) []const u8 {
    return ref.name_ptr[0..ref.name_len];
}

fn localTypeName(ref: sidecar_abi.LocalRef) []const u8 {
    return ref.type_name_ptr[0..ref.type_name_len];
}

const IntShape = struct { signed: bool, bits: u16 };

fn intShape(type_name: []const u8) ?IntShape {
    if (std.mem.eql(u8, type_name, "usize")) return .{ .signed = false, .bits = @bitSizeOf(usize) };
    if (std.mem.eql(u8, type_name, "isize")) return .{ .signed = true, .bits = @bitSizeOf(isize) };
    if (type_name.len < 2 or (type_name[0] != 'u' and type_name[0] != 'i')) return null;
    const bits = std.fmt.parseInt(u16, type_name[1..], 10) catch return null; // "u32" → 32; "usize"/"i_foo" → null
    return .{ .signed = type_name[0] == 'i', .bits = bits };
}

/// Decode primitive locals straight from bytes by type name — no generic
/// printer involved. Anything else returns null and waits for on-demand inspection.
pub fn formatScalar(buf: []u8, type_name: []const u8, bytes: []const u8) ?[]const u8 {
    const native = builtin.cpu.arch.endian();
    if (std.mem.eql(u8, type_name, "bool") and bytes.len == 1)
        return std.fmt.bufPrint(buf, "{}", .{bytes[0] != 0}) catch null;
    if (std.mem.eql(u8, type_name, "f32") and bytes.len == 4)
        return std.fmt.bufPrint(buf, "{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], native)))}) catch null;
    if (std.mem.eql(u8, type_name, "f64") and bytes.len == 8)
        return std.fmt.bufPrint(buf, "{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], native)))}) catch null;
    const is_pointer = type_name.len > 0 and (type_name[0] == '*' or std.mem.startsWith(u8, type_name, "?*"));
    if (is_pointer and bytes.len == @sizeOf(usize)) // single pointers show their address; ?* null reads as 0x0
        return std.fmt.bufPrint(buf, "0x{x}", .{std.mem.readInt(usize, bytes[0..@sizeOf(usize)], native)}) catch null;
    const shape = intShape(type_name) orelse return null;
    if (shape.bits / 8 != bytes.len) return null; // u24 etc. pad to 4 bytes — leave for on-demand
    inline for (.{ 8, 16, 32, 64 }) |b| {
        if (b == shape.bits) {
            const raw = std.mem.readInt(std.meta.Int(.unsigned, b), bytes[0 .. b / 8], native);
            return if (shape.signed)
                std.fmt.bufPrint(buf, "{d}", .{@as(std.meta.Int(.signed, b), @bitCast(raw))}) catch null
            else
                std.fmt.bufPrint(buf, "{d}", .{raw}) catch null;
        }
    }
    return null;
}

fn printLocal(ref: sidecar_abi.LocalRef) void {
    const type_name = localTypeName(ref);
    styled(ansi.field, "{s}", .{localName(ref)});
    styled(ansi.punctuation, ": ", .{});
    styled(ansi.type_name, "{s}", .{type_name});
    styled(ansi.punctuation, " = ", .{});
    if (ref.bytes_len == 0) {
        styled(ansi.keyword, "<no runtime bytes>", .{});
    } else {
        var buf: [64]u8 = undefined;
        if (formatScalar(&buf, type_name, ref.bytes_ptr[0..ref.bytes_len])) |text| {
            styled(ansi.number, "{s}", .{text});
        } else {
            styled(ansi.pointer, "<{d} bytes @ 0x{x}>", .{ ref.bytes_len, @intFromPtr(ref.bytes_ptr) });
        }
    }
    std.debug.print("\n", .{});
}

fn listLocals(locals: []const sidecar_abi.LocalRef) void {
    styled(ansi.type_name, "Locals", .{});
    styled(ansi.punctuation, " ({d}):\n", .{locals.len});
    for (locals) |ref| {
        std.debug.print("  ", .{});
        printLocal(ref);
    }
}

/// Exact local name → print it. A field/index path on a known local → say so
/// plainly; paths arrive with on-demand inspection, nothing is faked.
/// Scalars print from their bytes; anything else (a struct, or a path on one)
/// gets a printer compiled on demand for exactly that type and path.
fn queryLocal(locals: []const sidecar_abi.LocalRef, cmd: []const u8) bool {
    const expression = expressionFromCommand(cmd);
    for (locals) |ref| {
        const name = localName(ref);
        if (!std.mem.startsWith(u8, expression, name)) continue;
        const rest = expression[name.len..];
        if (rest.len > 0 and rest[0] != '.' and rest[0] != '[') continue; // a longer name, not a path
        if (rest.len == 0) {
            var scratch: [96]u8 = undefined;
            const type_name = localTypeName(ref);
            const indirect = type_name.len > 0 and (type_name[0] == '*' or type_name[0] == '['); // an address isn't the answer; its target is
            if (ref.bytes_len == 0 or (!indirect and formatScalar(&scratch, type_name, ref.bytes_ptr[0..ref.bytes_len]) != null)) {
                printLocal(ref);
                return true;
            }
        }
        var buf: [32 * 1024]u8 = undefined;
        std.debug.print("{s} = {s}\n", .{ expression, gen.inspect(ref, rest, &buf) });
        return true;
    }
    return false;
}

const page_items: usize = 8;
const compact_items: usize = 6;
const max_struct_fields: usize = 12;
const max_string_bytes: usize = 160;
const max_print_depth: usize = 3;

const ansi = struct {
    const reset = "\x1b[0m";
    const punctuation = "\x1b[38;5;244m";
    const type_name = "\x1b[38;5;141m";
    const field = "\x1b[38;5;80m";
    const number = "\x1b[38;5;215m";
    const string = "\x1b[38;5;114m";
    const keyword = "\x1b[38;5;176m";
    const enum_value = "\x1b[38;5;221m";
    const pointer = "\x1b[38;5;109m";
};

var color_enabled: ?bool = null;

pub var runtime: Runtime = .{};

const WatchExpr = struct {
    name: []const u8,
    check_fn: *const fn () bool,
};

pub const Runtime = struct {
    threaded: std.Io.Threaded = .init_single_threaded,

    pub fn deinit(self: *Runtime) void {
        self.threaded.deinit();
    }

    pub fn io(self: *Runtime) std.Io {
        return self.threaded.io();
    }
};
pub fn canAddress(comptime T: type) bool {
    @setEvalBranchQuota(10_000_000);
    return switch (@typeInfo(T)) {
        .comptime_int, .comptime_float, .type, .null, .undefined, .enum_literal => false,
        else => true,
    };
}

fn runtimeType(comptime T: type) bool {
    @setEvalBranchQuota(10_000_000);
    return switch (@typeInfo(T)) {
        .type, .@"fn", .comptime_int, .comptime_float, .enum_literal => false,
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (field.is_comptime or !runtimeType(field.type)) break :blk false;
            }
            break :blk true;
        },
        // A slice of type metadata cannot be indexed by the runtime printers.
        // Single pointers stay opaque during capture.
        .pointer => |info| if (info.size == .slice) runtimeType(info.child) else true,
        .array => |info| runtimeType(info.child),
        .optional => |info| runtimeType(info.child),
        else => true,
    };
}

fn CaptureType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .comptime_int => i128,
        .comptime_float => f64,
        else => if (runtimeType(T)) T else []const u8,
    };
}

/// Preserve application pointers; never dereference an opaque or uninitialized
/// pointee while assembling a locals tuple. Types are displayed by name.
pub fn capture(value: anytype) CaptureType(@TypeOf(value)) {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .type => @typeName(value),
        .comptime_int, .comptime_float => value,
        .enum_literal => @tagName(value),
        else => if (comptime runtimeType(T)) value else @typeName(T),
    };
}

fn CaptureRef(comptime Pointer: type) type {
    return struct {
        pub const zdb_capture_ref = true;
        ptr: Pointer,
    };
}

fn CaptureCopy(comptime T: type) type {
    return struct {
        pub const zdb_capture_copy = true;
        value: CaptureType(T),
    };
}

/// Keep debugger locals as references so injecting many line hooks does not
/// copy large application values into the function's stack frame. Application
/// pointers remain values behind this wrapper and still print as pointers.
pub fn captureRef(ptr: anytype) CaptureRef(@TypeOf(ptr)) {
    return .{ .ptr = ptr };
}

/// Take a stable breakpoint snapshot. Unlike `captureRef`, a sidecar may read
/// this storage but cannot change the application local through it.
pub fn captureCopy(value: anytype) CaptureCopy(@TypeOf(value)) {
    return .{ .value = capture(value) };
}

fn isCaptureRef(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zdb_capture_ref");
}

fn isCaptureCopy(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zdb_capture_copy");
}

pub fn rebuild(values: anytype) @TypeOf(values) {
    return values;
}
// Check if we should step in the current function
pub fn isStepping() bool {
    if (gen.remote()) |api| return api.isStepping(); // generated code: step state lives in the host
    return step_mode;
}

fn shouldStepInFunction(function_name: []const u8) bool {
    if (!step_mode) return false;

    // Check if this function is in our step stack
    var i: usize = 0;
    while (i < step_function_count) : (i += 1) {
        if (step_functions[i]) |sf| {
            if (std.mem.eql(u8, sf, function_name)) {
                return true;
            }
        }
    }
    return false;
}

// Add a function to the step stack
fn addFunctionToStepStack(function_name: []const u8) void {
    if (step_function_count < step_functions.len) {
        step_functions[step_function_count] = function_name;
        step_function_count += 1;
    }
}

// Auto-trim the stack when we return to a function
fn autoTrimStepStack(function_name: []const u8) void {
    var i: usize = 0;
    while (i < step_function_count) : (i += 1) {
        if (step_functions[i]) |sf| {
            if (std.mem.eql(u8, sf, function_name)) {
                step_function_count = i + 1;
                return;
            }
        }
    }
}

fn colorsEnabled() bool {
    if (color_enabled) |enabled| return enabled;
    const enabled = std.Io.File.stderr().isTty(runtime.io()) catch false;
    color_enabled = enabled;
    return enabled;
}

fn styled(comptime color: []const u8, comptime format: []const u8, args: anytype) void {
    if (colorsEnabled()) {
        std.debug.print(color ++ format ++ ansi.reset, args);
    } else {
        std.debug.print(format, args);
    }
}

fn shortTypeName(comptime T: type) []const u8 {
    const name = @typeName(T);
    if (std.mem.lastIndexOf(u8, name, ".")) |dot| return name[dot + 1 ..];
    return name;
}

fn printDepthSummary(comptime T: type, value: anytype) void {
    const info = @typeInfo(T);
    switch (info) {
        .pointer => |pointer| {
            if (pointer.size == .slice) {
                styled(ansi.punctuation, "<", .{});
                styled(ansi.type_name, "[]{s}", .{shortTypeName(pointer.child)});
                styled(ansi.punctuation, " len=", .{});
                styled(ansi.number, "{}", .{value.len});
                styled(ansi.punctuation, ">", .{});
            } else {
                styled(ansi.pointer, "<*{s} 0x{x}>", .{ shortTypeName(pointer.child), @intFromPtr(value) });
            }
        },
        .array => |array| {
            styled(ansi.punctuation, "<", .{});
            styled(ansi.type_name, "[{}]{s}", .{ array.len, shortTypeName(array.child) });
            styled(ansi.punctuation, ">", .{});
        },
        .@"struct" => {
            styled(ansi.type_name, "{s}", .{shortTypeName(T)});
            styled(ansi.punctuation, "{{ ... }}", .{});
        },
        else => std.debug.print("{any}", .{value}),
    }
}

// Pretty printer for any type
pub fn debugPrint(name: []const u8, value: anytype) void {
    debugPrintWithPage(name, value, 0);
}

pub fn debugPrintWithPage(name: []const u8, value: anytype, page: usize) void {
    const T = @TypeOf(value);
    if (comptime isCaptureRef(T)) {
        debugPrintWithPage(name, value.ptr.*, page);
        return;
    }
    if (comptime isCaptureCopy(T)) {
        debugPrintWithPage(name, value.value, page);
        return;
    }
    const type_info = @typeInfo(T);

    // Captured locals such as `self` are references to pointer variables.
    // Dereference the application pointer here so our bounded printer handles
    // the pointee instead of `{any}` dumping the complete object graph.
    if (comptime canDereferencePointer(T)) {
        if (@intFromPtr(value) == 0) {
            styled(ansi.field, "{s}", .{name});
            styled(ansi.punctuation, " = ", .{});
            styled(ansi.keyword, "null", .{});
            std.debug.print("\n", .{});
            return;
        }
        debugPrintWithPage(name, value.*, page);
        return;
    }

    // For arrays, apply paging. Byte arrays/slices are strings, so keep them
    // intact instead of presenting eight unrelated characters per page.
    const is_byte_string = switch (type_info) {
        .array => |array| array.child == u8,
        .pointer => |pointer| pointer.size == .slice and pointer.child == u8,
        else => false,
    };
    if (!is_byte_string and (type_info == .array or type_info == .pointer) and
        (type_info == .array or (type_info == .pointer and type_info.pointer.size == .slice)))
    {
        const array_len = if (type_info == .array) value.len else value.len;
        if (array_len > page_items) {
            const start = page * page_items;
            if (start >= array_len) {
                std.debug.print("{s} = (page {} is out of range, max page is {})\n", .{ name, page, (array_len - 1) / page_items });
                return;
            }
            const end = @min(start + page_items, array_len);

            const child_type = if (type_info == .array) type_info.array.child else type_info.pointer.child;
            if (@typeInfo(child_type) == .@"struct") {
                styled(ansi.field, "{s}", .{name});
                std.debug.print(" (page {}/{}): ", .{ page + 1, (array_len + page_items - 1) / page_items });
                debugPrintStructArray(value[start..end], start, 0);
            } else {
                std.debug.print("{s}[{}..{}] (page {}/{} of {} items) = ", .{ name, start, end, page + 1, (array_len + page_items - 1) / page_items, array_len });
                debugPrintValue(value[start..end], 0, false);
                std.debug.print("\n", .{});
            }
            return;
        }
    }

    styled(ansi.field, "{s}", .{name});
    styled(ansi.punctuation, " = ", .{});
    debugPrintValue(value, 0, false);
    std.debug.print("\n", .{});
}

pub fn debugPrintRange(name: []const u8, value: anytype, start: usize, end: usize) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    if (type_info == .array or (type_info == .pointer and type_info.pointer.size == .slice)) {
        const actual_end = @min(end, value.len);
        const actual_start = @min(start, value.len);

        std.debug.print("{s}[{}..{}] = ", .{ name, start, end });

        if (actual_start >= value.len) {
            std.debug.print("(out of range)\n", .{});
            return;
        }

        if (type_info == .array) {
            if (@typeInfo(type_info.array.child) == .@"struct") {
                debugPrintStructArray(value[actual_start..actual_end], actual_start, 0);
                return;
            }
        }

        std.debug.print("[\n", .{});
        var i = actual_start;
        while (i < actual_end) : (i += 1) {
            std.debug.print("  [{}] = ", .{i});
            debugPrintValue(value[i], 1, false);
            std.debug.print("\n", .{});
        }
        std.debug.print("]\n", .{});
    } else {
        std.debug.print("{s} = (not an array)\n", .{name});
    }
}

fn debugPrintValue(value: anytype, indent: usize, compact: bool) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    if (indent >= max_print_depth and switch (type_info) {
        .pointer, .array, .@"struct" => true,
        else => false,
    }) {
        printDepthSummary(T, value);
        return;
    }

    switch (type_info) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                printString(value);
            } else if (ptr.size == .slice) {
                if (@typeInfo(ptr.child) == .@"struct" and value.len > 0) {
                    debugPrintStructArray(value, 0, indent);
                } else {
                    debugPrintSimpleArray(value, indent, compact);
                }
            } else if (comptime canDereferencePointer(T)) {
                if (@intFromPtr(value) == 0) {
                    styled(ansi.keyword, "null", .{});
                } else if (compact) {
                    styled(ansi.pointer, "*", .{});
                    debugPrintValue(value.*, indent + 1, true);
                } else {
                    debugPrintValue(value.*, indent + 1, false);
                }
            } else {
                styled(ansi.pointer, "<ptr 0x{x}>", .{@intFromPtr(value)});
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                printString(&value);
            } else if (@typeInfo(arr.child) == .@"struct" and arr.len > 0) {
                debugPrintStructArray(&value, 0, indent);
            } else {
                debugPrintSimpleArray(&value, indent, compact);
            }
        },
        .@"struct" => {
            debugPrintStruct(value, indent, compact);
        },
        .@"enum" => styled(ansi.enum_value, "{any}", .{value}),
        .optional => {
            if (value) |v| {
                debugPrintValue(v, indent, compact);
            } else {
                styled(ansi.keyword, "null", .{});
            }
        },
        .int => styled(ansi.number, "{}", .{value}),
        .float => styled(ansi.number, "{d:.1}", .{value}),
        .bool => styled(ansi.keyword, "{}", .{value}),
        .@"fn" => styled(ansi.type_name, "<fn>", .{}),
        else => std.debug.print("{any}", .{value}),
    }
}

fn debugPrintSimpleArray(value: anytype, indent: usize, compact: bool) void {
    const len = value.len;
    const limit = if (compact) compact_items else page_items;

    if (len <= limit) {
        styled(ansi.punctuation, "[ ", .{});
        for (value, 0..) |item, i| {
            if (i > 0) styled(ansi.punctuation, ", ", .{});
            debugPrintValue(item, indent, true);
        }
        styled(ansi.punctuation, " ]", .{});
    } else {
        styled(ansi.punctuation, "[ ", .{});
        for (0..@min(limit, len)) |i| {
            if (i > 0) styled(ansi.punctuation, ", ", .{});
            debugPrintValue(value[i], indent, true);
        }
        styled(ansi.punctuation, ", ... (", .{});
        styled(ansi.number, "{}", .{len});
        styled(ansi.punctuation, " items total) ]", .{});
    }
}

fn debugPrintStruct(value: anytype, indent: usize, compact: bool) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    const fields = type_info.@"struct".fields;

    if (fields.len == 0) {
        styled(ansi.punctuation, "{{}}", .{});
        return;
    }

    const type_name = @typeName(T);
    const is_anon = std.mem.indexOf(u8, type_name, "__struct_") != null;

    if (is_anon and fields.len == 2 and
        @hasField(T, "x") and @hasField(T, "y"))
    {
        const x_type = @TypeOf(@field(value, "x"));
        const y_type = @TypeOf(@field(value, "y"));
        if (@typeInfo(x_type) == .float and @typeInfo(y_type) == .float) {
            styled(ansi.punctuation, "(", .{});
            styled(ansi.number, "{d:.1}", .{@field(value, "x")});
            styled(ansi.punctuation, ", ", .{});
            styled(ansi.number, "{d:.1}", .{@field(value, "y")});
            styled(ansi.punctuation, ")", .{});
            return;
        }
    }

    if (compact or fields.len <= 4) {
        if (!is_anon) {
            if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_pos| {
                styled(ansi.type_name, "{s}", .{type_name[dot_pos + 1 ..]});
            } else {
                styled(ansi.type_name, "{s}", .{type_name});
            }
            styled(ansi.punctuation, "{{ ", .{});
        } else {
            styled(ansi.punctuation, "{{ ", .{});
        }

        inline for (fields, 0..) |field, i| {
            if (i >= max_struct_fields) continue;
            if (i > 0) styled(ansi.punctuation, ", ", .{});
            styled(ansi.punctuation, ".", .{});
            styled(ansi.field, "{s}", .{field.name});
            styled(ansi.punctuation, " = ", .{});
            debugPrintValue(@field(value, field.name), indent + 1, true);
        }
        if (fields.len > max_struct_fields) std.debug.print(", ... {} more", .{fields.len - max_struct_fields});
        styled(ansi.punctuation, " }}", .{});
    } else {
        if (!is_anon) {
            if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_pos| {
                styled(ansi.type_name, "{s}", .{type_name[dot_pos + 1 ..]});
            } else {
                styled(ansi.type_name, "{s}", .{type_name});
            }
            styled(ansi.punctuation, "{{", .{});
            std.debug.print("\n", .{});
        } else {
            styled(ansi.punctuation, "{{", .{});
            std.debug.print("\n", .{});
        }

        inline for (fields, 0..) |field, i| {
            if (i >= max_struct_fields) continue;
            for (0..((indent + 1) * 2)) |_| std.debug.print(" ", .{});
            styled(ansi.punctuation, ".", .{});
            styled(ansi.field, "{s}", .{field.name});
            styled(ansi.punctuation, " = ", .{});
            debugPrintValue(@field(value, field.name), indent + 1, true);
            std.debug.print("\n", .{});
        }
        if (fields.len > max_struct_fields) {
            for (0..((indent + 1) * 2)) |_| std.debug.print(" ", .{});
            std.debug.print("... {} more fields (query with value.field)\n", .{fields.len - max_struct_fields});
        }
        for (0..(indent * 2)) |_| std.debug.print(" ", .{});
        styled(ansi.punctuation, "}}", .{});
    }
}

fn debugPrintStructArray(items: anytype, start_index: usize, indent: usize) void {
    if (items.len == 0) {
        std.debug.print("[]\n", .{});
        return;
    }

    const T = @TypeOf(items[0]);
    const fields = @typeInfo(T).@"struct".fields;

    const items_to_show = @min(items.len, page_items);
    const show_items = items[0..items_to_show];
    var column_widths = [_]usize{3} ** page_items;
    for (show_items, 0..) |item, column| {
        inline for (fields, 0..) |field, field_index| {
            if (field_index >= max_struct_fields) continue;
            column_widths[column] = @max(column_widths[column], @min(valueDisplayWidth(@field(item, field.name)), 24));
        }
    }

    styled(ansi.punctuation, "[", .{});
    std.debug.print("\n", .{});

    std.debug.print("            ", .{});
    for (show_items, 0..) |_, i| {
        const header_width = std.fmt.count("[{}]", .{start_index + i});
        styled(ansi.punctuation, "[", .{});
        styled(ansi.number, "{}", .{start_index + i});
        styled(ansi.punctuation, "]", .{});
        for (header_width..column_widths[i] + 1) |_| std.debug.print(" ", .{});
    }
    std.debug.print("\n", .{});

    inline for (fields, 0..) |field, field_index| {
        if (field_index >= max_struct_fields) continue;
        std.debug.print("  ", .{});
        styled(ansi.field, "{s:<9}", .{field.name ++ ":"});
        std.debug.print(" ", .{});
        for (show_items, 0..) |item, column| {
            const val = @field(item, field.name);
            const T2 = @TypeOf(val);
            const visible_width = @min(valueDisplayWidth(val), 24);

            if (T2 == []const u8 or T2 == []u8) {
                const shown_len = @min(val.len, @min(column_widths[column] -| 2, 22));
                styled(ansi.string, "\"{s}\"", .{val[0..shown_len]});
            } else if (@typeInfo(T2) == .@"struct") {
                const is_point = comptime (@typeInfo(T2).@"struct".fields.len == 2 and
                    @hasField(T2, "x") and @hasField(T2, "y"));
                if (is_point) {
                    const x_is_float = @typeInfo(@TypeOf(@field(val, "x"))) == .float;
                    const y_is_float = @typeInfo(@TypeOf(@field(val, "y"))) == .float;
                    if (x_is_float and y_is_float) {
                        styled(ansi.punctuation, "(", .{});
                        styled(ansi.number, "{d:.1}", .{@field(val, "x")});
                        styled(ansi.punctuation, ", ", .{});
                        styled(ansi.number, "{d:.1}", .{@field(val, "y")});
                        styled(ansi.punctuation, ")", .{});
                    } else {
                        debugPrintValue(val, indent + 1, true);
                    }
                } else {
                    debugPrintValue(val, indent + 1, true);
                }
            } else if (@typeInfo(T2) == .int) {
                styled(ansi.number, "{d}", .{val});
            } else if (@typeInfo(T2) == .float) {
                styled(ansi.number, "{d:.1}", .{val});
            } else {
                debugPrintValue(val, indent + 1, true);
            }
            for (visible_width..column_widths[column] + 1) |_| std.debug.print(" ", .{});
        }
        std.debug.print("\n", .{});
    }

    if (items.len > page_items) {
        std.debug.print("  ... ({} items total; use n/p or value[start..end])\n", .{items.len});
    }

    if (fields.len > max_struct_fields) {
        std.debug.print("  ... {} more fields (query with value[index].field)\n", .{fields.len - max_struct_fields});
    }

    styled(ansi.punctuation, "]", .{});
    std.debug.print("\n", .{});
}

fn valueDisplayWidth(value: anytype) usize {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int => std.fmt.count("{}", .{value}),
        .float => std.fmt.count("{d:.1}", .{value}),
        .bool => if (value) 4 else 5,
        .@"enum" => 1 + @tagName(value).len,
        .optional => if (value) |unwrapped| valueDisplayWidth(unwrapped) else 4,
        .pointer => |pointer| if (pointer.size == .slice)
            (if (pointer.child == u8) @min(value.len, 22) + 2 else 12)
        else
            16,
        .@"struct" => blk: {
            if (@hasField(T, "x") and @hasField(T, "y")) {
                const x = @field(value, "x");
                const y = @field(value, "y");
                if (@typeInfo(@TypeOf(x)) == .float and @typeInfo(@TypeOf(y)) == .float)
                    break :blk std.fmt.count("({d:.1}, {d:.1})", .{ x, y });
            }
            break :blk @min(shortTypeName(T).len + 7, 24);
        },
        else => 8,
    };
}

fn printString(value: []const u8) void {
    const shown = @min(value.len, max_string_bytes);
    styled(ansi.string, "\"{s}\"", .{value[0..shown]});
    if (shown < value.len) std.debug.print("... ({} bytes)", .{value.len});
}

const prompt_commands = [_][]const u8{ "vars", "continue", "reload", "step", "next" };

fn readCommand(
    reader: *std.Io.Reader,
    prompt: []const u8,
    locals: []const sidecar_abi.LocalRef,
    storage: []u8,
) ?[]const u8 {
    const io = runtime.io();
    if (!(std.Io.File.stdin().isTty(io) catch false)) {
        std.debug.print("{s}", .{prompt});
        const line = reader.takeDelimiter('\n') catch return null;
        return if (line) |bytes| std.mem.trim(u8, bytes, " \t\r\n") else null;
    }

    const fd = std.posix.STDIN_FILENO;
    const original = std.posix.tcgetattr(fd) catch return null;
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(fd, .NOW, raw) catch return null;
    defer std.posix.tcsetattr(fd, .NOW, original) catch {};

    std.debug.print("{s}", .{prompt});
    var len: usize = 0;
    var tab_base: [256]u8 = undefined;
    var tab_base_len: usize = 0;
    var tab_index: usize = 0;
    var cycling = false;

    while (true) {
        const byte = reader.takeByte() catch {
            std.debug.print("\n", .{});
            return null;
        };
        switch (byte) {
            '\r', '\n' => {
                std.debug.print("\n", .{});
                return std.mem.trim(u8, storage[0..len], " \t\r\n");
            },
            3 => {
                std.debug.print("^C\n", .{});
                return null;
            },
            8, 127 => {
                if (len > 0) {
                    len -= 1;
                    std.debug.print("\x08 \x08", .{});
                }
                cycling = false;
            },
            '\t' => {
                if (!cycling) {
                    tab_base_len = @min(len, tab_base.len);
                    @memcpy(tab_base[0..tab_base_len], storage[0..tab_base_len]);
                    tab_index = 0;
                    cycling = true;
                }
                if (completeCommand(tab_base[0..tab_base_len], tab_index, locals, storage)) |completed_len| {
                    len = completed_len;
                    tab_index += 1;
                    std.debug.print("\r\x1b[2K{s}{s}", .{ prompt, storage[0..len] });
                }
            },
            27 => { // Consume the rest of an arrow/function-key escape sequence.
                _ = reader.takeByte() catch 0;
                _ = reader.takeByte() catch 0;
                cycling = false;
            },
            else => {
                if (byte >= 32 and byte < 127 and len < storage.len) {
                    storage[len] = byte;
                    len += 1;
                    std.debug.print("{c}", .{byte});
                }
                cycling = false;
            },
        }
    }
}

/// Tab cycles local names, then commands. Member completion needs the type,
/// so it arrives with on-demand inspection.
fn completeCommand(base: []const u8, requested: usize, locals: []const sidecar_abi.LocalRef, output: []u8) ?usize {
    var count: usize = 0;
    for (locals) |ref| {
        if (std.mem.startsWith(u8, localName(ref), base)) count += 1;
    }
    for (prompt_commands) |name| {
        if (std.mem.startsWith(u8, name, base)) count += 1;
    }
    if (count == 0) return null;
    var target = requested % count;
    for (locals) |ref| {
        const name = localName(ref);
        if (!std.mem.startsWith(u8, name, base)) continue;
        if (target == 0) {
            if (name.len > output.len) return null;
            @memcpy(output[0..name.len], name);
            return name.len;
        }
        target -= 1;
    }
    for (prompt_commands) |name| {
        if (!std.mem.startsWith(u8, name, base)) continue;
        if (target == 0) {
            @memcpy(output[0..name.len], name);
            return name.len;
        }
        target -= 1;
    }
    return null;
}

fn expressionFromCommand(cmd: []const u8) []const u8 {
    if (std.mem.startsWith(u8, cmd, "print ")) return std.mem.trim(u8, cmd[6..], " \t");
    if (std.mem.startsWith(u8, cmd, "p ")) return std.mem.trim(u8, cmd[2..], " \t");
    return cmd;
}

fn canDereferencePointer(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer or info.pointer.size != .one) return false;
    return switch (@typeInfo(info.pointer.child)) {
        .@"opaque", .@"fn", .type, .comptime_float, .comptime_int, .null, .undefined => false,
        else => true,
    };
}

// Main breakpoint handler — non-generic: every hook passes the same slice type
pub fn handleBreakpoint(
    function_name: []const u8,
    file_path: []const u8,
    line_number: usize,
    locals: []const sidecar_abi.LocalRef,
) void {
    if (gen.remote()) |api| return api.handleBreakpoint(function_name, file_path, line_number, locals);
    // Time tracking using std.Io clock
    const io = runtime.io();
    const now = std.Io.Clock.awake.now(io);

    if (breakpoint_timestamp) |last| {
        const elapsed = last.durationTo(now);
        const elapsed_ms = @divTrunc(elapsed.nanoseconds, std.time.ns_per_ms);
        std.debug.print("\n[Time since last breakpoint: {}ms]\n", .{elapsed_ms});
    }
    breakpoint_timestamp = now;

    const is_build_context = std.mem.eql(u8, function_name, "build");

    std.debug.print("\n=== BREAKPOINT #{} in {s}() ===\n", .{ breakpoint_count + 1, function_name });
    if (beginSidecarHandoff(function_name, locals)) return;
    gen.onStop(file_path, function_name, line_number, locals);

    if (is_build_context) {
        std.debug.print("(Build.zig detected)\n", .{});
        std.debug.print("For interactive debugging, run: zig build <args> 2>&1 | cat\n", .{});
    }

    // Normal interactive mode
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, stdin_buf[0..]);
    const r = &stdin_reader.interface;
    var command_buf: [256]u8 = undefined;

    listLocals(locals);
    std.debug.print("Commands: vars, <local>, r reload sidecar, s step, c continue (Tab completes)\n\n", .{});

    while (true) {
        const cmd = readCommand(r, "> ", locals, &command_buf) orelse break;
        if (std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "continue")) {
            break;
        } else if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step")) {
            step_mode = true;
            addFunctionToStepStack(function_name);
            std.debug.print("Step mode enabled for {s}().\n", .{function_name});
            break;
        } else if (std.mem.eql(u8, cmd, "r") or std.mem.eql(u8, cmd, "reload")) {
            if (reloadSidecarHandoff(function_name, locals) == .continue_execution) break;
        } else if (std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "vars")) {
            listLocals(locals);
        } else if (!queryLocal(locals, cmd)) {
            std.debug.print("Unknown command or variable\n", .{});
        }
    }
}

// Step debugging handler (before line execution)
pub fn handleStepBefore(
    function_name: []const u8,
    file_path: []const u8,
    next_line: []const u8,
    line_number: usize,
    locals: []const sidecar_abi.LocalRef,
) void {
    if (gen.remote()) |api| return api.handleStepBefore(function_name, file_path, next_line, line_number, locals);
    autoTrimStepStack(function_name);
    if (!shouldStepInFunction(function_name)) return;
    gen.onStop(file_path, function_name, line_number, locals);

    std.debug.print("\n[{s}:{d}] about to execute: {s}\n", .{ function_name, line_number, next_line });
    std.debug.print("(s=step, c=continue, n=next, v=vars, or variable name)\n", .{});

    const io = runtime.io();
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, stdin_buf[0..]);
    const r = &stdin_reader.interface;
    var command_buf: [256]u8 = undefined;

    while (true) {
        const cmd = readCommand(r, "step> ", locals, &command_buf) orelse {
            step_mode = false;
            step_function_count = 0;
            return;
        };

        if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step") or cmd.len == 0) {
            break;
        } else if (std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "continue")) {
            step_mode = false;
            step_function_count = 0;
            break;
        } else if (std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "next")) {
            break;
        } else if (std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "vars")) {
            listLocals(locals);
        } else if (!queryLocal(locals, cmd)) {
            std.debug.print("Unknown command or variable\n", .{});
        }
    }
}

// Step debugging handler (after line execution)
pub fn handleStep(
    function_name: []const u8,
    executed_line: []const u8,
    line_number: usize,
    locals: []const sidecar_abi.LocalRef,
) void {
    if (!shouldStepInFunction(function_name)) return;

    std.debug.print("\n[{s}:{d}] executed: {s}\n", .{ function_name, line_number, executed_line });
    std.debug.print("(s=step, c=continue, n=next (skip calls), v=vars, or variable name)\n", .{});

    const io = runtime.io();
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, stdin_buf[0..]);
    const r = &stdin_reader.interface;
    var command_buf: [256]u8 = undefined;

    while (true) {
        const cmd = readCommand(r, "step> ", locals, &command_buf) orelse {
            step_mode = false;
            step_function_count = 0;
            return;
        };

        if (std.mem.eql(u8, cmd, "s") or std.mem.eql(u8, cmd, "step") or cmd.len == 0) {
            break;
        } else if (std.mem.eql(u8, cmd, "c") or std.mem.eql(u8, cmd, "continue")) {
            step_mode = false;
            step_function_count = 0;
            break;
        } else if (std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "next")) {
            break;
        } else if (std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "vars")) {
            listLocals(locals);
        } else if (!queryLocal(locals, cmd)) {
            std.debug.print("Unknown command or variable\n", .{});
        }
    }
}

// Watch expression support
pub fn addWatch(name: []const u8, check_fn: *const fn () bool) void {
    _ = name;
    _ = check_fn;
    std.debug.print("Watch expressions not yet implemented\n", .{});
}

pub fn checkWatches() void {
    for (watch_expressions) |watch| {
        if (watch.check_fn()) {
            std.debug.print("\n!!! WATCH HIT: {s} !!!\n", .{watch.name});
        }
    }
}

test "locals capture preserves pointers and normalizes comptime values" {
    const ptr: *anyopaque = @ptrFromInt(0x1000);
    try std.testing.expect(capture(ptr) == ptr);
    try std.testing.expectEqual(@as(i128, 42), capture(42));
    try std.testing.expectEqualStrings("i32", capture(i32));
    try std.testing.expectEqualStrings("ready", capture(.ready));
    const values = rebuild(.{ capture(ptr), capture(i32), capture(42) });
    try std.testing.expect(values[0] == ptr);
    try std.testing.expectEqualStrings("i32", values[1]);
    try std.testing.expectEqual(@as(i128, 42), values[2]);
}

test "locals capture references large values without copying them" {
    var value = [_]u8{7} ** 4096;
    const captured = captureRef(&value);
    try std.testing.expect(captured.ptr == &value);
    captured.ptr[0] = 9;
    try std.testing.expectEqual(@as(u8, 9), value[0]);
}

test "handoff copies are snapshots" {
    var value: u32 = 7;
    const copied = captureCopy(value);
    value = 9;
    try std.testing.expectEqual(@as(u32, 7), copied.value);
    try std.testing.expectEqual(@as(u32, 9), value);
}

test "localRef marks const locals read-only and decodes scalars from bytes" {
    var counter: u32 = 7;
    const limit: i16 = -3;
    const folded = 5; // comptime_int: no runtime bytes
    const a = localRef("counter", &counter);
    const b = localRef("limit", &limit);
    const c = localRef("folded", &folded);
    try std.testing.expectEqual(sidecar_abi.LocalStorage.mutable_pointer, a.storage);
    try std.testing.expectEqual(sidecar_abi.LocalStorage.read_only_pointer, b.storage);
    try std.testing.expectEqual(@as(usize, 0), c.bytes_len);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("7", formatScalar(&buf, "u32", a.bytes_ptr[0..a.bytes_len]).?);
    try std.testing.expectEqualStrings("-3", formatScalar(&buf, "i16", b.bytes_ptr[0..b.bytes_len]).?);
    counter = 9; // live pointer, not a snapshot
    try std.testing.expectEqualStrings("9", formatScalar(&buf, "u32", a.bytes_ptr[0..a.bytes_len]).?);
}

test "completion cycles local names, then commands" {
    const self_value: u32 = 1;
    const settings: u8 = 2;
    const state: u8 = 3;
    const locals = [_]sidecar_abi.LocalRef{
        localRef("self", &self_value),
        localRef("settings", &settings),
        localRef("state", &state),
    };
    var output: [64]u8 = undefined;

    const first = completeCommand("s", 0, &locals, &output).?;
    try std.testing.expectEqualStrings("self", output[0..first]);
    const second = completeCommand("s", 1, &locals, &output).?;
    try std.testing.expectEqualStrings("settings", output[0..second]);
    const fourth = completeCommand("s", 3, &locals, &output).?;
    try std.testing.expectEqualStrings("step", output[0..fourth]);
}
