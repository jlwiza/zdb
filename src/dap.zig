const std = @import("std");
const live = @import("live.zig");

// ============================================================================
// Debug Adapter Protocol (DAP) Server
//
// DAP is the standard protocol for editor ↔ debugger communication.
// Used by nvim-dap, vscode, and other editors.
//
// Architecture:
//   [nvim-dap] ←→ stdin/stdout JSON-RPC ←→ [this server] ←→ [instrumented binary]
//
// This runs as a separate process that launches and manages the debuggee.
// The debuggee communicates via a simple line protocol on a pipe.
//
// DAP spec: https://microsoft.github.io/debug-adapter-protocol/
// ============================================================================

const MAX_MSG_SIZE = 256 * 1024; // 256K max DAP message

// ============================================================================
// DAP Message Types
// ============================================================================

const DapMessage = struct {
    seq: u32,
    type: []const u8, // "request", "response", "event"
    // Request fields
    command: ?[]const u8 = null,
    // Response fields
    request_seq: ?u32 = null,
    success: ?bool = null,
    body: ?[]const u8 = null, // raw JSON body
};

// ============================================================================
// Server State
// ============================================================================

var seq_counter: u32 = 1;
var debuggee_path: ?[]const u8 = null;
var debuggee_args: ?[]const []const u8 = null;
var is_running: bool = false;
var client_supports_invalidated: bool = false;

// Buffers
var read_buf: [MAX_MSG_SIZE]u8 = undefined;
var write_buf: [MAX_MSG_SIZE]u8 = undefined;

// ============================================================================
// Entry Point
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // DAP communicates over stdin/stdout with Content-Length headers
    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();

    while (true) {
        // Read DAP message (Content-Length: N\r\n\r\n{json})
        const msg_bytes = readDapMessage(stdin, &read_buf) catch |err| {
            switch (err) {
                error.EndOfStream => return, // Editor disconnected
                else => {
                    std.debug.print("[zdb-dap] Read error: {}\n", .{err});
                    return;
                },
            }
        };

        // Parse and handle
        handleMessage(allocator, msg_bytes, stdout) catch |err| {
            std.debug.print("[zdb-dap] Handle error: {}\n", .{err});
        };
    }
}

// ============================================================================
// DAP Message I/O
// ============================================================================

fn readDapMessage(reader: anytype, buf: []u8) ![]const u8 {
    // Read headers until empty line
    var content_length: ?usize = null;
    var header_buf: [1024]u8 = undefined;

    while (true) {
        // Read a line
        var line_len: usize = 0;
        while (line_len < header_buf.len) {
            const byte = try reader.readByte();
            if (byte == '\n') break;
            header_buf[line_len] = byte;
            line_len += 1;
        }

        const line = std.mem.trimRight(u8, header_buf[0..line_len], "\r");
        if (line.len == 0) break; // Empty line = end of headers

        // Parse Content-Length
        if (std.mem.startsWith(u8, line, "Content-Length: ")) {
            content_length = try std.fmt.parseInt(usize, line["Content-Length: ".len..], 10);
        }
    }

    const len = content_length orelse return error.MissingContentLength;
    if (len > buf.len) return error.MessageTooLarge;

    // Read exact body
    var read: usize = 0;
    while (read < len) {
        const n = try reader.read(buf[read..len]);
        if (n == 0) return error.EndOfStream;
        read += n;
    }

    return buf[0..len];
}

fn sendDapMessage(writer: anytype, json: []const u8) !void {
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{json.len}) catch return;
    try writer.writeAll(header);
    try writer.writeAll(json);
}

// ============================================================================
// Message Handling
// ============================================================================

fn handleMessage(allocator: std.mem.Allocator, msg_bytes: []const u8, writer: anytype) !void {
    // Parse JSON to find "command" field
    const command = extractJsonString(msg_bytes, "command") orelse return;
    const request_seq = extractJsonNumber(msg_bytes, "seq") orelse 0;

    if (std.mem.eql(u8, command, "initialize")) {
        try handleInitialize(allocator, request_seq, writer);
    } else if (std.mem.eql(u8, command, "launch")) {
        try handleLaunch(allocator, request_seq, msg_bytes, writer);
    } else if (std.mem.eql(u8, command, "setBreakpoints")) {
        try handleSetBreakpoints(allocator, request_seq, msg_bytes, writer);
    } else if (std.mem.eql(u8, command, "continue")) {
        try handleContinue(allocator, request_seq, writer);
    } else if (std.mem.eql(u8, command, "threads")) {
        try handleThreads(allocator, request_seq, writer);
    } else if (std.mem.eql(u8, command, "stackTrace")) {
        try handleStackTrace(allocator, request_seq, writer);
    } else if (std.mem.eql(u8, command, "scopes")) {
        try handleScopes(allocator, request_seq, writer);
    } else if (std.mem.eql(u8, command, "variables")) {
        try handleVariables(allocator, request_seq, writer);
    } else if (std.mem.eql(u8, command, "disconnect")) {
        try sendResponse(allocator, request_seq, command, true, "{}", writer);
        std.process.exit(0);
    } else if (std.mem.eql(u8, command, "configurationDone")) {
        try sendResponse(allocator, request_seq, command, true, "{}", writer);
    } else {
        // Unknown command — send success response anyway
        try sendResponse(allocator, request_seq, command, true, "{}", writer);
    }
}

// ============================================================================
// DAP Request Handlers
// ============================================================================

fn handleInitialize(allocator: std.mem.Allocator, request_seq: u32, writer: anytype) !void {
    const body =
        \\{
        \\  "supportsConfigurationDoneRequest": true,
        \\  "supportsFunctionBreakpoints": false,
        \\  "supportsConditionalBreakpoints": false,
        \\  "supportsEvaluateForHovers": true,
        \\  "supportsSetVariable": false,
        \\  "supportsStepBack": false,
        \\  "supportsRestartRequest": false,
        \\  "supportsModulesRequest": false
        \\}
    ;
    try sendResponse(allocator, request_seq, "initialize", true, body, writer);

    // Send "initialized" event
    try sendEvent(allocator, "initialized", "{}", writer);
}

fn handleLaunch(allocator: std.mem.Allocator, request_seq: u32, msg: []const u8, writer: anytype) !void {
    // Extract "program" from launch arguments
    const program = extractJsonString(msg, "program") orelse {
        try sendResponse(allocator, request_seq, "launch", false, "{\"error\": {\"id\": 1, \"format\": \"No program specified\"}}", writer);
        return;
    };
    _ = program;

    // Create the breakpoint file for the debuggee
    live.ensureBreakpointFile();

    // TODO: Actually launch the program as a subprocess
    // For now, acknowledge the launch
    is_running = true;
    try sendResponse(allocator, request_seq, "launch", true, "{}", writer);
}

fn handleSetBreakpoints(allocator: std.mem.Allocator, request_seq: u32, msg: []const u8, writer: anytype) !void {
    // Extract source file path
    const source_path = extractJsonString(msg, "path") orelse "unknown";

    // Extract line numbers from "breakpoints" array
    var lines: [64]u32 = undefined;
    var line_count: usize = 0;

    // Simple extraction: find all "line": N patterns after "breakpoints"
    if (std.mem.indexOf(u8, msg, "\"breakpoints\"")) |bp_start| {
        var pos = bp_start;
        while (pos < msg.len and line_count < 64) {
            if (std.mem.indexOf(u8, msg[pos..], "\"line\"")) |line_off| {
                const after = pos + line_off + 6; // skip "line"
                // Skip whitespace and colon
                var p = after;
                while (p < msg.len and (msg[p] == ' ' or msg[p] == ':')) p += 1;
                // Parse number
                var end = p;
                while (end < msg.len and msg[end] >= '0' and msg[end] <= '9') end += 1;
                if (end > p) {
                    if (std.fmt.parseInt(u32, msg[p..end], 10) catch null) |line| {
                        lines[line_count] = line;
                        line_count += 1;
                    }
                }
                pos = end;
            } else break;
        }
    }

    // Update live breakpoints (writes ZON file too)
    live.setBreakpointsForFile(source_path, lines[0..line_count]);

    // Build response with verified breakpoints
    var resp_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&resp_buf);
    const w = fbs.writer();

    w.writeAll("{\"breakpoints\": [") catch {};
    for (0..line_count) |i| {
        if (i > 0) w.writeAll(",") catch {};
        w.print("{{\"id\": {}, \"verified\": true, \"line\": {}}}", .{ i + 1, lines[i] }) catch {};
    }
    w.writeAll("]}") catch {};

    try sendResponse(allocator, request_seq, "setBreakpoints", true, fbs.getWritten(), writer);
}

fn handleContinue(allocator: std.mem.Allocator, request_seq: u32, writer: anytype) !void {
    try sendResponse(allocator, request_seq, "continue", true, "{\"allThreadsContinued\": true}", writer);
}

fn handleThreads(allocator: std.mem.Allocator, request_seq: u32, writer: anytype) !void {
    try sendResponse(allocator, request_seq, "threads", true,
        \\{"threads": [{"id": 1, "name": "main"}]}
    , writer);
}

fn handleStackTrace(allocator: std.mem.Allocator, request_seq: u32, writer: anytype) !void {
    // TODO: get actual stack from debuggee
    try sendResponse(allocator, request_seq, "stackTrace", true,
        \\{"stackFrames": [{"id": 1, "name": "main", "line": 1, "column": 1, "source": {"name": "main.zig", "path": "src/main.zig"}}], "totalFrames": 1}
    , writer);
}

fn handleScopes(allocator: std.mem.Allocator, request_seq: u32, writer: anytype) !void {
    try sendResponse(allocator, request_seq, "scopes", true,
        \\{"scopes": [{"name": "Locals", "variablesReference": 1, "expensive": false}, {"name": "Globals", "variablesReference": 2, "expensive": false}]}
    , writer);
}

fn handleVariables(allocator: std.mem.Allocator, request_seq: u32, writer: anytype) !void {
    // TODO: get actual variables from debuggee
    try sendResponse(allocator, request_seq, "variables", true,
        \\{"variables": []}
    , writer);
}

// ============================================================================
// DAP Response/Event Builders
// ============================================================================

fn sendResponse(allocator: std.mem.Allocator, request_seq: u32, command: []const u8, success: bool, body: []const u8, writer: anytype) !void {
    _ = allocator;
    var buf: [MAX_MSG_SIZE]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    const my_seq = seq_counter;
    seq_counter += 1;

    w.print(
        \\{{"seq": {}, "type": "response", "request_seq": {}, "success": {}, "command": "{s}", "body": {s}}}
    , .{ my_seq, request_seq, success, command, body }) catch return;

    try sendDapMessage(writer, fbs.getWritten());
}

fn sendEvent(allocator: std.mem.Allocator, event: []const u8, body: []const u8, writer: anytype) !void {
    _ = allocator;
    var buf: [MAX_MSG_SIZE]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    const my_seq = seq_counter;
    seq_counter += 1;

    w.print(
        \\{{"seq": {}, "type": "event", "event": "{s}", "body": {s}}}
    , .{ my_seq, event, body }) catch return;

    try sendDapMessage(writer, fbs.getWritten());
}

/// Send a "stopped" event when a breakpoint is hit
pub fn sendStoppedEvent(writer: anytype, reason: []const u8, thread_id: u32) !void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    w.print("{{\"reason\": \"{s}\", \"threadId\": {}, \"allThreadsStopped\": true}}", .{
        reason, thread_id,
    }) catch return;

    try sendEvent(undefined, "stopped", fbs.getWritten(), writer);
}

// ============================================================================
// Minimal JSON helpers (no dependency on std.json)
// ============================================================================

fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Find "key": "value"
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = key_pos + search.len;

    // Skip whitespace and colon
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) pos += 1;

    // Expect opening quote
    if (pos >= json.len or json[pos] != '"') return null;
    pos += 1;

    // Find closing quote (handle escapes)
    const start = pos;
    while (pos < json.len) {
        if (json[pos] == '\\') {
            pos += 2;
            continue;
        }
        if (json[pos] == '"') return json[start..pos];
        pos += 1;
    }
    return null;
}

fn extractJsonNumber(json: []const u8, key: []const u8) ?u32 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = key_pos + search.len;

    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) pos += 1;

    var end = pos;
    while (end < json.len and json[end] >= '0' and json[end] <= '9') end += 1;
    if (end == pos) return null;

    return std.fmt.parseInt(u32, json[pos..end], 10) catch null;
}
