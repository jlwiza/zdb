const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

const Capture = struct {
    name: []const u8,
    type_source: []const u8,
    mutable: bool,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();
    const args = try init.args.toSlice(allocator);
    if (args.len != 3) {
        std.debug.print("usage: zdb-continuation-codegen input.zig output.zig\n", .{});
        return 2;
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], allocator, .limited(10 * 1024 * 1024));
    const source_z = try allocator.dupeZ(u8, source);
    var ast = try Ast.parse(allocator, source_z, .zig);
    defer ast.deinit(allocator);
    if (ast.errors.len != 0) return error.InvalidSource;

    const boundary = try findBoundary(&ast, source, allocator);
    var output: std.ArrayList(u8) = .empty;
    try emit(&output, allocator, boundary);
    if (std.fs.path.dirname(args[2])) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[2], .data = output.items });
    return 0;
}

const Boundary = struct {
    function_name: []const u8,
    line: usize,
    suffix: []const u8,
    captures: []const Capture,
};

fn findBoundary(ast: *const Ast, source: []const u8, allocator: std.mem.Allocator) !Boundary {
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) != .fn_decl) continue;
        const data = ast.nodeData(decl).node_and_node;
        var proto_buf: [1]Node.Index = undefined;
        const proto = ast.fullFnProto(&proto_buf, data[0]) orelse continue;
        const name_token = proto.name_token orelse continue;
        const function_name = ast.tokenSlice(name_token);
        const body = data[1];
        var stmts_buf: [2]Node.Index = undefined;
        const statements = ast.blockStatements(&stmts_buf, body) orelse continue;
        var captures: std.ArrayList(Capture) = .empty;
        var parameter_it = proto.iterate(ast);
        while (parameter_it.next()) |param| {
            const param_name_token = param.name_token orelse continue;
            const param_name = ast.tokenSlice(param_name_token);
            const parameter_type = param.type_expr orelse continue;
            try captures.append(allocator, .{
                .name = try allocator.dupe(u8, param_name),
                .type_source = try allocator.dupe(u8, nodeSource(ast, source, parameter_type)),
                .mutable = false,
            });
        }
        for (statements) |statement| {
            const statement_source = nodeSourceWithSemicolon(ast, source, statement);
            if (std.mem.eql(u8, std.mem.trim(u8, statement_source, " \t\r\n"), "_ = .breakpoint;")) {
                const marker_end = sourceOffsetAfterNode(ast, source, statement);
                const close_brace = ast.tokenStart(ast.lastToken(body));
                const suffix = source[marker_end..close_brace];
                if (containsControlTransfer(suffix)) {
                    std.debug.print("zdb: cannot split {s}(): post-marker return/break/continue is not supported yet\n", .{function_name});
                    return error.UnsupportedContinuationControlFlow;
                }
                var used: std.ArrayList(Capture) = .empty;
                for (captures.items) |capture| {
                    if (!containsIdentifier(suffix, capture.name)) continue;
                    if (!supportedType(capture.type_source)) return unsupportedCapture(function_name, capture);
                    try used.append(allocator, capture);
                }
                return .{
                    .function_name = try allocator.dupe(u8, function_name),
                    .line = lineNumber(source, ast.tokenStart(ast.firstToken(statement))),
                    .suffix = try allocator.dupe(u8, suffix),
                    .captures = try used.toOwnedSlice(allocator),
                };
            }
            if (ast.fullVarDecl(statement)) |variable| {
                const variable_name_token = variable.ast.mut_token + 1;
                if (ast.tokenTag(variable_name_token) != .identifier) continue;
                const maybe_type_node = variable.ast.type_node.unwrap();
                try captures.append(allocator, .{
                    .name = try allocator.dupe(u8, ast.tokenSlice(variable_name_token)),
                    .type_source = if (maybe_type_node) |type_node|
                        try allocator.dupe(u8, nodeSource(ast, source, type_node))
                    else
                        "<inferred>",
                    .mutable = ast.tokenTag(variable.ast.mut_token) == .keyword_var,
                });
            }
        }
    }
    std.debug.print("zdb: continuation split requires a marker directly inside a top-level function body\n", .{});
    return error.NoSupportedContinuationBoundary;
}

fn unsupportedCapture(function_name: []const u8, capture: Capture) error{UnsupportedCaptureType} {
    std.debug.print("zdb: cannot split {s}(): capture '{s}' has unsupported first-slice type '{s}'\n", .{ function_name, capture.name, capture.type_source });
    return error.UnsupportedCaptureType;
}

fn supportedType(raw: []const u8) bool {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    const types = [_][]const u8{ "bool", "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f80", "f128" };
    for (types) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn emit(output: *std.ArrayList(u8), allocator: std.mem.Allocator, boundary: Boundary) !void {
    try output.appendSlice(allocator,
        \\// AUTO-GENERATED ZDB POST-MARKER CONTINUATION
        \\const std = @import("std");
        \\const zdb = @import("zdb");
        \\const abi = zdb.sidecar_abi;
        \\const options = @import("zdb_sidecar_options");
        \\
        \\export fn zdb_sidecar_abi_version() callconv(.c) u32 { return abi.version; }
        \\export fn zdb_sidecar_on_pause(event: *const abi.PauseEvent, reply: *abi.PauseReply) callconv(.c) void {
        \\    const function_name = event.function_name_ptr[0..event.function_name_len];
        \\    var copied_value: ?u32 = null;
        \\    var mutated_from: ?u32 = null;
        \\    if (event.locals_ptr) |locals_ptr| for (locals_ptr[0..event.locals_len]) |item| {
        \\        const name = item.name_ptr[0..item.name_len];
        \\        const type_name = item.type_name_ptr[0..item.type_name_len];
        \\        if (item.bytes_len != @sizeOf(u32) or !std.mem.eql(u8, type_name, "u32")) continue;
        \\        const value: *u32 = @ptrCast(@alignCast(item.bytes_ptr));
        \\        if (item.storage == .copied_value and std.mem.eql(u8, name, options.read_u32_name)) copied_value = value.*;
        \\        if (item.storage == .mutable_pointer and std.mem.eql(u8, name, options.mutate_u32_name)) { mutated_from = value.*; value.* = options.mutate_u32_value; }
        \\    };
        \\    const message = std.fmt.bufPrint(&reply.message, "generation {d} handling {s} breakpoint #{d}; copied={?d}; mutable={?d}->{d}", .{ options.generation, function_name, event.breakpoint_count, copied_value, mutated_from, options.mutate_u32_value }) catch "continuation reply was too long";
        \\    reply.generation = options.generation;
        \\    reply.message_len = message.len;
        \\    reply.outcome = @enumFromInt(options.outcome);
        \\}
        \\
        \\fn local(event: *const abi.PauseEvent, name: []const u8, storage: abi.LocalStorage) ?abi.LocalRef {
        \\    const ptr = event.locals_ptr orelse return null;
        \\    for (ptr[0..event.locals_len]) |item| {
        \\        if (item.storage == storage and std.mem.eql(u8, item.name_ptr[0..item.name_len], name)) return item;
        \\    }
        \\    return null;
        \\}
        \\
    );
    try output.appendSlice(allocator, "export fn zdb_sidecar_continue(event: *const abi.PauseEvent) callconv(.c) abi.ContinuationOutcome {\n");
    for (boundary.captures) |capture| {
        const storage = if (capture.mutable) ".mutable_pointer" else ".copied_value";
        try output.print(allocator, "    const zdb_local_{s} = local(event, \"{s}\", {s}) orelse return .fail;\n", .{ capture.name, capture.name, storage });
        try output.print(allocator, "    if (zdb_local_{s}.bytes_len != @sizeOf({s})) return .fail;\n", .{ capture.name, capture.type_source });
        if (capture.mutable) {
            try output.print(allocator, "    const zdb_ptr_{s}: *{s} = @ptrCast(@alignCast(zdb_local_{s}.bytes_ptr));\n", .{ capture.name, capture.type_source, capture.name });
            try output.print(allocator, "    var {s}: {s} = zdb_ptr_{s}.*;\n", .{ capture.name, capture.type_source, capture.name });
            try output.print(allocator, "    _ = &{s};\n", .{capture.name});
            try output.print(allocator, "    defer zdb_ptr_{s}.* = {s};\n", .{ capture.name, capture.name });
        } else {
            try output.print(allocator, "    const zdb_ptr_{s}: *const {s} = @ptrCast(@alignCast(zdb_local_{s}.bytes_ptr));\n", .{ capture.name, capture.type_source, capture.name });
            try output.print(allocator, "    const {s}: {s} = zdb_ptr_{s}.*;\n", .{ capture.name, capture.type_source, capture.name });
        }
    }
    try output.appendSlice(allocator, boundary.suffix);
    try output.appendSlice(allocator, "\n    return .return_from_function;\n}\n");
}

fn nodeSource(ast: *const Ast, source: []const u8, node: Node.Index) []const u8 {
    const start = ast.tokenStart(ast.firstToken(node));
    const last = ast.lastToken(node);
    return source[start .. ast.tokenStart(last) + ast.tokenSlice(last).len];
}

fn nodeSourceWithSemicolon(ast: *const Ast, source: []const u8, node: Node.Index) []const u8 {
    const start = ast.tokenStart(ast.firstToken(node));
    return source[start..sourceOffsetAfterNode(ast, source, node)];
}

fn sourceOffsetAfterNode(ast: *const Ast, source: []const u8, node: Node.Index) usize {
    const last = ast.lastToken(node);
    var result = ast.tokenStart(last) + ast.tokenSlice(last).len;
    if (result < source.len and source[result] == ';') result += 1;
    return result;
}

fn lineNumber(source: []const u8, offset: usize) usize {
    var result: usize = 1;
    for (source[0..offset]) |byte| if (byte == '\n') {
        result += 1;
    };
    return result;
}

fn containsControlTransfer(source: []const u8) bool {
    return containsIdentifier(source, "return") or containsIdentifier(source, "break") or containsIdentifier(source, "continue");
}

fn containsIdentifier(source: []const u8, needle: []const u8) bool {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, needle)) |position| {
        const before_ok = position == 0 or !(std.ascii.isAlphanumeric(source[position - 1]) or source[position - 1] == '_');
        const end = position + needle.len;
        const after_ok = end == source.len or !(std.ascii.isAlphanumeric(source[end]) or source[end] == '_');
        if (before_ok and after_ok) return true;
        cursor = end;
    }
    return false;
}
