const std = @import("std");
const runtime = @import("runtime.zig");
const sidecar_abi = @import("sidecar_abi.zig");
const gen = @import("gen.zig");

// ============================================================================
// Live Breakpoint System
//
// Watches a ZON file for breakpoint changes while the program runs.
// The instrumented program checks `shouldBreak()` at every statement.
// An editor (vim, BL_Editor, etc.) writes breakpoints to the ZON file.
//
// Flow:
//   [editor] → writes → zdb_breakpoints.zon ← polls ← [instrumented program]
//
// The ZON file is the single source of truth. Edit it by hand,
// from a vim plugin, from BL_Editor's gutter, whatever.
// ============================================================================

const MAX_BREAKPOINTS = 256;

pub const Breakpoint = struct {
    file: []const u8,
    line: u32,
    enabled: bool = true,
    hit_count: u32 = 0,
    condition: ?[]const u8 = null, // future: conditional breakpoints
};

pub const OutputMode = enum {
    terminal, // current behavior — stderr + stdin REPL
    dap, // Debug Adapter Protocol (JSON-RPC over stdio)
    silent, // log to file, no interactive
};

pub const Config = struct {
    pause_on_start: bool = false,
    output_mode: OutputMode = .terminal,
    breakpoint_file: []const u8 = "zdb_breakpoints.zon",
    state_file: []const u8 = "zdb_state.txt",
    command_file: []const u8 = "zdb_command.txt",
    output_file: []const u8 = "zdb_output.txt",
    log_file: ?[]const u8 = null,
};

// ============================================================================
// Global state
// ============================================================================

var breakpoints: [MAX_BREAKPOINTS]Breakpoint = undefined;
var breakpoint_count: usize = 0;
var config: Config = .{};

// File watching state
var last_mtime: std.Io.Timestamp = .{ .nanoseconds = 0 };
var poll_counter: u32 = 0;
const POLL_EVERY_N: u32 = 50_000; // check file every ~50K statements
var file_buf: [64 * 1024]u8 = undefined; // 64K should be plenty for breakpoint file

// State file buffer (separate from file_buf to avoid conflicts)
var state_buf: [8 * 1024]u8 = undefined;
var cmd_buf: [256]u8 = undefined;

// Output buffer for variable inspection responses
var output_buf: [32 * 1024]u8 = undefined;

// String storage for breakpoint file/condition strings
var string_buf: [16 * 1024]u8 = undefined;
var string_pos: usize = 0;

var initialized: bool = false;

// Step mode state
var step_mode: enum { none, step_in, step_over, step_out } = .none;
var step_frame: usize = 0; // frame of the stop that started next/out; stacks grow down, so larger = shallower
var break_frame: usize = 0; // frame of the most recent stop
var last_known_file: []const u8 = "unknown";

// ============================================================================
// Public API — called from instrumented code
// ============================================================================

/// CALLED BY: gen's host redirect — a step-in into a cold function builds it and waits.
pub fn stepInPending() bool {
    return step_mode == .step_in;
}

/// Fast check: should we break at this file:line?
/// Called at every instrumented statement. Must be fast.
pub fn shouldBreak(file_hash: u32, line: u32) bool {
    const frame = @frameAddress(); // same depth relation in host and generation: called straight from the hook
    if (gen.remote()) |api| return api.shouldBreak(file_hash, line, frame); // generated code: the host owns breakpoints and stepping
    return breakAt(file_hash, line, frame);
}

/// CALLED BY: shouldBreak here, or through HostApi from generated code.
pub fn breakAt(file_hash: u32, line: u32, frame: usize) bool {
    if (checkBreak(file_hash, line, frame)) {
        break_frame = frame;
        return true;
    }
    return false;
}

fn checkBreak(file_hash: u32, line: u32, frame: usize) bool {
    // Lazy init on first call
    if (!initialized) init();

    // Periodic poll for file changes
    pollForChanges();

    // Step mode: break on next statement
    if (step_mode == .step_in) {
        return true;
    }
    if (step_mode == .step_over and frame >= step_frame) return true; // same function, or its caller after return
    if (step_mode == .step_out and frame > step_frame) return true; // strictly shallower: we've returned

    // Fast path: no breakpoints set
    if (breakpoint_count == 0) return false;

    // Linear scan — with <256 breakpoints this is ~microseconds
    for (breakpoints[0..breakpoint_count]) |*bp| {
        if (bp.line == line and bp.enabled) {
            if (fileHashMatches(bp.file, file_hash)) {
                bp.hit_count += 1;
                return true;
            }
        }
    }
    return false;
}

/// Called when shouldBreak() returns true — handles the actual break.
/// Non-generic: every hook in every file passes the same slice type.
pub fn onBreak(
    function_name: []const u8,
    file_path: []const u8,
    file_hash: u32,
    line: u32,
    locals: []const sidecar_abi.LocalRef,
) void {
    if (gen.remote()) |api| return api.onBreak(function_name, file_path, file_hash, line, locals);
    if (runtime.beginSidecarHandoff(function_name, locals)) return;
    // Use the file path passed directly from instrumented code
    const bp_file = file_path;
    last_known_file = bp_file;

    // Clear step mode — we've landed, user will choose next action
    step_mode = .none;

    std.debug.print("[zdb] BREAK: {s}:{} in {s}()\n", .{ bp_file, line, function_name });
    gen.onStop(file_path, function_name, line, locals); // may recenter the ring and queue inspectors in the background

    // Write state file so nvim can display it
    writeStateFile(function_name, bp_file, line, locals);

    // Clear old output and command
    deleteFile(config.command_file);
    deleteFile(config.output_file);

    // Poll for command file — program is paused here
    var spin: u32 = 0;
    while (true) {
        spin +%= 1;
        if (spin % 100_000 != 0) continue;

        if (readCommandFile()) |cmd| {
            // Flow control
            if (std.mem.eql(u8, cmd, "continue") or std.mem.eql(u8, cmd, "c")) {
                step_mode = .none;
                break;
            }
            if (std.mem.eql(u8, cmd, "reload") or std.mem.eql(u8, cmd, "r")) {
                if (runtime.reloadSidecarHandoff(function_name, locals) == .continue_execution) {
                    step_mode = .none;
                    break;
                }
                continue;
            }
            if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) std.process.exit(0);

            // Step in: break on very next statement (any file/function)
            if (std.mem.eql(u8, cmd, "step") or std.mem.eql(u8, cmd, "s")) {
                step_mode = .step_in;
                break;
            }

            // Step over: next statement at this depth or shallower (calls run through)
            if (std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "n")) {
                step_mode = .step_over;
                step_frame = break_frame;
                break;
            }

            // Step out: first statement after this function returns
            if (std.mem.eql(u8, cmd, "out") or std.mem.eql(u8, cmd, "o")) {
                step_mode = .step_out;
                step_frame = break_frame;
                break;
            }

            // "v" or "vars" — list all variables with values
            if (std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "vars")) {
                writeAllVars(locals);
                deleteFile(config.command_file);
                continue;
            }

            // Strip "print " prefix if present
            const query = if (cmd.len > 6 and std.mem.eql(u8, cmd[0..6], "print "))
                cmd[6..]
            else
                cmd;

            writeLocalQuery(locals, query);
            deleteFile(config.command_file);
        }
    }

    // Clean up — program is running again
    deleteFile(config.command_file);
    deleteFile(config.output_file);
    writeRunningState();
}

// ============================================================================
// Initialization
// ============================================================================

fn init() void {
    initialized = true;
    string_pos = 0;

    // Try to load breakpoint file
    reloadBreakpoints();

    // Clear stale state from previous run
    writeRunningState();
}

// ============================================================================
// File watching
// ============================================================================

fn pollForChanges() void {
    poll_counter +%= 1;
    if (poll_counter % POLL_EVERY_N != 0) return;

    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io_local, config.breakpoint_file, .{}) catch return;
    const mtime = stat.mtime;

    if (mtime.nanoseconds != last_mtime.nanoseconds) {
        last_mtime = mtime;
        reloadBreakpoints();
    }
}

fn reloadBreakpoints() void {
    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();

    const file = cwd.openFile(io_local, config.breakpoint_file, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {},
            else => std.debug.print("[zdb] Error opening {s}: {}\n", .{ config.breakpoint_file, err }),
        }
        breakpoint_count = 0;
        return;
    };
    defer io_local.vtable.fileClose(io_local.userdata, &.{file});

    var bytes_read: usize = 0;
    while (bytes_read < file_buf.len) {
        const n = io_local.vtable.fileReadPositional(io_local.userdata, file, &.{file_buf[bytes_read..]}, bytes_read) catch break;
        if (n == 0) break;
        bytes_read += n;
    }

    const content = file_buf[0..bytes_read];
    parseZonBreakpoints(content);
}

// ============================================================================
// ZON Parser
// ============================================================================

fn parseZonBreakpoints(content: []const u8) void {
    breakpoint_count = 0;
    string_pos = 0;

    if (content.len >= file_buf.len) return;
    file_buf[content.len] = 0;
    const source: [:0]const u8 = file_buf[0..content.len :0];

    var tokenizer = std.zig.Tokenizer.init(source);

    const State = enum {
        searching,
        after_dot_file,
        after_file_eq,
        after_dot_line,
        after_line_eq,
        after_dot_enabled,
        after_enabled_eq,
    };

    var state: State = .searching;
    var current_file: ?[]const u8 = null;
    var current_line: ?u32 = null;
    var current_enabled: bool = true;

    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;

        switch (state) {
            .searching => {
                if (tok.tag == .period) {
                    const next = tokenizer.next();
                    if (next.tag == .identifier) {
                        const name = source[next.loc.start..next.loc.end];
                        if (std.mem.eql(u8, name, "file")) {
                            state = .after_dot_file;
                        } else if (std.mem.eql(u8, name, "line")) {
                            state = .after_dot_line;
                        } else if (std.mem.eql(u8, name, "enabled")) {
                            state = .after_dot_enabled;
                        }
                    }
                }
                if (tok.tag == .r_brace or tok.tag == .comma) {
                    if (current_file != null and current_line != null) {
                        if (breakpoint_count < MAX_BREAKPOINTS) {
                            breakpoints[breakpoint_count] = .{
                                .file = current_file.?,
                                .line = current_line.?,
                                .enabled = current_enabled,
                            };
                            breakpoint_count += 1;
                        }
                        current_file = null;
                        current_line = null;
                        current_enabled = true;
                    }
                }
            },
            .after_dot_file => {
                if (tok.tag == .equal) {
                    state = .after_file_eq;
                } else {
                    state = .searching;
                }
            },
            .after_file_eq => {
                if (tok.tag == .string_literal) {
                    const raw = source[tok.loc.start..tok.loc.end];
                    if (raw.len >= 2) {
                        const str = raw[1 .. raw.len - 1];
                        current_file = dupeString(str);
                    }
                }
                state = .searching;
            },
            .after_dot_line => {
                if (tok.tag == .equal) {
                    state = .after_line_eq;
                } else {
                    state = .searching;
                }
            },
            .after_line_eq => {
                if (tok.tag == .number_literal) {
                    const num_str = source[tok.loc.start..tok.loc.end];
                    current_line = std.fmt.parseInt(u32, num_str, 10) catch null;
                }
                state = .searching;
            },
            .after_dot_enabled => {
                if (tok.tag == .equal) {
                    state = .after_enabled_eq;
                } else {
                    state = .searching;
                }
            },
            .after_enabled_eq => {
                if (tok.tag == .identifier) {
                    const text = source[tok.loc.start..tok.loc.end];
                    if (std.mem.eql(u8, text, "true")) {
                        current_enabled = true;
                    } else if (std.mem.eql(u8, text, "false")) {
                        current_enabled = false;
                    }
                }
                state = .searching;
            },
        }
    }

    // Flush last entry
    if (current_file != null and current_line != null) {
        if (breakpoint_count < MAX_BREAKPOINTS) {
            breakpoints[breakpoint_count] = .{
                .file = current_file.?,
                .line = current_line.?,
                .enabled = current_enabled,
            };
            breakpoint_count += 1;
        }
    }

    if (breakpoint_count > 0) {
        std.debug.print("[zdb] Loaded {} breakpoint(s) from {s}\n", .{ breakpoint_count, config.breakpoint_file });
    }
}

// ============================================================================
// String storage (avoid allocation in hot path)
// ============================================================================

fn dupeString(s: []const u8) ?[]const u8 {
    if (string_pos + s.len > string_buf.len) return null;
    const start = string_pos;
    @memcpy(string_buf[start .. start + s.len], s);
    string_pos += s.len;
    return string_buf[start .. start + s.len];
}

fn appendSlice(buf: []u8, pos: usize, data: []const u8) usize {
    const end = pos + data.len;
    if (end > buf.len) return pos;
    @memcpy(buf[pos..end], data);
    return end;
}

fn appendInt(buf: []u8, pos: usize, val: u32) usize {
    var tmp: [10]u8 = undefined;
    var n = val;
    var len: usize = 0;
    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (n > 0) : (len += 1) {
            tmp[len] = @intCast('0' + (n % 10));
            n /= 10;
        }
        var i: usize = 0;
        while (i < len / 2) : (i += 1) {
            const t = tmp[i];
            tmp[i] = tmp[len - 1 - i];
            tmp[len - 1 - i] = t;
        }
    }
    return appendSlice(buf, pos, tmp[0..len]);
}

// ============================================================================
// File hash — comptime FNV-1a of filename for fast comparison
// ============================================================================

pub fn compileFileHash(comptime filename: []const u8) u32 {
    @setEvalBranchQuota(100_000);
    const basename = comptime blk: {
        var i = filename.len;
        while (i > 0) {
            i -= 1;
            if (filename[i] == '/' or filename[i] == '\\') break :blk filename[i + 1 ..];
        }
        break :blk filename;
    };
    return @truncate(std.hash.Fnv1a_32.hash(basename));
}

fn extractBasename(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') return path[i + 1 ..];
    }
    return path;
}

fn fileHashMatches(bp_file: []const u8, hash: u32) bool {
    const basename = extractBasename(bp_file);
    if (@as(u32, @truncate(std.hash.Fnv1a_32.hash(basename))) == hash) return true;
    if (@as(u32, @truncate(std.hash.Fnv1a_32.hash(bp_file))) == hash) return true;
    return false;
}

fn findBreakpointFile(file_hash: u32, line: u32) ?[]const u8 {
    for (breakpoints[0..breakpoint_count]) |bp| {
        if (bp.line == line and fileHashMatches(bp.file, file_hash)) {
            return bp.file;
        }
    }
    return null;
}

fn findFileByHash(file_hash: u32) ?[]const u8 {
    for (breakpoints[0..breakpoint_count]) |bp| {
        if (fileHashMatches(bp.file, file_hash)) {
            return bp.file;
        }
    }
    return null;
}

// ============================================================================
// Locals — type-erased; scalars decode from bytes, everything else waits
// for on-demand inspection
// ============================================================================

/// "name: type = value" — value is a decoded scalar, or a size/address summary.
fn appendLocal(buf: []u8, start: usize, ref: sidecar_abi.LocalRef) usize {
    const type_name = ref.type_name_ptr[0..ref.type_name_len];
    var pos = appendSlice(buf, start, ref.name_ptr[0..ref.name_len]);
    pos = appendSlice(buf, pos, ": ");
    pos = appendSlice(buf, pos, type_name);
    pos = appendSlice(buf, pos, " = ");
    if (ref.bytes_len == 0) return appendSlice(buf, pos, "<no runtime bytes>");
    var scalar_buf: [64]u8 = undefined;
    if (runtime.formatScalar(&scalar_buf, type_name, ref.bytes_ptr[0..ref.bytes_len])) |text| {
        return appendSlice(buf, pos, text);
    }
    var summary_buf: [64]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "<{d} bytes @ 0x{x}>", .{ ref.bytes_len, @intFromPtr(ref.bytes_ptr) }) catch "<bytes>";
    return appendSlice(buf, pos, summary);
}

/// Scalar local → its line from bytes. Struct, or a path on any local → a
/// printer compiled on demand for exactly that type and path (cached after).
fn writeLocalQuery(locals: []const sidecar_abi.LocalRef, query: []const u8) void {
    for (locals) |ref| {
        const name = ref.name_ptr[0..ref.name_len];
        if (!std.mem.startsWith(u8, query, name)) continue;
        const rest = query[name.len..];
        if (rest.len > 0 and rest[0] != '.' and rest[0] != '[') continue; // a longer name, not a path
        if (rest.len == 0) {
            var scratch: [96]u8 = undefined;
            const type_name = ref.type_name_ptr[0..ref.type_name_len];
            const indirect = type_name.len > 0 and (type_name[0] == '*' or type_name[0] == '['); // an address isn't the answer; its target is
            if (ref.bytes_len == 0 or (!indirect and runtime.formatScalar(&scratch, type_name, ref.bytes_ptr[0..ref.bytes_len]) != null)) {
                const pos = appendLocal(&output_buf, 0, ref);
                writeFileToCwd(config.output_file, output_buf[0..pos]);
                return;
            }
        }
        var pos = appendSlice(&output_buf, 0, query);
        pos = appendSlice(&output_buf, pos, " = ");
        const text = gen.inspect(ref, rest, output_buf[pos..]);
        if (text.ptr != output_buf[pos..].ptr) pos = appendSlice(&output_buf, pos, text) else pos += text.len; // messages aren't in the buffer
        writeFileToCwd(config.output_file, output_buf[0..pos]);
        return;
    }
    writeOutput("Unknown variable or command. Use 'v' to list variables.");
}

// ============================================================================
// File-based debug communication
// ============================================================================

fn writeStateFile(
    function_name: []const u8,
    bp_file: []const u8,
    line: u32,
    locals: []const sidecar_abi.LocalRef,
) void {
    var pos: usize = 0;

    pos = appendSlice(&state_buf, pos, "status=stopped\nfile=");
    pos = appendSlice(&state_buf, pos, bp_file);
    pos = appendSlice(&state_buf, pos, "\nline=");
    pos = appendInt(&state_buf, pos, line);
    pos = appendSlice(&state_buf, pos, "\nfunction=");
    pos = appendSlice(&state_buf, pos, function_name);
    pos = appendSlice(&state_buf, pos, "\n---\n");

    for (locals) |ref| {
        pos = appendSlice(&state_buf, pos, "  ");
        pos = appendLocal(&state_buf, pos, ref);
        pos = appendSlice(&state_buf, pos, "\n");
    }

    writeFileToCwd(config.state_file, state_buf[0..pos]);
}

fn writeRunningState() void {
    writeFileToCwd(config.state_file, "status=running\n");
}

fn writeOutput(msg: []const u8) void {
    writeFileToCwd(config.output_file, msg);
}

fn writeAllVars(locals: []const sidecar_abi.LocalRef) void {
    var pos: usize = 0;
    pos = appendSlice(&output_buf, pos, "=== Variables ===\n");
    for (locals) |ref| {
        pos = appendSlice(&output_buf, pos, "  ");
        pos = appendLocal(&output_buf, pos, ref);
        pos = appendSlice(&output_buf, pos, "\n");
    }
    writeFileToCwd(config.output_file, output_buf[0..pos]);
}

fn readCommandFile() ?[]const u8 {
    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();

    const file = cwd.openFile(io_local, config.command_file, .{}) catch return null;
    defer io_local.vtable.fileClose(io_local.userdata, &.{file});

    var bytes_read: usize = 0;
    while (bytes_read < cmd_buf.len) {
        const n = io_local.vtable.fileReadPositional(
            io_local.userdata,
            file,
            &.{cmd_buf[bytes_read..]},
            bytes_read,
        ) catch break;
        if (n == 0) break;
        bytes_read += n;
    }

    if (bytes_read == 0) return null;

    var end = bytes_read;
    while (end > 0 and (cmd_buf[end - 1] == '\n' or cmd_buf[end - 1] == '\r' or cmd_buf[end - 1] == ' ')) {
        end -= 1;
    }
    if (end == 0) return null;
    return cmd_buf[0..end];
}

fn deleteFile(path: []const u8) void {
    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io_local, path) catch {};
}

fn writeFileToCwd(path: []const u8, content: []const u8) void {
    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io_local, path, .{}) catch return;
    defer io_local.vtable.fileClose(io_local.userdata, &.{file});
    const iov = [1][]const u8{content};
    _ = io_local.vtable.fileWritePositional(io_local.userdata, file, &.{}, &iov, 1, 0) catch {};
}

// ============================================================================
// Output adapters
// ============================================================================

fn dapSendStopped(
    function_name: []const u8,
    file_hash: u32,
    line: u32,
    locals: []const sidecar_abi.LocalRef,
) void {
    _ = function_name;
    _ = file_hash;
    _ = line;
    _ = locals;
}

fn logBreakpoint(function_name: []const u8, file_hash: u32, line: u32) void {
    std.debug.print("[zdb-silent] break in {s}() at hash={} line={}\n", .{
        function_name, file_hash, line,
    });
}

// ============================================================================
// Public helpers for generated code
// ============================================================================

pub fn ensureBreakpointFile() void {
    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();

    cwd.access(io_local, config.breakpoint_file, .{}) catch {
        const file = cwd.createFile(io_local, config.breakpoint_file, .{}) catch return;
        defer io_local.vtable.fileClose(io_local.userdata, &.{file});
        const template =
            \\.{
            \\    // zdb live breakpoints
            \\    // Edit this file while your program runs.
            \\    // Breakpoints take effect within ~50ms.
            \\    //
            \\    // Format:
            \\    //   .{ .file = "src/main.zig", .line = 106 },
            \\    //   .{ .file = "src/main.zig", .line = 200, .enabled = false },
            \\    .breakpoints = .{
            \\    },
            \\}
            \\
        ;
        const iov = [1][]const u8{template};
        _ = io_local.vtable.fileWritePositional(io_local.userdata, file, &.{}, &iov, 1, 0) catch {};
        return;
    };
}

pub fn getBreakpoints() []const Breakpoint {
    return breakpoints[0..breakpoint_count];
}

pub fn setBreakpointsForFile(file: []const u8, lines: []const u32) void {
    var write_idx: usize = 0;
    for (breakpoints[0..breakpoint_count]) |bp| {
        if (!std.mem.eql(u8, bp.file, file)) {
            breakpoints[write_idx] = bp;
            write_idx += 1;
        }
    }
    breakpoint_count = write_idx;

    for (lines) |line| {
        if (breakpoint_count < MAX_BREAKPOINTS) {
            breakpoints[breakpoint_count] = .{
                .file = dupeString(file) orelse file,
                .line = line,
                .enabled = true,
            };
            breakpoint_count += 1;
        }
    }

    writeBreakpointFile();
}

fn writeBreakpointFile() void {
    var buf: [32 * 1024]u8 = undefined;
    var pos: usize = 0;

    pos = appendSlice(&buf, pos, ".{\n    .breakpoints = .{\n");
    for (breakpoints[0..breakpoint_count]) |bp| {
        pos = appendSlice(&buf, pos, "        .{ .file = \"");
        pos = appendSlice(&buf, pos, bp.file);
        pos = appendSlice(&buf, pos, "\", .line = ");
        pos = appendInt(&buf, pos, bp.line);
        pos = appendSlice(&buf, pos, " },\n");
    }
    pos = appendSlice(&buf, pos, "    },\n}\n");

    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();
    const file = cwd.createFile(io_local, config.breakpoint_file, .{}) catch return;
    defer io_local.vtable.fileClose(io_local.userdata, &.{file});
    const iov = [1][]const u8{buf[0..pos]};
    _ = io_local.vtable.fileWritePositional(io_local.userdata, file, &.{}, &iov, 1, 0) catch {};
}
