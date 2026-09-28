//! Shared by the preprocessor (build time) and the ring (run time): which
//! functions can be redirected, their stable ids, and who calls whom by name.
const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;

pub const Function = struct {
    file: []const u8, // source-relative, e.g. "timeline.zig"
    path: []const u8, // "Timeline.frameForTraversal"
    name: []const u8, // "frameForTraversal"
    id: u64,
    callees: []const []const u8, // bare names called in the body; over-approximate by design
};

/// Stable across builds and images: FNV-1a of "file:path".
pub fn functionId(file: []const u8, path: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(file);
    hasher.update(":");
    hasher.update(path);
    return hasher.final();
}

/// "Outer.Inner.fn" from the enclosing `const X = struct` names.
pub fn qualifiedPath(allocator: std.mem.Allocator, containers: []const []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (containers) |segment| {
        try out.appendSlice(allocator, segment);
        try out.append(allocator, '.');
    }
    try out.appendSlice(allocator, name);
    return out.toOwnedSlice(allocator);
}

pub fn isContainerTag(tag: Node.Tag) bool {
    return switch (tag) {
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
        => true,
        else => false,
    };
}

pub fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// One address, default calling convention, every param named: the only shape a
/// redirect wrapper can forward. "Not nested in a fn body" is the caller's check.
pub fn isRedirectable(ast: *const Ast, fn_node: Node.Index) bool {
    if (ast.nodeTag(fn_node) != .fn_decl) return false;
    const proto_node = ast.nodeData(fn_node).node_and_node[0];
    var buf: [1]Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, proto_node) orelse return false;
    if (proto.name_token == null) return false;
    if (proto.ast.callconv_expr != .none) return false; // .c / .naked / .@"inline"
    var token = ast.firstToken(fn_node); // includes pub/export/extern/inline
    while (token < proto.ast.fn_token) : (token += 1) {
        switch (ast.tokenTag(token)) {
            .keyword_export, .keyword_extern, .keyword_inline => return false,
            else => {},
        }
    }
    var params = proto.iterate(ast);
    while (params.next()) |param| {
        if (param.anytype_ellipsis3 != null) return false; // anytype: no single address
        if (param.comptime_noalias) |t| {
            if (ast.tokenTag(t) == .keyword_comptime) return false;
        }
        const name_token = param.name_token orelse return false;
        if (std.mem.eql(u8, ast.tokenSlice(name_token), "_")) return false; // the wrapper must forward it by name
    }
    return true;
}

/// Every `name(` in the body. Over-approximates (type constructors, methods of
/// other types with the same name) — the ring only uses it to guess neighbours.
fn calleeNames(allocator: std.mem.Allocator, ast: *const Ast, body: Node.Index) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var token = ast.firstToken(body);
    const last = ast.lastToken(body);
    while (token < last) : (token += 1) {
        if (ast.tokenTag(token) != .identifier or ast.tokenTag(token + 1) != .l_paren) continue;
        const name = ast.tokenSlice(token);
        if (containsName(out.items, name)) continue;
        try out.append(allocator, try allocator.dupe(u8, name));
    }
    return out.toOwnedSlice(allocator);
}

/// Index one file: every redirectable decl-level function, with the same path
/// and id the preprocessor gives its wrapper.
pub fn indexFile(allocator: std.mem.Allocator, file: []const u8, source: [:0]const u8) error{OutOfMemory}![]Function {
    var ast = try Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);
    var out: std.ArrayList(Function) = .empty;
    if (ast.errors.len != 0) return out.toOwnedSlice(allocator);
    var containers: std.ArrayList([]const u8) = .empty;
    for (ast.rootDecls()) |decl| try indexDecl(allocator, &ast, file, decl, &containers, &out);
    return out.toOwnedSlice(allocator);
}

fn indexDecl(
    allocator: std.mem.Allocator,
    ast: *const Ast,
    file: []const u8,
    node: Node.Index,
    containers: *std.ArrayList([]const u8),
    out: *std.ArrayList(Function),
) error{OutOfMemory}!void {
    const tag = ast.nodeTag(node);
    if (tag == .fn_decl) {
        if (!isRedirectable(ast, node)) return;
        var buf: [1]Node.Index = undefined;
        const data = ast.nodeData(node).node_and_node; // [0]=proto, [1]=body
        const proto = ast.fullFnProto(&buf, data[0]).?;
        const name = try allocator.dupe(u8, ast.tokenSlice(proto.name_token.?));
        const path = try qualifiedPath(allocator, containers.items, name);
        try out.append(allocator, .{
            .file = file,
            .path = path,
            .name = name,
            .id = functionId(file, path),
            .callees = try calleeNames(allocator, ast, data[1]),
        });
        return;
    }
    if (isContainerTag(tag)) {
        var buf: [2]Node.Index = undefined;
        const full = ast.fullContainerDecl(&buf, node) orelse return;
        for (full.ast.members) |member| try indexDecl(allocator, ast, file, member, containers, out);
        return;
    }
    const decl = ast.fullVarDecl(node) orelse return;
    const init_node = decl.ast.init_node.unwrap() orelse return;
    if (!isContainerTag(ast.nodeTag(init_node))) return;
    try containers.append(allocator, ast.tokenSlice(decl.ast.mut_token + 1)); // `const Name = struct` → path segment
    defer _ = containers.pop();
    try indexDecl(allocator, ast, file, init_node, containers, out);
}
