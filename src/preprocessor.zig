const std = @import("std");

// Structure to hold different types of globals
const GlobalVar = struct {
    name: []const u8,
    var_type: enum {
        regular,
        thread_local,
        comptime_const,
        pub_var,
        pub_const,
    },
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: preprocessor input.zig output.zig [--step] [--runtime-path <path>]\n", .{});
        return;
    }

    const input_file = args[1];
    const output_file = args[2];
    var enable_step = false;
    var runtime_path: ?[]const u8 = null;

    // Parse additional arguments
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
        std.fs.cwd().makePath(dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };
    }

    const source = try std.fs.cwd().readFileAlloc(allocator, input_file, 10 * 1024 * 1024);
    defer allocator.free(source);

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    // Check if file needs preprocessing
    const has_breakpoints = std.mem.indexOf(u8, source, "_ = .breakpoint;") != null;
    const has_step = std.mem.indexOf(u8, source, "step_debug()") != null;
    const needs_debug = has_breakpoints or has_step or enable_step;

    if (needs_debug) {
        // Add imports
        const has_std_import = std.mem.indexOf(u8, source, "@import(\"std\")") != null;

        try output.appendSlice("// AUTO-GENERATED - DO NOT EDIT\n");
        if (!has_std_import) {
            try output.appendSlice("const std = @import(\"std\");\n");
        }

        // Determine the import path for zdb runtime
        if (runtime_path) |path| {
            // Explicit runtime path provided
            try output.writer().print("const zdb = @import(\"{s}\");\n\n", .{path});
        } else if (std.mem.endsWith(u8, input_file, "build.zig")) {
            // For build.zig - use a special marker that we'll handle differently
            try output.appendSlice("const zdb = @import(\"zdb\"); // SPECIAL:BUILD_FILE\n\n");
        } else {
            // Default for regular files - use module import
            try output.appendSlice("const zdb = @import(\"zdb\");\n\n");
        }
    }

    // Process the source line by line
    var lines = std.mem.splitScalar(u8, source, '\n');
    var vars_in_scope = std.ArrayList([]const u8).init(allocator);
    defer vars_in_scope.deinit();

    // Track globals
    var globals_in_file = std.ArrayList(GlobalVar).init(allocator);
    defer globals_in_file.deinit();

    var in_function = false;
    var current_function: []const u8 = "";
    var indent_level: usize = 0;
    var brace_count: usize = 0;
    var line_number: usize = 0;
    var step_mode_active = enable_step or has_step;
    var in_initializer = false;
    var global_brace_count: usize = 0; // Track top-level braces

    const is_build_file = std.mem.endsWith(u8, input_file, "build.zig");

    while (lines.next()) |line| {
        line_number += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Track global brace count
        for (trimmed) |c| {
            if (c == '{') global_brace_count += 1;
            if (c == '}' and global_brace_count > 0) global_brace_count -= 1;
        }

        // Track globals (only at top level)
        if (!in_function and global_brace_count == 0) {
            // Thread-local variables
            if (std.mem.startsWith(u8, trimmed, "threadlocal var ")) {
                if (parseVarNameFrom(trimmed, "threadlocal var ")) |var_name| {
                    try globals_in_file.append(.{
                        .name = try allocator.dupe(u8, var_name),
                        .var_type = .thread_local,
                    });
                }
            }
            // Regular globals
            else if (std.mem.startsWith(u8, trimmed, "var ")) {
                if (parseVarName(trimmed)) |var_name| {
                    try globals_in_file.append(.{
                        .name = try allocator.dupe(u8, var_name),
                        .var_type = .regular,
                    });
                }
            }
            // Public variables
            else if (std.mem.startsWith(u8, trimmed, "pub var ")) {
                if (parseVarNameFrom(trimmed, "pub var ")) |var_name| {
                    try globals_in_file.append(.{
                        .name = try allocator.dupe(u8, var_name),
                        .var_type = .pub_var,
                    });
                }
            }
            // Constants (including comptime)
            else if (std.mem.startsWith(u8, trimmed, "const ")) {
                if (parseVarName(trimmed)) |var_name| {
                    // Check if it's a comptime block
                    const is_comptime = std.mem.indexOf(u8, trimmed, "comptime") != null;
                    try globals_in_file.append(.{
                        .name = try allocator.dupe(u8, var_name),
                        .var_type = if (is_comptime) .comptime_const else .regular,
                    });
                }
            }
            // Public constants
            else if (std.mem.startsWith(u8, trimmed, "pub const ")) {
                if (parseVarNameFrom(trimmed, "pub const ")) |var_name| {
                    try globals_in_file.append(.{
                        .name = try allocator.dupe(u8, var_name),
                        .var_type = .pub_const,
                    });
                }
            }
        }

        // Special handling for build.zig files - rewrite paths
        if (is_build_file) {
            var modified_line = false;
            var line_copy = try allocator.dupe(u8, line);
            defer allocator.free(line_copy);

            // Handle b.path() calls - prepend "../" to relative paths
            if (std.mem.indexOf(u8, line_copy, "b.path(\"")) |path_start| {
                var pos = path_start;
                while (std.mem.indexOf(u8, line_copy[pos..], "b.path(\"")) |next_path| {
                    pos = pos + next_path;
                    const after_path = line_copy[pos + 8 ..];
                    if (std.mem.indexOf(u8, after_path, "\"")) |quote_end| {
                        const path = after_path[0..quote_end];
                        // If it's a relative path (not absolute), prepend ../
                        if (!std.mem.startsWith(u8, path, "/") and !std.mem.startsWith(u8, path, "../")) {
                            var new_line = std.ArrayList(u8).init(allocator);
                            defer new_line.deinit();
                            try new_line.appendSlice(line_copy[0 .. pos + 8]);
                            try new_line.appendSlice("../");
                            try new_line.appendSlice(line_copy[pos + 8 ..]);
                            allocator.free(line_copy);
                            line_copy = try new_line.toOwnedSlice();
                            modified_line = true;
                            pos = pos + 8 + 3 + quote_end + 1; // Skip past this occurrence
                        } else {
                            pos = pos + 8 + quote_end + 1;
                        }
                    } else {
                        break;
                    }
                }
            }

            if (modified_line) {
                try output.appendSlice(line_copy);
                try output.append('\n');
                continue;
            }
        }

        // Handle imports - rewrite local imports to processed versions
        if (std.mem.indexOf(u8, trimmed, "@import")) |import_start| {
            const after_import = trimmed[import_start + 8 ..];
            if (std.mem.indexOf(u8, after_import, "\"")) |quote_start| {
                const path_start = quote_start + 1;
                if (std.mem.indexOf(u8, after_import[path_start..], "\"")) |path_end| {
                    const import_path = after_import[path_start .. path_start + path_end];

                    // Special handling for build.zig files
                    if (is_build_file and std.mem.endsWith(u8, import_path, ".zig")) {
                        // Don't rewrite imports in build.zig - they should reference the original files
                        try output.appendSlice(line);
                        try output.append('\n');
                        continue;
                    }

                    if (std.mem.endsWith(u8, import_path, ".zig") and
                        !std.mem.startsWith(u8, import_path, "std") and
                        !std.mem.eql(u8, import_path, "debug_runtime.zig"))
                    {
                        try output.appendSlice(line[0 .. import_start + 8 + quote_start + 1]);
                        try output.appendSlice(import_path);
                        try output.appendSlice(after_import[path_start + path_end ..]);
                        try output.append('\n');
                        continue;
                    }
                }
            }
        }

        // Track when we enter any function
        if (std.mem.indexOf(u8, trimmed, "fn ")) |fn_pos| {
            if (fn_pos == 0 or trimmed[fn_pos - 1] == ' ') {
                if (parseFunctionName(trimmed)) |fn_name| {
                    in_function = true;
                    current_function = try allocator.dupe(u8, fn_name);
                    brace_count = 0;
                    vars_in_scope.clearRetainingCapacity();
                }
            }
        }

        // Track braces to know when we exit a function
        if (in_function) {
            for (trimmed) |c| {
                if (c == '{') brace_count += 1;
                if (c == '}') {
                    if (brace_count > 0) brace_count -= 1;
                    if (brace_count == 0) {
                        in_function = false;
                        vars_in_scope.clearRetainingCapacity();
                    }
                }
            }
        }

        // Track indent level
        if (in_function) {
            var spaces: usize = 0;
            for (line) |c| {
                if (c == ' ') spaces += 1 else break;
            }
            indent_level = spaces / 4;
        }

        // Handle step_debug() to enable step mode
        if (std.mem.indexOf(u8, trimmed, "step_debug();")) |_| {
            step_mode_active = true;
            continue;
        }

        // Handle _ = .breakpoint; syntax
        if (std.mem.indexOf(u8, trimmed, "_ = .breakpoint;")) |_| {
            if (needs_debug) {
                try injectBreakpoint(&output, current_function, &vars_in_scope, &globals_in_file, indent_level);
            } else {
                // In non-debug mode, replace with a comment
                try output.appendSlice(line[0 .. line.len - trimmed.len]); // preserve indentation
                try output.appendSlice("// _ = .breakpoint; - disabled in non-debug mode\n");
            }
            continue;
        }

        // Track if we're in a multi-line initializer
        if (std.mem.endsWith(u8, trimmed, "= {") or
            std.mem.endsWith(u8, trimmed, "= .{") or
            std.mem.endsWith(u8, trimmed, "= struct {") or
            std.mem.indexOf(u8, trimmed, "struct {") != null or
            (std.mem.endsWith(u8, trimmed, "{") and std.mem.indexOf(u8, trimmed, "]") != null))
        {
            in_initializer = true;
        }
        if (in_initializer and (std.mem.indexOf(u8, trimmed, "};") != null or std.mem.indexOf(u8, trimmed, "},") != null)) {
            in_initializer = false;
        }

        // Inject step debugging
        if (needs_debug and in_function and !in_initializer and shouldInjectStep(trimmed)) {
            try injectStepDebugBefore(&output, current_function, trimmed, line_number, &vars_in_scope, &globals_in_file, indent_level);
        }

        // Check if this is a discard of a tracked variable
        var is_tracked_discard = false;
        if (std.mem.startsWith(u8, trimmed, "_ = ")) {
            const discarded_var = std.mem.trim(u8, trimmed[4..], " ;");

            // Check if this variable is being tracked locally
            for (vars_in_scope.items) |v| {
                if (std.mem.eql(u8, v, discarded_var)) {
                    is_tracked_discard = true;
                    break;
                }
            }
            // Also check globals
            if (!is_tracked_discard) {
                for (globals_in_file.items) |g| {
                    if (std.mem.eql(u8, g.name, discarded_var)) {
                        is_tracked_discard = true;
                        break;
                    }
                }
            }
        }

        // Copy the original line UNLESS it's a discard of a tracked variable
        if (!is_tracked_discard) {
            try output.appendSlice(line);
            try output.append('\n');
        }

        // Track variables AFTER the line is output
        if (in_function and brace_count == 1 and (std.mem.startsWith(u8, trimmed, "var ") or std.mem.startsWith(u8, trimmed, "const "))) {
            if (parseVarName(trimmed)) |var_name| {
                try vars_in_scope.append(try allocator.dupe(u8, var_name));
            }
        }
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = output_file,
        .data = output.items,
    });

    if (enable_step) {
        std.debug.print("Preprocessed {s} -> {s} (step mode enabled, {} globals found)\n", .{ input_file, output_file, globals_in_file.items.len });
    } else {
        std.debug.print("Preprocessed {s} -> {s} ({} globals found)\n", .{ input_file, output_file, globals_in_file.items.len });
    }
}

fn shouldInjectStep(line: []const u8) bool {
    if (line.len == 0) return false;
    if (std.mem.startsWith(u8, line, "}")) return false;
    if (std.mem.eql(u8, line, "{")) return false;
    if (std.mem.startsWith(u8, line, "//")) return false;
    if (std.mem.eql(u8, line, "else")) return false;
    if (std.mem.startsWith(u8, line, "return")) return false;
    if (std.mem.indexOf(u8, line, "fn ") != null) return false;
    if (std.mem.startsWith(u8, line, ".{")) return false;
    if (std.mem.startsWith(u8, line, ".[")) return false;
    if (std.mem.startsWith(u8, line, ".")) return false;
    if (std.mem.endsWith(u8, line, ",")) return false;
    return true;
}

fn injectBreakpoint(
    output: *std.ArrayList(u8),
    function_name: []const u8,
    vars_in_scope: *std.ArrayList([]const u8),
    globals: *std.ArrayList(GlobalVar),
    indent_level: usize,
) !void {
    const indent = "    " ** 16;
    const actual_indent = indent[0..(indent_level * 4)];

    try output.appendSlice(actual_indent);
    try output.appendSlice("{\n");

    // Build variable names - just the names, no annotations
    try output.appendSlice(actual_indent);
    try output.appendSlice("    const var_names = [_][]const u8{");

    // Local variables
    for (vars_in_scope.items, 0..) |v, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.writer().print("\"{s}\"", .{v});
    }

    // Global variables - just names
    if (vars_in_scope.items.len > 0 and globals.items.len > 0) {
        try output.appendSlice(", ");
    }
    for (globals.items, 0..) |g, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.writer().print("\"{s}\"", .{g.name});
    }
    try output.appendSlice("};\n");

    // Build variable values
    try output.appendSlice(actual_indent);
    try output.appendSlice("    const var_values = .{");

    // Local values
    for (vars_in_scope.items, 0..) |v, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.appendSlice(v);
    }

    // Global values
    if (vars_in_scope.items.len > 0 and globals.items.len > 0) {
        try output.appendSlice(", ");
    }
    for (globals.items, 0..) |g, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.appendSlice(g.name);
    }
    try output.appendSlice("};\n");

    try output.appendSlice(actual_indent);
    try output.writer().print("    zdb.handleBreakpoint(\"{s}\", &var_names, var_values);\n", .{function_name});

    try output.appendSlice(actual_indent);
    try output.appendSlice("}\n");
}

fn injectStepDebugBefore(
    output: *std.ArrayList(u8),
    function_name: []const u8,
    next_line: []const u8,
    line_number: usize,
    vars_in_scope: *std.ArrayList([]const u8),
    globals: *std.ArrayList(GlobalVar),
    indent_level: usize,
) !void {
    const indent = "    " ** 16;
    const actual_indent = indent[0..(indent_level * 4)];

    try output.appendSlice(actual_indent);
    try output.appendSlice("{\n");

    // Build variable info - just names
    try output.appendSlice(actual_indent);
    try output.appendSlice("    const var_names = [_][]const u8{");

    for (vars_in_scope.items, 0..) |v, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.writer().print("\"{s}\"", .{v});
    }

    if (vars_in_scope.items.len > 0 and globals.items.len > 0) {
        try output.appendSlice(", ");
    }

    for (globals.items, 0..) |g, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.writer().print("\"{s}\"", .{g.name});
    }
    try output.appendSlice("};\n");

    try output.appendSlice(actual_indent);
    try output.appendSlice("    const var_values = .{");

    for (vars_in_scope.items, 0..) |v, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.appendSlice(v);
    }

    if (vars_in_scope.items.len > 0 and globals.items.len > 0) {
        try output.appendSlice(", ");
    }

    for (globals.items, 0..) |g, i| {
        if (i > 0) try output.appendSlice(", ");
        try output.appendSlice(g.name);
    }
    try output.appendSlice("};\n");

    // Call handleStepBefore
    try output.appendSlice(actual_indent);
    try output.appendSlice("    zdb.handleStepBefore(\"");
    try output.appendSlice(function_name);
    try output.appendSlice("\", \"");

    // Escape special characters
    for (next_line) |c| {
        switch (c) {
            '"' => try output.appendSlice("\\\""),
            '\\' => try output.appendSlice("\\\\"),
            '\n' => try output.appendSlice("\\n"),
            '\r' => try output.appendSlice("\\r"),
            '\t' => try output.appendSlice("\\t"),
            else => try output.append(c),
        }
    }

    try output.writer().print("\", {}, &var_names, var_values);\n", .{line_number});

    try output.appendSlice(actual_indent);
    try output.appendSlice("}\n");
}

fn parseVarName(line: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeAny(u8, line, " :=");
    _ = tokens.next(); // skip var/const
    return tokens.next();
}

fn parseVarNameFrom(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, line, prefix)) {
        const after_prefix = line[prefix.len..];
        var tokens = std.mem.tokenizeAny(u8, after_prefix, " :=");
        return tokens.next();
    }
    return null;
}

fn parseFunctionName(line: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, line, "fn ")) |fn_pos| {
        const after_fn = line[fn_pos + 3 ..];
        if (std.mem.indexOf(u8, after_fn, "(")) |paren_pos| {
            const name = std.mem.trim(u8, after_fn[0..paren_pos], " ");
            return name;
        }
    }
    return null;
}
