const std = @import("std");
const runtime = @import("runtime.zig");

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
var output_buf: [16 * 1024]u8 = undefined;

// String storage for breakpoint file/condition strings
var string_buf: [16 * 1024]u8 = undefined;
var string_pos: usize = 0;

var initialized: bool = false;

// ============================================================================
// Public API — called from instrumented code
// ============================================================================

/// Fast check: should we break at this file:line?
/// Called at every instrumented statement. Must be fast.
pub fn shouldBreak(file_hash: u32, line: u32) bool {
    // Lazy init on first call
    if (!initialized) init();

    // Periodic poll for file changes
    pollForChanges();

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

/// Called when shouldBreak() returns true — handles the actual break
pub fn onBreak(
    function_name: []const u8,
    file_hash: u32,
    line: u32,
    var_names: []const []const u8,
    var_values: anytype,
) void {
    // Find the file path from our breakpoint list
    const bp_file = findBreakpointFile(file_hash, line) orelse "unknown";

    std.debug.print("[zdb] BREAK: {s}:{} in {s}()\n", .{ bp_file, line, function_name });

    // Write state file so nvim can display it
    writeStateFile(function_name, bp_file, line, var_names, var_values);

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
            if (std.mem.eql(u8, cmd, "continue") or std.mem.eql(u8, cmd, "c")) break;
            if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q")) std.process.exit(0);
            if (std.mem.eql(u8, cmd, "step") or std.mem.eql(u8, cmd, "s") or
                std.mem.eql(u8, cmd, "next") or std.mem.eql(u8, cmd, "n")) break;

            // "v" or "vars" — list all variables with values
            if (std.mem.eql(u8, cmd, "v") or std.mem.eql(u8, cmd, "vars")) {
                writeAllVars(var_names, var_values);
                deleteFile(config.command_file);
                continue;
            }

            // Strip "print " prefix if present
            const query = if (cmd.len > 6 and std.mem.eql(u8, cmd[0..6], "print "))
                cmd[6..]
            else
                cmd;

            // Try to match a variable name
            var matched = false;
            const fields = @typeInfo(@TypeOf(var_values)).@"struct".fields;
            inline for (fields, 0..) |_, i| {
                if (i < var_names.len) {
                    const name = var_names[i];
                    if (std.mem.eql(u8, query, name)) {
                        writeVarDetail(name, var_values[i]);
                        matched = true;
                    }
                }
            }

            if (!matched) {
                writeOutput("Unknown variable or command. Use 'v' to list variables.");
            }

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

    // Check for ZDB env vars
    // ZDB_MODE=dap|terminal|silent
    // ZDB_BREAKPOINTS=/path/to/file.zon
    // ZDB_PAUSE_ON_START=1

    // Try to load breakpoint file
    reloadBreakpoints();
}

// ============================================================================
// File watching
// ============================================================================

fn pollForChanges() void {
    // Throttle checks via call counter
    poll_counter +%= 1;
    if (poll_counter % POLL_EVERY_N != 0) return;

    // Stat the file — check mtime
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

    // Read file contents
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
//
// Parses a simple ZON format for breakpoints:
//
//   .{
//       .breakpoints = .{
//           .{ .file = "src/main.zig", .line = 106 },
//           .{ .file = "src/timeline.zig", .line = 42, .enabled = false },
//       },
//       .config = .{
//           .pause_on_start = true,
//       },
//   }
//
// Uses the Zig tokenizer for robust parsing — no regex, no hacks.
// ============================================================================

fn parseZonBreakpoints(content: []const u8) void {
    breakpoint_count = 0;
    string_pos = 0;

    // Null-terminate the content for the tokenizer
    if (content.len >= file_buf.len) return; // safety check
    file_buf[content.len] = 0;
    const source: [:0]const u8 = file_buf[0..content.len :0];

    var tokenizer = std.zig.Tokenizer.init(source);

    // State machine: look for .file = "..." and .line = N patterns
    const State = enum {
        searching, // looking for .file or .line
        after_dot_file, // saw .file, expect =
        after_file_eq, // saw .file =, expect string
        after_dot_line, // saw .line, expect =
        after_line_eq, // saw .line =, expect number
        after_dot_enabled, // saw .enabled, expect =
        after_enabled_eq, // saw .enabled =, expect bool
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
                    // Peek at next token
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
                // Detect end of a breakpoint entry (closing brace or comma)
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
                    // Strip quotes
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

// Buffer writing helpers (replaces fixedBufferStream which no longer exists)

fn appendSlice(buf: []u8, pos: usize, data: []const u8) usize {
    const end = pos + data.len;
    if (end > buf.len) return pos; // silent truncate
    @memcpy(buf[pos..end], data);
    return end;
}

fn appendInt(buf: []u8, pos: usize, val: u32) usize {
    // Format u32 into decimal digits
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
        // Reverse
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
    // Hash just the basename for cross-path matching
    // (comptime path is absolute, ZON path may be relative)
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
    // Primary: hash the basename of the breakpoint file path
    // This matches because compileFileHash also hashes the basename
    const basename = extractBasename(bp_file);
    if (@as(u32, @truncate(std.hash.Fnv1a_32.hash(basename))) == hash) return true;

    // Fallback: exact full-path hash
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

// ============================================================================
// File-based debug communication
//
// State file: program writes when stopped (nvim reads to show UI)
// Command file: nvim writes to tell program what to do (continue/step/quit)
// ============================================================================

fn writeStateFile(
    function_name: []const u8,
    bp_file: []const u8,
    line: u32,
    var_names: []const []const u8,
    var_values: anytype,
) void {
    // Build state text manually into state_buf
    var pos: usize = 0;

    pos = appendSlice(&state_buf, pos, "status=stopped\nfile=");
    pos = appendSlice(&state_buf, pos, bp_file);
    pos = appendSlice(&state_buf, pos, "\nline=");
    pos = appendInt(&state_buf, pos, line);
    pos = appendSlice(&state_buf, pos, "\nfunction=");
    pos = appendSlice(&state_buf, pos, function_name);
    pos = appendSlice(&state_buf, pos, "\n---\n");

    // Variables
    const fields = @typeInfo(@TypeOf(var_values)).@"struct".fields;
    inline for (fields, 0..) |_, i| {
        const name = if (i < var_names.len) var_names[i] else "?";
        pos = appendSlice(&state_buf, pos, "  ");
        pos = appendSlice(&state_buf, pos, name);
        pos = appendSlice(&state_buf, pos, ": ");
        pos = appendSlice(&state_buf, pos, @typeName(@TypeOf(var_values[i])));
        pos = appendSlice(&state_buf, pos, " = ");
        // Use formatValue which handles fn types, structs, etc.
        pos = formatValue(&state_buf, pos, var_values[i], 0);
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

fn writeVarDetail(name: []const u8, value: anytype) void {
    var pos: usize = 0;
    pos = appendSlice(&output_buf, pos, name);
    pos = appendSlice(&output_buf, pos, ": ");
    pos = appendSlice(&output_buf, pos, @typeName(@TypeOf(value)));
    pos = appendSlice(&output_buf, pos, "\n");
    pos = formatValue(&output_buf, pos, value, 0);
    writeFileToCwd(config.output_file, output_buf[0..pos]);
}

fn writeAllVars(var_names: []const []const u8, var_values: anytype) void {
    var pos: usize = 0;
    pos = appendSlice(&output_buf, pos, "=== Variables ===\n");
    const fields = @typeInfo(@TypeOf(var_values)).@"struct".fields;
    inline for (fields, 0..) |_, i| {
        const name = if (i < var_names.len) var_names[i] else "?";
        pos = appendSlice(&output_buf, pos, "  ");
        pos = appendSlice(&output_buf, pos, name);
        pos = appendSlice(&output_buf, pos, " = ");
        pos = formatValue(&output_buf, pos, var_values[i], 1);
        if (pos < output_buf.len) {
            output_buf[pos] = '\n';
            pos += 1;
        }
    }
    writeFileToCwd(config.output_file, output_buf[0..pos]);
}

// ============================================================================
// Value formatter — writes human-readable representation to buffer
// Handles structs, arrays, slices, enums, optionals, primitives.
// ============================================================================

fn formatValue(buf: []u8, start: usize, value: anytype, depth: usize) usize {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    var pos = start;

    if (depth > 4) {
        pos = appendSlice(buf, pos, "(...)");
        return pos;
    }

    switch (info) {
        .int => {
            // Use bufPrint for ints
            var tmp: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{}", .{value}) catch "?";
            pos = appendSlice(buf, pos, s);
        },
        .float => {
            var tmp: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d:.4}", .{value}) catch "?";
            pos = appendSlice(buf, pos, s);
        },
        .bool => {
            pos = appendSlice(buf, pos, if (value) "true" else "false");
        },
        .@"enum" => {
            pos = appendSlice(buf, pos, ".");
            pos = appendSlice(buf, pos, @tagName(value));
        },
        .optional => {
            if (value) |v| {
                pos = formatValue(buf, pos, v, depth);
            } else {
                pos = appendSlice(buf, pos, "null");
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                // String slice
                pos = appendSlice(buf, pos, "\"");
                const str = if (value.len > 200) value[0..200] else value;
                pos = appendSlice(buf, pos, str);
                if (value.len > 200) pos = appendSlice(buf, pos, "...");
                pos = appendSlice(buf, pos, "\"");
            } else if (ptr.size == .slice) {
                // Other slices — show elements
                pos = appendSlice(buf, pos, "[\n");
                const show = if (value.len > 20) @as(usize, 20) else value.len;
                for (value[0..show], 0..) |item, idx| {
                    pos = appendIndent(buf, pos, depth + 1);
                    pos = appendSlice(buf, pos, "[");
                    pos = appendInt(buf, pos, @intCast(idx));
                    pos = appendSlice(buf, pos, "] ");
                    pos = formatValue(buf, pos, item, depth + 1);
                    pos = appendSlice(buf, pos, "\n");
                }
                if (value.len > 20) {
                    pos = appendIndent(buf, pos, depth + 1);
                    pos = appendSlice(buf, pos, "... (");
                    pos = appendInt(buf, pos, @intCast(value.len));
                    pos = appendSlice(buf, pos, " items total)\n");
                }
                pos = appendIndent(buf, pos, depth);
                pos = appendSlice(buf, pos, "]");
            } else {
                // Other pointer — show address
                var tmp: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&tmp, "{*}", .{value}) catch "ptr";
                pos = appendSlice(buf, pos, s);
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                pos = appendSlice(buf, pos, "\"");
                const str: []const u8 = &value;
                const show = if (str.len > 200) str[0..200] else str;
                pos = appendSlice(buf, pos, show);
                if (str.len > 200) pos = appendSlice(buf, pos, "...");
                pos = appendSlice(buf, pos, "\"");
            } else {
                pos = appendSlice(buf, pos, "[\n");
                const items: []const arr.child = &value;
                const show = if (items.len > 20) @as(usize, 20) else items.len;
                for (items[0..show], 0..) |item, idx| {
                    pos = appendIndent(buf, pos, depth + 1);
                    pos = appendSlice(buf, pos, "[");
                    pos = appendInt(buf, pos, @intCast(idx));
                    pos = appendSlice(buf, pos, "] ");
                    pos = formatValue(buf, pos, item, depth + 1);
                    pos = appendSlice(buf, pos, "\n");
                }
                if (items.len > 20) {
                    pos = appendIndent(buf, pos, depth + 1);
                    pos = appendSlice(buf, pos, "... (");
                    pos = appendInt(buf, pos, @intCast(items.len));
                    pos = appendSlice(buf, pos, " items total)\n");
                }
                pos = appendIndent(buf, pos, depth);
                pos = appendSlice(buf, pos, "]");
            }
        },
        .@"struct" => |s| {
            if (s.fields.len == 0) {
                pos = appendSlice(buf, pos, "{}");
            } else {
                // Get short type name
                const type_name = @typeName(T);
                if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |dot| {
                    pos = appendSlice(buf, pos, type_name[dot + 1 ..]);
                }
                pos = appendSlice(buf, pos, "{\n");
                inline for (s.fields) |field| {
                    pos = appendIndent(buf, pos, depth + 1);
                    pos = appendSlice(buf, pos, ".");
                    pos = appendSlice(buf, pos, field.name);
                    pos = appendSlice(buf, pos, " = ");
                    pos = formatValue(buf, pos, @field(value, field.name), depth + 1);
                    pos = appendSlice(buf, pos, "\n");
                }
                pos = appendIndent(buf, pos, depth);
                pos = appendSlice(buf, pos, "}");
            }
        },
        .@"fn" => {
            pos = appendSlice(buf, pos, "<fn>");
        },
        else => {
            // Fallback
            var tmp: [128]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{any}", .{value}) catch "?";
            pos = appendSlice(buf, pos, s);
        },
    }
    return pos;
}

fn appendIndent(buf: []u8, pos: usize, depth: usize) usize {
    var p = pos;
    var i: usize = 0;
    while (i < depth * 2) : (i += 1) {
        p = appendSlice(buf, p, " ");
    }
    return p;
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

    // Trim whitespace/newlines
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
    // data slice must have >= 1 element (impl does data[0..data.len-1])
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
    var_names: []const []const u8,
    var_values: anytype,
) void {
    // DAP "stopped" event — implemented in dap.zig
    _ = function_name;
    _ = file_hash;
    _ = line;
    _ = var_names;
    _ = var_values;
    // TODO: call into dap module
}

fn logBreakpoint(function_name: []const u8, file_hash: u32, line: u32) void {
    std.debug.print("[zdb-silent] break in {s}() at hash={} line={}\n", .{
        function_name, file_hash, line,
    });
}

// ============================================================================
// Public helpers for generated code
// ============================================================================

/// Write the initial ZON file with no breakpoints (creates the file for editors)
pub fn ensureBreakpointFile() void {
    const io_local = runtime.runtime.io();
    const cwd = std.Io.Dir.cwd();

    // Only create if it doesn't exist
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

/// Get current breakpoint list (for DAP responses)
pub fn getBreakpoints() []const Breakpoint {
    return breakpoints[0..breakpoint_count];
}

/// Programmatic breakpoint add (from DAP setBreakpoints)
pub fn setBreakpointsForFile(file: []const u8, lines: []const u32) void {
    // Remove existing breakpoints for this file
    var write_idx: usize = 0;
    for (breakpoints[0..breakpoint_count]) |bp| {
        if (!std.mem.eql(u8, bp.file, file)) {
            breakpoints[write_idx] = bp;
            write_idx += 1;
        }
    }
    breakpoint_count = write_idx;

    // Add new ones
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

    // Write back to ZON file so other tools see it
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
