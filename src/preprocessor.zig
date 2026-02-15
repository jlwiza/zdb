const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

// ============================================================================
// Types
// ============================================================================

const Edit = struct {
    offset: usize,
    delete_len: usize,
    insert: []const u8,
};

const VarType = enum { regular, thread_local, comptime_const, pub_var, pub_const };

const GlobalVar = struct {
    name: []const u8,
    var_type: VarType,
};

const ScopeVar = struct {
    name: []const u8,
};

const WalkContext = struct {
    ast: *const Ast,
    source: []const u8,
    edits: *std.ArrayList(Edit),
    globals: *std.ArrayList(GlobalVar),
    vars: *std.ArrayList(ScopeVar),
    allocator: std.mem.Allocator,
    fn_name: []const u8,
    enable_step: bool,
    needs_debug: bool,
    // Track discard deletions per function — only commit if we actually inject code
    pending_discards: std.ArrayList(Edit) = .empty,
    injected_in_fn: bool = false,
};

// ============================================================================
// Entry point
// ============================================================================

pub fn main(init: std.process.Init.Minimal) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: std.Io.Threaded = .init(allocator, .{
        .environ = init.environ,
        .argv0 = .init(init.args),
    });
    defer threaded.deinit();
    const io = threaded.ioBasic();
    const args = try init.args.toSlice(allocator);

    if (args.len < 3) {
        std.debug.print("Usage: preprocessor input.zig output.zig [--step] [--runtime-path <path>]\n", .{});
        return 2;
    }

    const input_file = args[1];
    const output_file = args[2];
    var enable_step = false;
    var runtime_path: ?[]const u8 = null;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--step")) {
            enable_step = true;
        } else if (std.mem.eql(u8, args[i], "--runtime-path") and i + 1 < args.len) {
            runtime_path = args[i + 1];
            i += 1;
        }
    }

    // Ensure output directory exists
    if (std.fs.path.dirname(output_file)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(io, input_file, allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(source);

    const is_build_file = std.mem.endsWith(u8, input_file, "build.zig");

    const has_breakpoints = std.mem.indexOf(u8, source, "_ = .breakpoint;") != null;
    const has_step = std.mem.indexOf(u8, source, "step_debug()") != null;
    const needs_debug = has_breakpoints or has_step or enable_step;

    if (!needs_debug) {
        if (is_build_file) {
            var output_buf: std.ArrayList(u8) = .empty;
            defer output_buf.deinit(allocator);
            try rewriteBuildFile(source, &output_buf, allocator);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = output_buf.items });
        } else {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = source });
        }
        std.debug.print("Preprocessed {s} -> {s} (no debug needed)\n", .{ input_file, output_file });
        return 0;
    }

    // Parse AST
    const source_z = try allocator.dupeZ(u8, source);
    var ast = try Ast.parse(allocator, source_z, .zig);
    defer ast.deinit(allocator);

    if (ast.errors.len > 0) {
        // Parse errors — pass through unchanged
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = source });
        std.debug.print("Preprocessed {s} -> {s} (parse errors, passed through)\n", .{ input_file, output_file });
        return 0;
    }

    // ---- Collect edits ----
    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);

    var globals: std.ArrayList(GlobalVar) = .empty;
    defer globals.deinit(allocator);

    var vars: std.ArrayList(ScopeVar) = .empty;
    defer vars.deinit(allocator);

    // Phase 1: Scan globals
    scanGlobals(&ast, source, &globals, allocator);

    // Phase 2: Add header
    try addHeader(source, &edits, allocator, runtime_path, is_build_file);

    // Phase 3: Walk functions
    var ctx = WalkContext{
        .ast = &ast,
        .source = source,
        .edits = &edits,
        .globals = &globals,
        .vars = &vars,
        .allocator = allocator,
        .fn_name = "",
        .enable_step = enable_step or has_step,
        .needs_debug = needs_debug,
    };

    try walkTopLevel(&ctx);

    // Phase 4: Apply edits
    var output_buf: std.ArrayList(u8) = .empty;
    defer output_buf.deinit(allocator);
    try applyEdits(source, edits.items, &output_buf, allocator);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = output_buf.items });
    std.debug.print("Preprocessed {s} -> {s} ({} edits, {} globals)\n", .{ input_file, output_file, edits.items.len, globals.items.len });
    return 0;
}

// ============================================================================
// AST Walking
// ============================================================================

fn walkTopLevel(ctx: *WalkContext) WalkError!void {
    for (ctx.ast.rootDecls()) |decl_idx| {
        try walkDecl(ctx, decl_idx);
    }
}

/// Process a declaration: fn → walk body, container → recurse members, var → check init
fn walkDecl(ctx: *WalkContext, node: Node.Index) WalkError!void {
    const tag = ctx.ast.nodeTag(node);

    switch (tag) {
        .fn_decl => try walkFunction(ctx, node),

        // Container types — recurse to find nested functions
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => {
            var buf: [2]Node.Index = undefined;
            if (ctx.ast.fullContainerDecl(&buf, node)) |full| {
                for (full.ast.members) |member| {
                    try walkDecl(ctx, member);
                }
            }
        },

        // Variable decls whose init might be a container
        .simple_var_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        => {
            if (ctx.ast.fullVarDecl(node)) |decl| {
                if (decl.ast.init_node.unwrap()) |init_node| {
                    try walkDecl(ctx, init_node);
                }
            }
        },

        else => {},
    }
}

/// Walk a function: extract name, walk body block
fn walkFunction(ctx: *WalkContext, fn_node: Node.Index) WalkError!void {
    // fn_decl data is node_and_node: [0]=proto, [1]=body
    const data = ctx.ast.nodeData(fn_node).node_and_node;
    const proto_node = data[0];
    const body_node = data[1];

    // Get function name
    var proto_buf: [1]Node.Index = undefined;
    const fn_name = if (ctx.ast.fullFnProto(&proto_buf, proto_node)) |proto|
        if (proto.name_token) |nt| ctx.ast.tokenSlice(nt) else "unknown"
    else
        "unknown";

    const saved_fn = ctx.fn_name;
    const saved_vars_len = ctx.vars.items.len;
    ctx.fn_name = fn_name;

    // Track pending discards and injection flag for this function
    const saved_injected = ctx.injected_in_fn;
    const discards_before = ctx.pending_discards.items.len;
    ctx.injected_in_fn = false;

    // Add function parameters as scope variables
    if (ctx.ast.fullFnProto(&proto_buf, proto_node)) |proto| {
        var it = proto.iterate(ctx.ast);
        while (it.next()) |param| {
            if (param.name_token) |name_tok| {
                try ctx.vars.append(ctx.allocator, .{
                    .name = try ctx.allocator.dupe(u8, ctx.ast.tokenSlice(name_tok)),
                });
            }
        }
    }

    try walkBlock(ctx, body_node);

    // If instrumentation was injected in THIS function, commit the discard deletions
    if (ctx.injected_in_fn) {
        for (ctx.pending_discards.items[discards_before..]) |discard_edit| {
            try ctx.edits.append(ctx.allocator, discard_edit);
        }
    }
    // Either way, clear pending discards for this function
    ctx.pending_discards.shrinkRetainingCapacity(discards_before);

    ctx.injected_in_fn = saved_injected;
    ctx.fn_name = saved_fn;
    ctx.vars.shrinkRetainingCapacity(saved_vars_len);
}

const WalkError = error{OutOfMemory};

/// Walk a block's statements
fn walkBlock(ctx: *WalkContext, block_node: Node.Index) WalkError!void {
    const scope_save = ctx.vars.items.len;

    var stmts_buf: [2]Node.Index = undefined;
    const stmts = ctx.ast.blockStatements(&stmts_buf, block_node) orelse return;

    for (stmts) |stmt| {
        const tag = ctx.ast.nodeTag(stmt);
        const main_tok = ctx.ast.nodeMainToken(stmt);
        const stmt_start: usize = ctx.ast.tokenStart(main_tok);

        const line_text = getLineAt(ctx.source, stmt_start);
        const trimmed = std.mem.trim(u8, line_text, " \t\r");
        const line_number = getLineNumber(ctx.source, stmt_start);

        // ---- Breakpoint: `_ = .breakpoint;` ----
        if (isBreakpoint(trimmed)) {
            const ls = lineStartOffset(ctx.source, stmt_start);
            const le = lineEndOffset(ctx.source, stmt_start);
            const indent = getIndent(ctx.source, stmt_start);
            try ctx.edits.append(ctx.allocator, .{
                .offset = ls,
                .delete_len = le - ls,
                .insert = try genBreakpoint(ctx, indent),
            });
            ctx.injected_in_fn = true;
            continue;
        }

        // ---- step_debug() marker ----
        if (std.mem.indexOf(u8, trimmed, "step_debug();") != null) {
            continue;
        }

        // ---- Discard of tracked variable: queue for deletion ----
        // Only actually deleted if instrumentation is injected in this function
        if (isTrackedDiscard(trimmed, ctx.vars.items, ctx.globals.items)) {
            const ls = lineStartOffset(ctx.source, stmt_start);
            const le = lineEndOffset(ctx.source, stmt_start);
            try ctx.pending_discards.append(ctx.allocator, .{
                .offset = ls,
                .delete_len = le - ls,
                .insert = "",
            });
        }

        // ---- Inject step debug ----
        if (ctx.needs_debug and ctx.enable_step and isInjectableStatement(tag)) {
            const insert_at = lineStartOffset(ctx.source, stmt_start);
            const indent = getIndent(ctx.source, stmt_start);
            try ctx.edits.append(ctx.allocator, .{
                .offset = insert_at,
                .delete_len = 0,
                .insert = try genStepDebug(ctx, trimmed, line_number, indent),
            });
            ctx.injected_in_fn = true;
        }

        // ---- Track variable declarations ----
        if (isVarDecl(tag)) {
            if (getVarDeclName(ctx.ast, stmt)) |name| {
                if (!isImportDecl(ctx.ast, ctx.source, stmt)) {
                    try ctx.vars.append(ctx.allocator, .{
                        .name = try ctx.allocator.dupe(u8, name),
                    });
                }
            }
        }

        // ---- Recurse into sub-blocks ----
        try walkSubBlocks(ctx, stmt);
    }

    ctx.vars.shrinkRetainingCapacity(scope_save);
}

/// Recursively find and walk blocks nested inside a node
fn walkSubBlocks(ctx: *WalkContext, node: Node.Index) WalkError!void {
    const tag = ctx.ast.nodeTag(node);

    // If this node IS a block, walk it directly
    if (isBlockLike(tag)) {
        try walkBlock(ctx, node);
        return;
    }

    switch (tag) {
        // If/else
        .@"if", .if_simple => {
            if (ctx.ast.fullIf(node)) |full| {
                try walkBlockOrRecurse(ctx, full.ast.then_expr);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    try walkBlockOrRecurse(ctx, else_expr);
                }
            }
        },

        // While loops
        .@"while", .while_simple, .while_cont => {
            if (ctx.ast.fullWhile(node)) |full| {
                try walkBlockOrRecurse(ctx, full.ast.then_expr);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    try walkBlockOrRecurse(ctx, else_expr);
                }
            }
        },

        // For loops
        .@"for", .for_simple => {
            if (ctx.ast.fullFor(node)) |full| {
                try walkBlockOrRecurse(ctx, full.ast.then_expr);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    try walkBlockOrRecurse(ctx, else_expr);
                }
            }
        },

        // Switch — walk each case body
        .@"switch", .switch_comma => {
            if (ctx.ast.fullSwitch(node)) |full| {
                for (full.ast.cases) |case_node| {
                    if (ctx.ast.fullSwitchCase(case_node)) |case| {
                        try walkBlockOrRecurse(ctx, case.ast.target_expr);
                    }
                }
            }
        },

        // Catch/orelse — RHS might be a block
        .@"catch" => {
            const rhs = ctx.ast.nodeData(node).node_and_node[1];
            try walkBlockOrRecurse(ctx, rhs);
        },
        .@"orelse" => {
            const rhs = ctx.ast.nodeData(node).node_and_node[1];
            try walkBlockOrRecurse(ctx, rhs);
        },

        // fn_decl inside expressions (nested functions)
        .fn_decl => try walkFunction(ctx, node),

        // Generic: try to walk children based on data type
        else => {
            // For nodes with two child nodes, try walking both
            walkChildNodes(ctx, node) catch {};
        },
    }
}

/// Walk a node as a block if it is one, otherwise recurse for nested blocks
fn walkBlockOrRecurse(ctx: *WalkContext, node: Node.Index) WalkError!void {
    if (isBlockLike(ctx.ast.nodeTag(node))) {
        try walkBlock(ctx, node);
    } else {
        try walkSubBlocks(ctx, node);
    }
}

/// Try to walk child nodes generically (best-effort)
fn walkChildNodes(ctx: *WalkContext, node: Node.Index) WalkError!void {
    const tag = ctx.ast.nodeTag(node);
    const data = ctx.ast.nodeData(node);

    // Try common data shapes that have child nodes
    switch (tag) {
        // Nodes with node_and_node data
        .@"catch",
        .equal_equal,
        .bang_equal,
        .assign,
        .assign_add,
        .assign_sub,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_shl,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_xor,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .@"orelse",
        .bool_and,
        .bool_or,
        .array_access,
        .slice_open,
        .error_union,
        .array_type,
        .switch_range,
        .if_simple,
        .while_simple,
        .for_simple,
        .fn_decl,
        .array_init_one,
        .array_init_one_comma,
        => {
            const children = data.node_and_node;
            try walkSubBlocks(ctx, children[0]);
            try walkSubBlocks(ctx, children[1]);
        },

        // Nodes with a single child
        .@"return" => {
            if (data.opt_node.unwrap()) |child| {
                try walkSubBlocks(ctx, child);
            }
        },
        .@"try",
        .@"defer",
        .@"comptime",
        .@"nosuspend",
        .bool_not,
        .negation,
        .bit_not,
        .address_of,
        .deref,
        .@"suspend",
        .@"resume",
        => {
            try walkSubBlocks(ctx, data.node);
        },

        else => {},
    }
}

// ============================================================================
// Globals scanning
// ============================================================================

fn scanGlobals(ast: *const Ast, source: []const u8, globals: *std.ArrayList(GlobalVar), allocator: std.mem.Allocator) void {
    for (ast.rootDecls()) |decl_node| {
        const tag = ast.nodeTag(decl_node);
        if (!isVarDecl(tag)) continue;

        const name = getVarDeclName(ast, decl_node) orelse continue;
        if (isImportDecl(ast, source, decl_node)) continue;
        if (isTypeAlias(ast, decl_node)) continue;

        const main_tok = ast.nodeMainToken(decl_node);
        const line = getLineAt(source, ast.tokenStart(main_tok));
        const trimmed = std.mem.trim(u8, line, " \t\r");

        var var_type: VarType = .regular;
        if (std.mem.startsWith(u8, trimmed, "threadlocal ")) {
            var_type = .thread_local;
        } else if (std.mem.startsWith(u8, trimmed, "pub var ")) {
            var_type = .pub_var;
        } else if (std.mem.startsWith(u8, trimmed, "pub const ")) {
            var_type = .pub_const;
        } else if (std.mem.startsWith(u8, trimmed, "const ")) {
            const is_comptime = std.mem.indexOf(u8, trimmed, "comptime") != null;
            var_type = if (is_comptime) .comptime_const else .regular;
        }

        globals.append(allocator, .{
            .name = allocator.dupe(u8, name) catch continue,
            .var_type = var_type,
        }) catch {};
    }
}

// ============================================================================
// Header injection
// ============================================================================

fn addHeader(source: []const u8, edits: *std.ArrayList(Edit), allocator: std.mem.Allocator, runtime_path: ?[]const u8, is_build_file: bool) !void {
    var insert_offset: usize = 0;

    // Skip BOM
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        insert_offset = 3;
    }

    // Skip module doc comments (//!) and blank lines at top
    var pos: usize = insert_offset;
    while (pos < source.len) {
        while (pos < source.len and (source[pos] == ' ' or source[pos] == '\t' or source[pos] == '\r')) pos += 1;
        if (pos < source.len and source[pos] == '\n') {
            pos += 1;
            insert_offset = pos;
            continue;
        }
        if (pos + 3 <= source.len and std.mem.eql(u8, source[pos .. pos + 3], "//!")) {
            while (pos < source.len and source[pos] != '\n') pos += 1;
            if (pos < source.len) pos += 1;
            insert_offset = pos;
        } else {
            break;
        }
    }

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(allocator);

    try header.appendSlice(allocator, "// AUTO-GENERATED - DO NOT EDIT\n");

    if (std.mem.indexOf(u8, source, "@import(\"std\")") == null) {
        try header.appendSlice(allocator, "const std = @import(\"std\");\n");
    }

    if (std.mem.indexOf(u8, source, "@import(\"zdb\")") == null) {
        if (runtime_path) |path| {
            try header.print(allocator, "const zdb = @import(\"{s}\");\n", .{path});
        } else if (is_build_file) {
            try header.appendSlice(allocator, "const zdb = @import(\"zdb\"); // SPECIAL:BUILD_FILE\n");
        } else {
            try header.appendSlice(allocator, "const zdb = @import(\"zdb\");\n");
        }
    }

    try header.appendSlice(allocator, "\n");

    try edits.append(allocator, .{
        .offset = insert_offset,
        .delete_len = 0,
        .insert = try allocator.dupe(u8, header.items),
    });
}

// ============================================================================
// Code generation
// ============================================================================

fn genBreakpoint(ctx: *WalkContext, indent: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "if (!@inComptime()) {\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    const var_names = [_][]const u8{");
    try appendVarNames(&buf, ctx);
    try buf.appendSlice(ctx.allocator, "};\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    const var_values = .{");
    try appendVarValues(&buf, ctx);
    try buf.appendSlice(ctx.allocator, "};\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.print(ctx.allocator, "    zdb.handleBreakpoint(\"{s}\", &var_names, var_values);\n", .{ctx.fn_name});
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "}\n");
    return buf.toOwnedSlice(ctx.allocator);
}

fn genStepDebug(ctx: *WalkContext, line_text: []const u8, line_number: usize, indent: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "if (!@inComptime()) {\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    const var_names = [_][]const u8{");
    try appendVarNames(&buf, ctx);
    try buf.appendSlice(ctx.allocator, "};\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    const var_values = .{");
    try appendVarValues(&buf, ctx);
    try buf.appendSlice(ctx.allocator, "};\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    zdb.handleStepBefore(\"");
    try buf.appendSlice(ctx.allocator, ctx.fn_name);
    try buf.appendSlice(ctx.allocator, "\", \"");
    try appendEscaped(&buf, ctx.allocator, line_text);
    try buf.print(ctx.allocator, "\", {}, &var_names, var_values);\n", .{line_number});
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "}\n");
    return buf.toOwnedSlice(ctx.allocator);
}

fn appendVarNames(buf: *std.ArrayList(u8), ctx: *WalkContext) !void {
    var first = true;
    for (ctx.vars.items) |v| {
        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        try buf.print(ctx.allocator, "\"{s}\"", .{v.name});
        first = false;
    }
    for (ctx.globals.items) |g| {
        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        try buf.print(ctx.allocator, "\"{s}\"", .{g.name});
        first = false;
    }
}

fn appendVarValues(buf: *std.ArrayList(u8), ctx: *WalkContext) !void {
    var first = true;
    for (ctx.vars.items) |v| {
        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, v.name);
        first = false;
    }
    for (ctx.globals.items) |g| {
        if (!first) try buf.appendSlice(ctx.allocator, ", ");
        try buf.appendSlice(ctx.allocator, g.name);
        first = false;
    }
}

fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

// ============================================================================
// Edit application
// ============================================================================

fn applyEdits(source: []const u8, edits_slice: []const Edit, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    // Sort edits by offset ascending
    const sorted = try allocator.dupe(Edit, edits_slice);
    std.mem.sort(Edit, sorted, {}, struct {
        fn f(_: void, a: Edit, b: Edit) bool {
            return a.offset < b.offset;
        }
    }.f);

    // Build output by walking through source and applying edits
    var src_pos: usize = 0;
    for (sorted) |edit| {
        if (edit.offset > src_pos) {
            try output.appendSlice(allocator, source[src_pos..edit.offset]);
        }
        if (edit.insert.len > 0) {
            try output.appendSlice(allocator, edit.insert);
        }
        src_pos = edit.offset + edit.delete_len;
    }
    if (src_pos < source.len) {
        try output.appendSlice(allocator, source[src_pos..]);
    }
}

// ============================================================================
// AST helpers
// ============================================================================

fn getVarDeclName(ast: *const Ast, node: Node.Index) ?[]const u8 {
    if (ast.fullVarDecl(node)) |decl| {
        // mut_token is the `const`/`var` keyword. Name is the next token.
        const name_tok = decl.ast.mut_token + 1;
        if (name_tok < ast.tokens.len) {
            const name = ast.tokenSlice(name_tok);
            if (name.len > 0 and (std.ascii.isAlphabetic(name[0]) or name[0] == '_')) {
                return name;
            }
        }
    }
    return null;
}

// ============================================================================
// Classification helpers
// ============================================================================

fn isVarDecl(tag: Node.Tag) bool {
    return tag == .simple_var_decl or tag == .local_var_decl or
        tag == .global_var_decl or tag == .aligned_var_decl;
}

fn isBlockLike(tag: Node.Tag) bool {
    return tag == .block or tag == .block_semicolon or
        tag == .block_two or tag == .block_two_semicolon;
}

fn isInjectableStatement(tag: Node.Tag) bool {
    return switch (tag) {
        .simple_var_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        .assign,
        .assign_destructure,
        .assign_add,
        .assign_sub,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_shl,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_or,
        .assign_bit_xor,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign_shl_sat,
        .call,
        .call_comma,
        .call_one,
        .call_one_comma,
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        .@"return",
        .@"if",
        .if_simple,
        .@"while",
        .while_simple,
        .while_cont,
        .@"for",
        .for_simple,
        .@"switch",
        .switch_comma,
        .@"break",
        .@"continue",
        .field_access,
        .@"try",
        .@"defer",
        .@"errdefer",
        .unwrap_optional,
        .deref,
        .array_access,
        .@"catch",
        .@"orelse",
        .grouped_expression,
        .@"suspend",
        .@"resume",
        => true,
        else => false,
    };
}

fn isBreakpoint(trimmed: []const u8) bool {
    return std.mem.eql(u8, trimmed, "_ = .breakpoint;");
}

fn isTrackedDiscard(trimmed: []const u8, vars: []const ScopeVar, globals: []const GlobalVar) bool {
    if (!std.mem.startsWith(u8, trimmed, "_ = ")) return false;
    const rest = trimmed[4..];
    const semi = std.mem.indexOf(u8, rest, ";") orelse return false;
    const name = std.mem.trim(u8, rest[0..semi], " ");
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    for (vars) |v| {
        if (std.mem.eql(u8, v.name, name)) return true;
    }
    for (globals) |g| {
        if (std.mem.eql(u8, g.name, name)) return true;
    }
    return false;
}

fn isImportDecl(ast: *const Ast, source: []const u8, node: Node.Index) bool {
    if (ast.fullVarDecl(node)) |decl| {
        if (decl.ast.init_node.unwrap()) |init_node| {
            const init_tag = ast.nodeTag(init_node);
            if (init_tag == .builtin_call_two or init_tag == .builtin_call_two_comma or
                init_tag == .builtin_call or init_tag == .builtin_call_comma)
            {
                const init_main = ast.nodeMainToken(init_node);
                const name = ast.tokenSlice(init_main);
                if (std.mem.eql(u8, name, "@import")) return true;
            }
        }
    }
    // Fallback
    const main_tok = ast.nodeMainToken(node);
    const line = getLineAt(source, ast.tokenStart(main_tok));
    return std.mem.indexOf(u8, line, "@import(") != null;
}

fn isTypeAlias(ast: *const Ast, node: Node.Index) bool {
    if (ast.fullVarDecl(node)) |decl| {
        if (decl.ast.init_node.unwrap()) |init_node| {
            const init_tag = ast.nodeTag(init_node);
            if (init_tag == .field_access) return true;
            // Container decl = inline struct/enum/union definition
            switch (init_tag) {
                .container_decl,
                .container_decl_two,
                .container_decl_trailing,
                .container_decl_two_trailing,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .tagged_union,
                .tagged_union_two,
                .tagged_union_trailing,
                .tagged_union_two_trailing,
                .tagged_union_enum_tag,
                .tagged_union_enum_tag_trailing,
                => return true,
                else => {},
            }
        }
    }
    return false;
}

// ============================================================================
// Source position utilities
// ============================================================================

fn lineStartOffset(source: []const u8, offset: usize) usize {
    var pos = offset;
    while (pos > 0 and source[pos - 1] != '\n') pos -= 1;
    return pos;
}

fn lineEndOffset(source: []const u8, offset: usize) usize {
    var pos = offset;
    while (pos < source.len and source[pos] != '\n') pos += 1;
    if (pos < source.len) pos += 1;
    return pos;
}

fn getLineAt(source: []const u8, offset: usize) []const u8 {
    const start = lineStartOffset(source, offset);
    var end = offset;
    while (end < source.len and source[end] != '\n') end += 1;
    return source[start..end];
}

fn getLineNumber(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn getIndent(source: []const u8, offset: usize) []const u8 {
    const start = lineStartOffset(source, offset);
    var end = start;
    while (end < source.len and (source[end] == ' ' or source[end] == '\t')) end += 1;
    return source[start..end];
}

// ============================================================================
// Build file rewriting
// ============================================================================

fn rewriteBuildFile(source: []const u8, output: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    var pos: usize = 0;
    while (pos < source.len) {
        if (std.mem.indexOf(u8, source[pos..], "b.path(\"")) |rel_start| {
            const abs_start = pos + rel_start;
            try output.appendSlice(allocator, source[pos .. abs_start + 8]);
            const after = source[abs_start + 8 ..];
            if (std.mem.indexOf(u8, after, "\"")) |quote_end| {
                const path = after[0..quote_end];
                if (!std.mem.startsWith(u8, path, "/") and !std.mem.startsWith(u8, path, "../")) {
                    try output.appendSlice(allocator, "../");
                }
                try output.appendSlice(allocator, path);
                pos = abs_start + 8 + quote_end;
            } else {
                pos = abs_start + 8;
            }
        } else {
            try output.appendSlice(allocator, source[pos..]);
            break;
        }
    }
}
