const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const fn_index = @import("zdb").fn_index; // shared with the runtime ring: same eligibility, paths and ids

// ============================================================================
// Types
// ============================================================================

const Edit = struct {
    offset: usize,
    delete_len: usize,
    insert: []const u8,
};

const ScopeVar = struct {
    name: []const u8,
    mutable: bool,
};

/// --inspect fn:line:local:path — compile a printer for `local` + `path` at that statement.
const Inspect = struct { fn_name: []const u8, line: usize, local: []const u8, rest: []const u8 };

const TokenRange = struct { first: Ast.TokenIndex, last: Ast.TokenIndex };

const WalkContext = struct {
    ast: *const Ast,
    source: []const u8,
    edits: *std.ArrayList(Edit),
    vars: *std.ArrayList(ScopeVar),
    allocator: std.mem.Allocator,
    io: std.Io,
    fn_name: []const u8,
    enable_step: bool,
    enable_live: bool,
    input_file: []const u8,
    rel_path: []const u8, // source-relative; wrapper ids and generation keys use it
    needs_debug: bool,
    // When a selected file contains an explicit breakpoint, only the function
    // containing that marker is instrumented and hooks begin after the marker.
    // Marker-free files retain the legacy whole-file live/step behavior.
    marker_driven_file: bool,
    // --fn (repeatable): hook exactly these functions from their first statement;
    // overrides marker/whole-file gating so the runtime can request them without editing source
    targets: []const []const u8,
    target_hits: []usize, // per target: fn decls matching; >1 means bare-name collision
    container_path: std.ArrayList([]const u8) = .empty, // enclosing `const X = struct` names while walking decls
    entries: std.ArrayList([]const u8) = .empty, // "Timeline.frameForTraversal" per redirectable target
    entry_ids: std.ArrayList(u64) = .empty, // parallel to entries: the id the host's wrapper asks for
    prologue: bool, // --prologue: wrap every redirectable fn so a generation can take it over
    gen_mode: bool, // --gen: this copy is compiled into a generation dylib
    inspects: []const Inspect, // --inspect, repeatable; the Nth exports zdb_inspect_N / zdb_level_N
    inspect_done: []bool,
    fn_bodies: std.ArrayList(TokenRange) = .empty, // every fn body, for --gen's global rewrite
    split_continuation: bool,
    function_body: Node.Index = .root,
    hooks_enabled: bool = false,
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
    const io = threaded.io();
    const args = try init.args.toSlice(allocator);

    if (args.len < 3) {
        std.debug.print("Usage: preprocessor input.zig output.zig [--step] [--live] [--fn <name>]... [--rel <path>] [--prologue] [--gen] [--inspect fn:line:local:path]... [--runtime-path <path>]\n", .{});
        return 2;
    }

    const input_file = args[1];
    const output_file = args[2];
    var enable_step = false;
    var enable_live = false;
    var whole_file = false;
    var split_continuation = false;
    var runtime_path: ?[]const u8 = null;
    var targets: std.ArrayList([]const u8) = .empty;
    var rel_path: ?[]const u8 = null;
    var prologue = false;
    var gen_mode = false;
    var inspects: std.ArrayList(Inspect) = .empty;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--step")) {
            enable_step = true;
        } else if (std.mem.eql(u8, args[i], "--live")) {
            enable_live = true;
        } else if (std.mem.eql(u8, args[i], "--whole-file")) {
            whole_file = true;
        } else if (std.mem.eql(u8, args[i], "--split-continuation")) {
            split_continuation = true;
        } else if (std.mem.eql(u8, args[i], "--runtime-path") and i + 1 < args.len) {
            runtime_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--fn") and i + 1 < args.len) {
            try targets.append(allocator, args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--rel") and i + 1 < args.len) {
            rel_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--prologue")) {
            prologue = true;
        } else if (std.mem.eql(u8, args[i], "--gen")) {
            gen_mode = true;
        } else if (std.mem.eql(u8, args[i], "--inspect") and i + 1 < args.len) {
            try inspects.append(allocator, parseInspect(args[i + 1]) orelse {
                std.debug.print("[zdb] --inspect wants fn:line:local:path, got {s}\n", .{args[i + 1]});
                return 2;
            });
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
    const needs_debug = has_breakpoints or has_step or enable_step or enable_live or prologue or gen_mode;

    if (!needs_debug) {
        if (is_build_file) {
            var output_buf: std.ArrayList(u8) = .empty;
            defer output_buf.deinit(allocator);
            try rewriteBuildFile(source, &output_buf, allocator);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = output_buf.items });
        } else {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = source });
        }
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

    var vars: std.ArrayList(ScopeVar) = .empty;
    defer vars.deinit(allocator);

    // Phase 1: Add header (globals are never captured; on-demand inspection reaches them via zdb_source)
    try addHeader(source, &edits, allocator, runtime_path, is_build_file);
    if (enable_live) try edits.append(allocator, .{ .offset = source.len, .delete_len = 0, .insert = try std.fmt.allocPrint(allocator, "\nconst zdb_file_hash = zdb.live.compileFileHash(\"{s}\");\n", .{input_file}) });

    // Phase 2: Walk functions
    var ctx = WalkContext{
        .ast = &ast,
        .source = source,
        .edits = &edits,
        .vars = &vars,
        .allocator = allocator,
        .io = io,
        .fn_name = "",
        .enable_step = enable_step or has_step,
        .enable_live = enable_live,
        .input_file = input_file,
        .rel_path = rel_path orelse std.fs.path.basename(input_file),
        .needs_debug = needs_debug,
        .marker_driven_file = has_breakpoints and !whole_file,
        .targets = targets.items,
        .prologue = prologue,
        .gen_mode = gen_mode,
        .inspects = inspects.items,
        .inspect_done = blk: {
            const done = try allocator.alloc(bool, inspects.items.len);
            @memset(done, false);
            break :blk done;
        },
        .target_hits = try allocator.alloc(usize, targets.items.len),
        .split_continuation = split_continuation,
    };

    @memset(ctx.target_hits, 0);
    try walkTopLevel(&ctx);

    // A requested function that isn't here fails the build — never emit a quietly plain file
    for (ctx.targets, ctx.target_hits) |name, hits| {
        if (hits == 0) {
            std.debug.print("[zdb] --fn {s}: no such function in {s}\n", .{ name, input_file });
            return 1;
        }
        if (hits > 1) {
            std.debug.print("[zdb] --fn {s}: {d} functions share this name in {s}; all were instrumented\n", .{ name, hits, input_file });
        }
    }
    // The generation root exports these; the host build never references them, so they cost nothing there
    if (ctx.targets.len > 0) {
        if (ctx.entries.items.len < ctx.targets.len) {
            std.debug.print("[zdb] {s}: some --fn targets are generic or nested in a function body; they can't become generation entries\n", .{input_file});
        }
        var decl: std.ArrayList(u8) = .empty;
        try decl.appendSlice(allocator, "\npub const zdb_gen_entries = .{ ");
        for (ctx.entries.items) |path| try decl.print(allocator, "&{s}, ", .{path});
        try decl.appendSlice(allocator, "};\npub const zdb_gen_ids = [_]u64{ ");
        for (ctx.entry_ids.items) |id| try decl.print(allocator, "{d}, ", .{id});
        try decl.appendSlice(allocator, "};\n");
        try edits.append(allocator, .{ .offset = source.len, .delete_len = 0, .insert = decl.items });
    }
    for (ctx.inspects, ctx.inspect_done) |request, done| {
        if (!done) {
            std.debug.print("[zdb] --inspect: no statement at line {d} in {s}() of {s}\n", .{ request.line, request.fn_name, input_file });
            return 1;
        }
    }
    // Generation copies share the host's globals: every use in a fn body goes through the host's address
    if (gen_mode) try rewriteGlobals(&ctx);

    // Phase 3: Apply edits
    var output_buf: std.ArrayList(u8) = .empty;
    defer output_buf.deinit(allocator);
    try applyEdits(source, edits.items, &output_buf, allocator);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_file, .data = output_buf.items });
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

        // Variable decls whose init might be a container — `const X = struct` names a path segment
        .simple_var_decl,
        .local_var_decl,
        .global_var_decl,
        .aligned_var_decl,
        => {
            if (ctx.ast.fullVarDecl(node)) |decl| {
                if (decl.ast.init_node.unwrap()) |init_node| {
                    const name = getVarDeclName(ctx.ast, node);
                    const pushed = name != null and fn_index.isContainerTag(ctx.ast.nodeTag(init_node));
                    if (pushed) try ctx.container_path.append(ctx.allocator, name.?);
                    defer if (pushed) {
                        _ = ctx.container_path.pop();
                    };
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
    const saved_hooks_enabled = ctx.hooks_enabled;
    const saved_function_body = ctx.function_body;
    ctx.fn_name = fn_name;
    // Decl-level (not nested in a fn body) and one-address: a wrapper can forward it, a generation can replace it
    const redirectable = saved_fn.len == 0 and fn_index.isRedirectable(ctx.ast, fn_node);
    const qualified = if (redirectable) try fn_index.qualifiedPath(ctx.allocator, ctx.container_path.items, fn_name) else "";
    // --fn: only the named functions are hooked, from their first statement.
    // Otherwise, in marker-driven files each function starts as ordinary code
    // and `_ = .breakpoint;` opens the gate for the remainder of that function.
    var is_target = false;
    if (ctx.targets.len > 0) {
        if (indexOfName(ctx.targets, fn_name)) |index| {
            ctx.target_hits[index] += 1;
            is_target = true;
            if (redirectable) {
                try ctx.entries.append(ctx.allocator, qualified);
                try ctx.entry_ids.append(ctx.allocator, fn_index.functionId(ctx.rel_path, qualified));
            }
        }
        ctx.hooks_enabled = is_target;
    } else {
        ctx.hooks_enabled = !ctx.marker_driven_file;
    }
    // A generation's own targets are what wrappers jump TO, so they get none (no redirect loop)
    if (ctx.prologue and redirectable and !(ctx.gen_mode and is_target))
        try emitRedirectWrapper(ctx, fn_node, proto_node, fn_name, qualified);
    try ctx.fn_bodies.append(ctx.allocator, .{ .first = ctx.ast.firstToken(body_node), .last = ctx.ast.lastToken(body_node) });
    ctx.function_body = body_node;

    // Track pending discards and injection flag for this function
    const saved_injected = ctx.injected_in_fn;
    const discards_before = ctx.pending_discards.items.len;
    ctx.injected_in_fn = false;

    // Add function parameters as scope variables
    if (ctx.ast.fullFnProto(&proto_buf, proto_node)) |proto| {
        var it = proto.iterate(ctx.ast);
        while (it.next()) |param| {
            if (param.comptime_noalias) |tok| {
                if (ctx.ast.tokenTag(tok) == .keyword_comptime) continue; // comptime params have no runtime address
            }
            if (param.name_token) |name_tok| {
                const pname = ctx.ast.tokenSlice(name_tok);
                if (!std.mem.eql(u8, pname, "_")) {
                    try ctx.vars.append(ctx.allocator, .{
                        .name = try ctx.allocator.dupe(u8, pname),
                        .mutable = false,
                    });
                }
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
    ctx.hooks_enabled = saved_hooks_enabled;
    ctx.function_body = saved_function_body;
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
        const main_tok = ctx.ast.firstToken(stmt);
        const stmt_start: usize = ctx.ast.tokenStart(main_tok);

        const last_token = ctx.ast.lastToken(stmt);
        var stmt_end = ctx.ast.tokenStart(last_token) + ctx.ast.tokenSlice(last_token).len;
        if (stmt_end < ctx.source.len and ctx.source[stmt_end] == ';') stmt_end += 1;
        const trimmed = std.mem.trim(u8, ctx.source[stmt_start..stmt_end], " \t\r\n");
        const line_number = getLineNumber(ctx.source, stmt_start);

        // ---- --inspect: printer for local+path, placed where that local is in scope ----
        for (ctx.inspects, 0..) |request, slot| {
            if (!ctx.inspect_done[slot] and line_number == request.line and std.mem.eql(u8, ctx.fn_name, request.fn_name)) {
                try ctx.edits.append(ctx.allocator, .{
                    .offset = stmt_start,
                    .delete_len = 0,
                    .insert = try genInspect(ctx, getIndent(ctx.source, stmt_start), request, slot),
                });
                ctx.inspect_done[slot] = true;
            }
        }

        // ---- Breakpoint: `_ = .breakpoint;` ----
        if (isBreakpoint(trimmed)) {
            const ls = stmt_start;
            const le = stmt_end;
            const indent = getIndent(ctx.source, stmt_start);
            try ctx.edits.append(ctx.allocator, .{
                .offset = ls,
                .delete_len = le - ls,
                .insert = try genBreakpoint(ctx, indent, line_number),
            });
            ctx.injected_in_fn = true;
            // Under --fn a marker still stops, but only target functions get hooks
            if (ctx.targets.len == 0) ctx.hooks_enabled = true;
            if (ctx.split_continuation and block_node == ctx.function_body) {
                const close_brace = ctx.ast.tokenStart(ctx.ast.lastToken(block_node));
                if (stmt_end < close_brace) {
                    try ctx.edits.append(ctx.allocator, .{
                        .offset = stmt_end,
                        .delete_len = close_brace - stmt_end,
                        .insert = "",
                    });
                }
                break;
            }
            continue;
        }

        // ---- step_debug() marker ----
        if (std.mem.indexOf(u8, trimmed, "step_debug();") != null) {
            continue;
        }

        // ---- Discard of tracked variable: queue for deletion ----
        // Only actually deleted if instrumentation is injected in this function
        if (ctx.hooks_enabled and isTrackedDiscard(trimmed, ctx.vars.items)) {
            const ls = stmt_start;
            const le = stmt_end;
            try ctx.pending_discards.append(ctx.allocator, .{
                .offset = ls,
                .delete_len = le - ls,
                .insert = "",
            });
            continue;
        }

        // ---- Inject step debug ----
        if (ctx.needs_debug and ctx.hooks_enabled and ctx.enable_step and isInjectableStatement(tag)) {
            const insert_at = stmt_start;
            const indent = getIndent(ctx.source, stmt_start);
            try ctx.edits.append(ctx.allocator, .{
                .offset = insert_at,
                .delete_len = 0,
                .insert = try genStepDebug(ctx, trimmed, line_number, indent),
            });
            ctx.injected_in_fn = true;
        }

        // ---- Inject live breakpoint check ----
        if (ctx.needs_debug and ctx.hooks_enabled and ctx.enable_live and isInjectableStatement(tag)) {
            const insert_at = stmt_start;
            const indent = getIndent(ctx.source, stmt_start);
            try ctx.edits.append(ctx.allocator, .{
                .offset = insert_at,
                .delete_len = 0,
                .insert = try genLiveCheck(ctx, line_number, indent),
            });
            ctx.injected_in_fn = true;
        }

        // ---- Track variable declarations ----
        if (isVarDecl(tag)) {
            if (getVarDeclName(ctx.ast, stmt)) |name| {
                const decl = ctx.ast.fullVarDecl(stmt).?;
                // `comptime var` → &x at runtime is "runtime value contains reference to comptime var"
                if (!isImportDecl(ctx.ast, ctx.source, stmt) and decl.comptime_token == null) {
                    try ctx.vars.append(ctx.allocator, .{
                        .name = try ctx.allocator.dupe(u8, name),
                        .mutable = ctx.ast.tokenTag(decl.ast.mut_token) == .keyword_var,
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
    // Runtime hooks cannot appear inside explicitly comptime expressions.
    if (tag == .@"comptime") return;

    // If this node IS a block, walk it directly
    if (isBlockLike(tag)) {
        try walkBlock(ctx, node);
        return;
    }

    switch (tag) {
        // If/else
        .@"if", .if_simple => {
            if (ctx.ast.fullIf(node)) |full| {
                const then_scope = ctx.vars.items.len;
                if (full.payload_token) |token| _ = try appendPayloadVariable(ctx, token);
                try walkBlockOrRecurse(ctx, full.ast.then_expr);
                ctx.vars.shrinkRetainingCapacity(then_scope);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    const else_scope = ctx.vars.items.len;
                    if (full.error_token) |token| _ = try appendPayloadVariable(ctx, token);
                    try walkBlockOrRecurse(ctx, else_expr);
                    ctx.vars.shrinkRetainingCapacity(else_scope);
                }
            }
        },

        // While loops. Inline-while payloads may be comptime-only; don't capture them.
        .@"while", .while_simple, .while_cont => {
            if (ctx.ast.fullWhile(node)) |full| {
                const is_inline = full.inline_token != null;
                const then_scope = ctx.vars.items.len;
                if (!is_inline) {
                    if (full.payload_token) |token| _ = try appendPayloadVariable(ctx, token);
                }
                try walkBlockOrRecurse(ctx, full.ast.then_expr);
                ctx.vars.shrinkRetainingCapacity(then_scope);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    const else_scope = ctx.vars.items.len;
                    if (!is_inline) {
                        if (full.error_token) |token| _ = try appendPayloadVariable(ctx, token);
                    }
                    try walkBlockOrRecurse(ctx, else_expr);
                    ctx.vars.shrinkRetainingCapacity(else_scope);
                }
            }
        },

        // For loops. Payloads are ordinary lexical variables inside the loop
        // body, so include them in every generated breakpoint/step capture —
        // except inline-for payloads (e.g. StructField), which are comptime-only.
        .@"for", .for_simple => {
            if (ctx.ast.fullFor(node)) |full| {
                const scope_save = ctx.vars.items.len;
                if (full.inline_token == null) {
                    var capture_token = full.payload_token;
                    for (full.ast.inputs) |_| {
                        const ident_token = try appendPayloadVariable(ctx, capture_token);
                        // identifier, followed by either a comma or the closing |.
                        capture_token = ident_token + 2;
                    }
                }
                try walkBlockOrRecurse(ctx, full.ast.then_expr);
                ctx.vars.shrinkRetainingCapacity(scope_save);
                if (full.ast.else_expr.unwrap()) |else_expr| {
                    try walkBlockOrRecurse(ctx, else_expr);
                }
            }
        },

        // Switch — walk each case body. Inline prongs bind comptime payloads; skip them.
        .@"switch", .switch_comma => {
            if (ctx.ast.fullSwitch(node)) |full| {
                for (full.ast.cases) |case_node| {
                    if (ctx.ast.fullSwitchCase(case_node)) |case| {
                        const case_scope = ctx.vars.items.len;
                        if (case.inline_token == null) {
                            if (case.payload_token) |token| _ = try appendPayloadVariable(ctx, token);
                        }
                        try walkBlockOrRecurse(ctx, case.ast.target_expr);
                        ctx.vars.shrinkRetainingCapacity(case_scope);
                    }
                }
            }
        },

        // Catch/orelse — RHS might be a block
        .@"catch" => {
            const rhs = ctx.ast.nodeData(node).node_and_node[1];
            const scope_save = ctx.vars.items.len;
            const catch_token = ctx.ast.nodeMainToken(node);
            if (ctx.ast.tokenTag(catch_token + 1) == .pipe) {
                _ = try appendPayloadVariable(ctx, catch_token + 2);
            }
            try walkBlockOrRecurse(ctx, rhs);
            ctx.vars.shrinkRetainingCapacity(scope_save);
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

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name)) return index;
    }
    return null;
}

fn parseInspect(arg: []const u8) ?Inspect {
    var parts = std.mem.splitScalar(u8, arg, ':');
    const fn_name = parts.next() orelse return null;
    const line = std.fmt.parseInt(usize, parts.next() orelse return null, 10) catch return null;
    const local = parts.next() orelse return null;
    return .{ .fn_name = fn_name, .line = line, .local = local, .rest = parts.rest() };
}

fn tokenEnd(ast: *const Ast, token: Ast.TokenIndex) usize {
    return ast.tokenStart(token) + ast.tokenSlice(token).len;
}

/// `fn f(a: A) R { body }` becomes
///   `fn f(a: A) <body's return type> { if (zdb.gen.redirect(ID)) |t| return zdb.gen.crossReturn(@TypeOf(&f__zdb_ID), t, .{a}); return f__zdb_ID(a); }`
///   `fn f__zdb_ID(a: A) R { body }`
/// The wrapper keeps the name (callers, method syntax and &f reach it); the body keeps every hook
/// untouched. Body name carries the id: same-named fns in nested scopes would otherwise be ambiguous.
/// Return type comes from the body: re-typing `?struct {...}` would make a second, distinct type.
fn emitRedirectWrapper(ctx: *WalkContext, fn_node: Node.Index, proto_node: Node.Index, fn_name: []const u8, qualified: []const u8) WalkError!void {
    const ast = ctx.ast;
    const alloc = ctx.allocator;
    var proto_buf: [1]Node.Index = undefined;
    const proto = ast.fullFnProto(&proto_buf, proto_node).?;
    const return_type = proto.ast.return_type.unwrap() orelse return; // no return type: not a fn we can wrap
    var return_start = ast.firstToken(return_type);
    if (ast.tokenTag(return_start - 1) == .bang) return_start -= 1; // inferred error set `!T`

    const id = fn_index.functionId(ctx.rel_path, qualified);
    const body_name = try std.fmt.allocPrint(alloc, "{s}__zdb_{x}", .{ fn_name, id });
    const start = ast.tokenStart(ast.firstToken(fn_node)); // includes `pub`
    const head_text = ctx.source[start..ast.tokenStart(return_start)]; // `pub fn f(a: A) `

    var args: std.ArrayList(u8) = .empty;
    var params = proto.iterate(ast);
    var first = true;
    while (params.next()) |param| {
        if (!first) try args.appendSlice(alloc, ", ");
        try args.appendSlice(alloc, ast.tokenSlice(param.name_token.?)); // isRedirectable guaranteed a name
        first = false;
    }

    var wrapper: std.ArrayList(u8) = .empty;
    try wrapper.print(alloc, "{s}@typeInfo(@TypeOf({s})).@\"fn\".return_type.? {{ if (zdb.gen.redirect({d})) |zdb_target| return zdb.gen.crossReturn(@TypeOf(&{s}), zdb_target, .{{{s}}}); return {s}({s}); }}\n", .{
        head_text, body_name, id, body_name, args.items, body_name, args.items,
    });
    try wrapper.appendSlice(alloc, getIndent(ctx.source, start));
    try ctx.edits.append(alloc, .{ .offset = start, .delete_len = 0, .insert = wrapper.items });

    try ctx.edits.append(alloc, .{
        .offset = ast.tokenStart(proto.name_token.?),
        .delete_len = fn_name.len,
        .insert = body_name,
    });
}

/// Add one lexical payload capture and return its identifier token. Payload
/// tokens point at either the identifier itself or a leading `*`.
fn appendPayloadVariable(ctx: *WalkContext, payload_token: Ast.TokenIndex) WalkError!Ast.TokenIndex {
    const is_pointer = ctx.ast.tokenTag(payload_token) == .asterisk;
    const ident_token = payload_token + @intFromBool(is_pointer);
    const name = ctx.ast.tokenSlice(ident_token);
    if (!std.mem.eql(u8, name, "_")) {
        try ctx.vars.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, name),
            .mutable = false,
        });
    }
    return ident_token;
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

    try header.appendSlice(allocator, "// AUTO-GENERATED - DO NOT EDIT\nconst zdb_source = @This();\n");

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

fn genBreakpoint(ctx: *WalkContext, indent: []const u8, line_number: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "if (!@inComptime()) {\n");
    try appendLocalsDecl(&buf, ctx, indent, "    ");
    try buf.appendSlice(ctx.allocator, indent);
    if (ctx.enable_live) {
        try buf.print(ctx.allocator, "    zdb.live.onBreak(\"{s}\", \"{s}\", zdb_file_hash, {}, &zdb_locals);\n", .{ ctx.fn_name, ctx.input_file, line_number });
    } else {
        try buf.print(ctx.allocator, "    zdb.handleBreakpoint(\"{s}\", \"{s}\", {d}, &zdb_locals);\n", .{ ctx.fn_name, ctx.input_file, line_number });
    }
    if (ctx.split_continuation) {
        try buf.appendSlice(ctx.allocator, indent);
        try buf.print(ctx.allocator, "    if (!zdb.runSidecarContinuation(\"{s}\", &zdb_locals)) @panic(\"ZDB continuation failed\");\n", .{ctx.fn_name});
        try buf.appendSlice(ctx.allocator, indent);
        try buf.appendSlice(ctx.allocator, "    return;\n");
    }
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "}\n");
    return buf.toOwnedSlice(ctx.allocator);
}

fn genStepDebug(ctx: *WalkContext, line_text: []const u8, line_number: usize, indent: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "if (!@inComptime() and zdb.isStepping()) {\n");
    try appendLocalsDecl(&buf, ctx, indent, "    ");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    zdb.handleStepBefore(\"");
    try buf.appendSlice(ctx.allocator, ctx.fn_name);
    try buf.appendSlice(ctx.allocator, "\", \"");
    try buf.appendSlice(ctx.allocator, ctx.input_file);
    try buf.appendSlice(ctx.allocator, "\", \"");
    try appendEscaped(&buf, ctx.allocator, line_text);
    try buf.print(ctx.allocator, "\", {}, &zdb_locals);\n", .{line_number});
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "}\n");
    return buf.toOwnedSlice(ctx.allocator);
}

fn genLiveCheck(ctx: *WalkContext, line_number: usize, indent: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "if (!@inComptime()) {\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.print(ctx.allocator, "    if (zdb.live.shouldBreak(zdb_file_hash, {})) {{\n", .{line_number});
    try appendLocalsDecl(&buf, ctx, indent, "        ");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.print(ctx.allocator, "        zdb.live.onBreak(\"{s}\", \"{s}\", zdb_file_hash, {}, &zdb_locals);\n", .{ ctx.fn_name, ctx.input_file, line_number });
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "    }\n");
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, "}\n");
    return buf.toOwnedSlice(ctx.allocator);
}

/// `const zdb_locals = [_]zdb.sidecar_abi.LocalRef{ zdb.localRef("x", &x), ... };`
/// Pointer + type name per local — nothing about a local's type is walked or
/// printed here. Every hook gets the same slice type, so handlers stay non-generic.
fn appendLocalsDecl(buf: *std.ArrayList(u8), ctx: *WalkContext, indent: []const u8, inner: []const u8) !void {
    try buf.appendSlice(ctx.allocator, indent);
    try buf.appendSlice(ctx.allocator, inner);
    try buf.appendSlice(ctx.allocator, "const zdb_locals = [_]zdb.sidecar_abi.LocalRef{");
    for (ctx.vars.items, 0..) |v, idx| {
        if (idx > 0) try buf.appendSlice(ctx.allocator, ", ");
        try buf.print(ctx.allocator, "zdb.localRef(\"{s}\", &{s})", .{ v.name, v.name }); // &x of a const is *const T ⇒ read-only ref
    }
    try buf.appendSlice(ctx.allocator, "};\n");
}

/// Two exported printers for `local` + `rest`, typed through @TypeOf(local) right where
/// the stop was: zdb_inspect_N prints the value, zdb_level_N prints one of its fields
/// by run-time name (the instant next click). Each path segment is a checked zdb.gen
/// step, so a stale path prints why instead of faulting. Every name here is zdb_-prefixed:
/// nested-struct params may not shadow the user's locals.
fn genInspect(ctx: *WalkContext, indent: []const u8, request: Inspect, slot: usize) ![]const u8 {
    const alloc = ctx.allocator;
    const body = try std.fmt.allocPrint(alloc, "{s}            ", .{indent});
    var steps: std.ArrayList(u8) = .empty; // shared by both printers
    try steps.print(alloc, "{s}const zdb_v0: *ZdbInspectT{d} = @ptrCast(@alignCast(zdb_ptr));\n", .{ body, slot });
    var n: usize = 0;
    var rest = request.rest;
    var ranged = false;
    var bad = false;
    while (rest.len > 0 and !bad) {
        if (ranged) {
            bad = true; // [a..b] must be last
        } else if (rest[0] == '.') {
            const end_at = std.mem.indexOfAnyPos(u8, rest, 1, ".[") orelse rest.len;
            if (end_at == 1) {
                bad = true;
            } else {
                try steps.print(alloc, "{s}const zdb_v{d} = zdb.gen.field(zdb_v{d}, \"{s}\") orelse return zdb.gen.pathFailed(zdb_out[0..zdb_cap]);\n", .{ body, n + 1, n, rest[1..end_at] });
                rest = rest[end_at..];
                n += 1;
            }
        } else if (rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse {
                bad = true;
                continue;
            };
            const inner = rest[1..close];
            if (std.mem.indexOf(u8, inner, "..")) |dots| {
                const a = std.fmt.parseInt(usize, inner[0..dots], 10) catch null;
                const b = std.fmt.parseInt(usize, inner[dots + 2 ..], 10) catch null;
                if (a == null or b == null) {
                    bad = true;
                    continue;
                }
                try steps.print(alloc, "{s}const zdb_v{d} = zdb.gen.range(zdb_v{d}, {d}, {d}) orelse return zdb.gen.pathFailed(zdb_out[0..zdb_cap]);\n", .{ body, n + 1, n, a.?, b.? });
                ranged = true;
            } else {
                const i = std.fmt.parseInt(usize, inner, 10) catch {
                    bad = true;
                    continue;
                };
                try steps.print(alloc, "{s}const zdb_v{d} = zdb.gen.index(zdb_v{d}, {d}) orelse return zdb.gen.pathFailed(zdb_out[0..zdb_cap]);\n", .{ body, n + 1, n, i });
            }
            rest = rest[close + 1 ..];
            n += 1;
        } else {
            bad = true;
        }
    }

    var print_tail: []const u8 = undefined;
    var level_tail: []const u8 = undefined;
    if (bad) {
        print_tail = try std.fmt.allocPrint(alloc, "{s}@compileError(\"zdb: can't read inspect path '{s}' (names, [index], [a..b] last)\");\n", .{ body, request.rest });
        level_tail = print_tail;
    } else {
        print_tail = if (n == 0)
            try std.fmt.allocPrint(alloc, "{s}return zdb.gen.formatInto(zdb_out[0..zdb_cap], zdb_v0.*);\n", .{body})
        else
            try std.fmt.allocPrint(alloc, "{s}return zdb.gen.formatInto(zdb_out[0..zdb_cap], zdb_v{d});\n", .{ body, n });
        level_tail = if (ranged) // a range has no fields: every param and the range itself are discarded
            try std.fmt.allocPrint(alloc, "{s}_ = zdb_v{d};\n{s}_ = zdb_name;\n{s}_ = zdb_name_len;\n{s}return zdb.gen.noFields(zdb_out[0..zdb_cap]);\n", .{ body, n, body, body, body })
        else
            try std.fmt.allocPrint(alloc, "{s}return zdb.gen.formatField(zdb_out[0..zdb_cap], zdb_v{d}, zdb_name[0..zdb_name_len]);\n", .{ body, n });
    }

    var out: std.ArrayList(u8) = .empty;
    try out.print(alloc, "{s}const ZdbInspectT{d} = @TypeOf({s});\n", .{ indent, slot, request.local });
    try out.print(alloc, "{s}comptime {{\n", .{indent});
    try out.print(alloc, "{s}    @export(&struct {{\n{s}        fn zdb_print(zdb_ptr: *anyopaque, zdb_out: [*]u8, zdb_cap: usize) callconv(.c) usize {{\n", .{ indent, indent });
    try out.print(alloc, "{s}{s}", .{ steps.items, print_tail });
    try out.print(alloc, "{s}        }}\n{s}    }}.zdb_print, .{{ .name = \"zdb_inspect_{d}\" }});\n", .{ indent, indent, slot });
    try out.print(alloc, "{s}    @export(&struct {{\n{s}        fn zdb_level(zdb_ptr: *anyopaque, zdb_name: [*]const u8, zdb_name_len: usize, zdb_out: [*]u8, zdb_cap: usize) callconv(.c) usize {{\n", .{ indent, indent });
    try out.print(alloc, "{s}{s}", .{ steps.items, level_tail });
    try out.print(alloc, "{s}        }}\n{s}    }}.zdb_level, .{{ .name = \"zdb_level_{d}\" }});\n", .{ indent, indent, slot });
    try out.print(alloc, "{s}}}\n", .{indent});
    return out.items;
}

// ============================================================================
// Generation globals
// ============================================================================

const GlobalScope = struct { first: Ast.TokenIndex, last: Ast.TokenIndex, names: []const []const u8 };

/// Mutable, process-wide, one-per-image: exactly the globals a generation would otherwise duplicate.
fn isSharedGlobal(ast: *const Ast, node: Node.Index) bool {
    const decl = ast.fullVarDecl(node) orelse return false;
    return ast.tokenTag(decl.ast.mut_token) == .keyword_var and
        decl.threadlocal_token == null and // per-thread storage has no single host address
        decl.extern_export_token == null; // extern/export already resolve to one symbol
}

fn containerGlobals(ctx: *WalkContext, container: Node.Index) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var buf: [2]Node.Index = undefined;
    const full = ctx.ast.fullContainerDecl(&buf, container) orelse return names.items;
    for (full.ast.members) |member| {
        if (!isSharedGlobal(ctx.ast, member)) continue;
        if (getVarDeclName(ctx.ast, member)) |name| try names.append(ctx.allocator, name);
    }
    return names.items;
}

fn importPath(ast: *const Ast, node: Node.Index) ?[]const u8 {
    var buf: [2]Node.Index = undefined;
    const params = ast.builtinCallParams(&buf, node) orelse return null;
    if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import") or params.len != 1) return null;
    if (ast.nodeTag(params[0]) != .string_literal) return null;
    const literal = ast.tokenSlice(ast.nodeMainToken(params[0]));
    return literal[1 .. literal.len - 1];
}

/// File-scope globals of a sibling file this one imports as `const alias = @import("x.zig")`.
fn importedGlobals(ctx: *WalkContext, import_path: []const u8) ![]const []const u8 {
    const dir = std.fs.path.dirname(ctx.input_file) orelse ".";
    const full_path = try std.fs.path.join(ctx.allocator, &.{ dir, import_path });
    const source = std.Io.Dir.cwd().readFileAlloc(ctx.io, full_path, ctx.allocator, .limited(10 * 1024 * 1024)) catch {
        std.debug.print("[zdb] couldn't read {s}; `alias.global` uses of it keep the generation's copy (NOT shared)\n", .{full_path});
        return &.{};
    };
    const ast = try Ast.parse(ctx.allocator, try ctx.allocator.dupeZ(u8, source), .zig);
    var names: std.ArrayList([]const u8) = .empty;
    for (ast.rootDecls()) |decl| {
        if (!isSharedGlobal(&ast, decl)) continue;
        if (getVarDeclName(&ast, decl)) |name| try names.append(ctx.allocator, try ctx.allocator.dupe(u8, name));
    }
    return names.items;
}

fn replaceTokens(ctx: *WalkContext, first: Ast.TokenIndex, last: Ast.TokenIndex, text: []const u8) !void {
    const offset = ctx.ast.tokenStart(first);
    try ctx.edits.append(ctx.allocator, .{ .offset = offset, .delete_len = tokenEnd(ctx.ast, last) - offset, .insert = text });
}

/// In every fn body: `g` → `zdb.gen.hostGlobal(&g).*`, likewise `alias.g` and `Container.g`.
/// Declarations stay put (the generation's copies exist, unused); only uses move to the host's.
fn rewriteGlobals(ctx: *WalkContext) !void {
    const ast = ctx.ast;
    const alloc = ctx.allocator;
    var file_vars: std.ArrayList([]const u8) = .empty;
    var containers: std.StringHashMapUnmanaged([]const []const u8) = .empty; // `const C = struct` → its globals
    var aliases: std.StringHashMapUnmanaged([]const []const u8) = .empty; // `const a = @import("x.zig")` → x's globals
    for (ast.rootDecls()) |decl_node| {
        const name = getVarDeclName(ast, decl_node) orelse continue;
        if (isSharedGlobal(ast, decl_node)) {
            try file_vars.append(alloc, name);
            continue;
        }
        const decl = ast.fullVarDecl(decl_node) orelse continue;
        const init_node = decl.ast.init_node.unwrap() orelse continue;
        if (fn_index.isContainerTag(ast.nodeTag(init_node))) {
            try containers.put(alloc, name, try containerGlobals(ctx, init_node));
        } else if (importPath(ast, init_node)) |path| {
            if (std.mem.endsWith(u8, path, ".zig")) try aliases.put(alloc, name, try importedGlobals(ctx, path));
        }
    }
    var scopes: std.ArrayList(GlobalScope) = .empty; // bare `g` inside a container means that container's g
    for (0..ast.nodes.len) |i| {
        const node: Node.Index = @enumFromInt(@as(u32, @intCast(i)));
        if (!fn_index.isContainerTag(ast.nodeTag(node))) continue;
        const names = try containerGlobals(ctx, node);
        if (names.len > 0) try scopes.append(alloc, .{ .first = ast.firstToken(node), .last = ast.lastToken(node), .names = names });
    }
    var in_body = try std.DynamicBitSetUnmanaged.initEmpty(alloc, ast.tokens.len);
    for (ctx.fn_bodies.items) |range| in_body.setRangeValue(.{ .start = range.first, .end = range.last + 1 }, true);

    var token: Ast.TokenIndex = 0;
    while (token < ast.tokens.len) : (token += 1) {
        if (!in_body.isSet(token) or ast.tokenTag(token) != .identifier) continue;
        if (token > 0) {
            switch (ast.tokenTag(token - 1)) {
                .period, .keyword_const, .keyword_var, .keyword_fn => continue, // field, or a declaration's own name
                else => {},
            }
        }
        const name = ast.tokenSlice(token);
        if (token + 2 < ast.tokens.len and ast.tokenTag(token + 1) == .period and ast.tokenTag(token + 2) == .identifier) {
            const member = ast.tokenSlice(token + 2);
            if (aliases.get(name) orelse containers.get(name)) |globals| {
                if (fn_index.containsName(globals, member)) {
                    try replaceTokens(ctx, token, token + 2, try std.fmt.allocPrint(alloc, "zdb.gen.hostGlobal(&{s}.{s}).*", .{ name, member }));
                    token += 2;
                    continue;
                }
            }
        }
        if (token + 1 < ast.tokens.len and ast.tokenTag(token + 1) == .colon) continue; // label or field decl
        if (fn_index.containsName(file_vars.items, name) or inScope(scopes.items, token, name)) {
            try replaceTokens(ctx, token, token, try std.fmt.allocPrint(alloc, "zdb.gen.hostGlobal(&{s}).*", .{name}));
        }
    }
}

fn inScope(scopes: []const GlobalScope, token: Ast.TokenIndex, name: []const u8) bool {
    for (scopes) |scope| {
        if (token >= scope.first and token <= scope.last and fn_index.containsName(scope.names, name)) return true;
    }
    return false;
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
            if (std.mem.eql(u8, name, "_")) return null;
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

/// `_ = x;` becomes a "pointless discard" once the hook uses x, so it's deleted.
/// Globals aren't captured anymore, so their discards stay.
fn isTrackedDiscard(trimmed: []const u8, vars: []const ScopeVar) bool {
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
