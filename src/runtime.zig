const std = @import("std");
const Timer = @import("util_timer.zig").Timer;
// Global state for debugging
pub var step_mode: bool = false;
// FIXED: Now using a stack of functions instead of single function
pub var step_functions: [32]?[]const u8 = [_]?[]const u8{null} ** 32;
pub var step_function_count: usize = 0;
var watch_expressions: []const WatchExpr = &.{};
var breakpoint_count: usize = 0;
var breakpoint_timer: ?Timer = null;

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

// Check if we should step in the current function
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
    // If we're back in a function that's already on the stack,
    // we must have returned from deeper calls
    var i: usize = 0;
    while (i < step_function_count) : (i += 1) {
        if (step_functions[i]) |sf| {
            if (std.mem.eql(u8, sf, function_name)) {
                // Trim everything after this function
                step_function_count = i + 1;
                return;
            }
        }
    }
}

// Pretty printer for any type
pub fn debugPrint(name: []const u8, value: anytype) void {
    debugPrintWithPage(name, value, 0);
}

pub fn debugPrintWithPage(name: []const u8, value: anytype, page: usize) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    // For arrays, apply paging
    if ((type_info == .array or type_info == .pointer) and
        (type_info == .array or (type_info == .pointer and type_info.pointer.size == .slice)))
    {
        const array_len = if (type_info == .array) value.len else value.len;
        if (array_len > 10) {
            const start = page * 10;
            if (start >= array_len) {
                std.debug.print("{s} = (page {} is out of range, max page is {})\n", .{ name, page, (array_len - 1) / 10 });
                return;
            }
            const end = @min(start + 10, array_len);

            const child_type = if (type_info == .array) type_info.array.child else type_info.pointer.child;
            if (@typeInfo(child_type) == .@"struct") {
                // Struct array - use table format
                std.debug.print("{s} (page {}/{}): ", .{ name, page + 1, (array_len + 9) / 10 });
                debugPrintStructArray(value[start..end], start);
            } else {
                // Simple array - show the page
                std.debug.print("{s}[{}..{}] (page {}/{} of {} items) = ", .{ name, start, end, page + 1, (array_len + 9) / 10, array_len });
                debugPrintValue(value[start..end], 0, false);
                std.debug.print("\n", .{});
            }
            return;
        }
    }

    // Default printing for small arrays or non-arrays
    std.debug.print("{s} = ", .{name});
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

        // Check if all elements are the same struct type
        if (type_info == .array) {
            if (@typeInfo(type_info.array.child) == .@"struct") {
                debugPrintStructArray(value[actual_start..actual_end], actual_start);
                return;
            }
        }

        // Default array printing
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

    switch (type_info) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                std.debug.print("\"{s}\"", .{value});
            } else if (ptr.size == .slice) {
                // Check if it's an array of structs for table format
                if (@typeInfo(ptr.child) == .@"struct" and value.len > 0) {
                    debugPrintStructArray(value, 0);
                } else {
                    debugPrintSimpleArray(value, indent, compact);
                }
            } else {
                // Just use Zig's any formatter for other pointers
                std.debug.print("{any}", .{value});
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                std.debug.print("\"{s}\"", .{value});
            } else if (@typeInfo(arr.child) == .@"struct" and arr.len > 0) {
                debugPrintStructArray(&value, 0);
            } else {
                debugPrintSimpleArray(&value, indent, compact);
            }
        },
        .@"struct" => {
            debugPrintStruct(value, indent, compact);
        },
        .@"enum" => std.debug.print(".{s}", .{@tagName(value)}),
        .optional => {
            if (value) |v| {
                debugPrintValue(v, indent, compact);
            } else {
                std.debug.print("null", .{});
            }
        },
        .int => std.debug.print("{}", .{value}),
        .float => std.debug.print("{d:.1}", .{value}),
        .bool => std.debug.print("{}", .{value}),
        .@"fn" => std.debug.print("<fn>", .{}), // ADD THIS
        else => std.debug.print("{any}", .{value}),
    }
}

fn debugPrintSimpleArray(value: anytype, indent: usize, compact: bool) void {
    _ = compact;
    const len = value.len;

    // For simple types, use compact inline format
    if (len <= 20) {
        std.debug.print("[ ", .{});
        for (value, 0..) |item, i| {
            if (i > 0) std.debug.print(", ", .{});
            debugPrintValue(item, indent, true);
        }
        std.debug.print(" ]", .{});
    } else {
        // Show first 10, then ellipsis
        std.debug.print("[ ", .{});
        for (0..@min(10, len)) |i| {
            if (i > 0) std.debug.print(", ", .{});
            debugPrintValue(value[i], indent, true);
        }
        std.debug.print(", ... ({} items total) ]\n", .{len});
        std.debug.print("Use 'n' for next page or name[10..20] to see more", .{});
    }
}

fn debugPrintStruct(value: anytype, indent: usize, compact: bool) void {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    const fields = type_info.@"struct".fields;

    if (fields.len == 0) {
        std.debug.print("{{}}", .{});
        return;
    }

    const type_name = @typeName(T);
    const is_anon = std.mem.indexOf(u8, type_name, "__struct_") != null;

    // For position-like structs, use compact (x, y) format
    if (is_anon and fields.len == 2 and
        @hasField(T, "x") and @hasField(T, "y"))
    {
        const x_type = @TypeOf(@field(value, "x"));
        const y_type = @TypeOf(@field(value, "y"));
        if (@typeInfo(x_type) == .float and @typeInfo(y_type) == .float) {
            std.debug.print("({d:.1}, {d:.1})", .{ @field(value, "x"), @field(value, "y") });
            return;
        }
    }

    if (compact or fields.len <= 4) {
        if (!is_anon) {
            if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_pos| {
                std.debug.print("{s}{{ ", .{type_name[dot_pos + 1 ..]});
            } else {
                std.debug.print("{s}{{ ", .{type_name});
            }
        } else {
            std.debug.print("{{ ", .{});
        }

        inline for (fields, 0..) |field, i| {
            if (i > 0) std.debug.print(", ", .{});
            std.debug.print(".{s} = ", .{field.name});
            debugPrintValue(@field(value, field.name), indent + 1, true);
        }
        std.debug.print(" }}", .{});
    } else {
        // Multi-line format for complex structs
        if (!is_anon) {
            if (std.mem.lastIndexOf(u8, type_name, ".")) |dot_pos| {
                std.debug.print("{s}{{\n", .{type_name[dot_pos + 1 ..]});
            } else {
                std.debug.print("{s}{{\n", .{type_name});
            }
        } else {
            std.debug.print("{{\n", .{});
        }

        inline for (fields) |field| {
            for (0..((indent + 1) * 2)) |_| std.debug.print(" ", .{});
            std.debug.print(".{s} = ", .{field.name});
            debugPrintValue(@field(value, field.name), indent + 1, false);
            std.debug.print("\n", .{});
        }
        for (0..(indent * 2)) |_| std.debug.print(" ", .{});
        std.debug.print("}}", .{});
    }
}

fn debugPrintStructArray(items: anytype, start_index: usize) void {
    if (items.len == 0) {
        std.debug.print("[]\n", .{});
        return;
    }

    const T = @TypeOf(items[0]);
    const fields = @typeInfo(T).@"struct".fields;

    // Determine how many items to show (max 10 for table format)
    const items_to_show = @min(items.len, 10);
    const show_items = items[0..items_to_show];

    std.debug.print("[\n", .{});

    // Print header with indices
    std.debug.print("            ", .{});
    for (show_items, 0..) |_, i| {
        std.debug.print("[{d:<2}]            ", .{start_index + i});
    }
    std.debug.print("\n", .{});

    // Print each field as a row
    inline for (fields) |field| {
        std.debug.print("  {s:<9} ", .{field.name ++ ":"});
        for (show_items) |item| {
            const val = @field(item, field.name);
            const T2 = @TypeOf(val);

            if (T2 == []const u8 or T2 == []u8) {
                std.debug.print("{s:<15} ", .{val});
            } else if (@typeInfo(T2) == .@"struct") {
                // Special handling for position
                const info = @typeInfo(T2);
                if (info.@"struct".fields.len == 2) {
                    const f1 = info.@"struct".fields[0];
                    const f2 = info.@"struct".fields[1];
                    if (std.mem.eql(u8, f1.name, "x") and std.mem.eql(u8, f2.name, "y")) {
                        std.debug.print("({d:.1}, {d:.1})     ", .{ @field(val, "x"), @field(val, "y") });
                        continue;
                    }
                }
                debugPrintValue(val, 0, true);
                std.debug.print(" ", .{});
            } else if (@typeInfo(T2) == .int) {
                std.debug.print("{d:<15} ", .{val});
            } else if (@typeInfo(T2) == .float) {
                std.debug.print("{d:<15.1} ", .{val});
            } else {
                debugPrintValue(val, 0, true);
                std.debug.print(" ", .{});
            }
        }
        std.debug.print("\n", .{});
    }

    if (items.len > 10) {
        std.debug.print("  ... ({} items total. Use name[10..20] for next page)\n", .{items.len});
    }

    std.debug.print("]\n", .{});
}

// Main breakpoint handler
pub fn handleBreakpoint(
    function_name: []const u8,
    var_names: []const []const u8,
    var_values: anytype,
) void {
    breakpoint_count += 1;

    // Time tracking
    if (breakpoint_timer) |last| {
        const elapsed_ns = last.read();
        std.debug.print("\n[Time since last breakpoint: {}ms]\n", .{
            elapsed_ns / std.time.ns_per_ms,
        });
    }
    breakpoint_timer = Timer.start() catch null;
    // Check if we're in a build.zig context
    const is_build_context = std.mem.eql(u8, function_name, "build");

    std.debug.print("\n=== BREAKPOINT #{} in {s}() ===\n", .{ breakpoint_count, function_name });

    if (is_build_context) {
        std.debug.print("(Build.zig detected", .{});
        std.debug.print("For interactive debugging, run: zig build <args> 2>&1 | cat\n", .{});
        // Print all variables automatically
        // inline for (var_values, 0..) |value, idx| {
        //     const name = var_names[idx];
        //     std.debug.print("  ", .{});
        //     debugPrint(name, value);
        // }
        // std.debug.print("\nContinuing...\n", .{});
        // return; // Skip interactive loop
    }

    // Normal interactive mode for non-build contexts
    const io = runtime.io();
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, stdin_buf[0..]);
    const r = &stdin_reader.interface;
    var last_array_name: []const u8 = "";
    var last_array_page: usize = 0;

    std.debug.print("Variables: ", .{});
    for (var_names, 0..) |v, i| {
        if (i > 0) std.debug.print(", ", .{});
        std.debug.print("{s}", .{v});
    }
    std.debug.print("\n", .{});
    std.debug.print("Commands: <var>, print <var>, n/p (next/prev page), s (step mode), c (continue)\n\n", .{});

    while (true) {
        std.debug.print("> ", .{});
        // Add debug output to see what's happening
        const maybe_line = r.takeDelimiter('\n') catch |err| {
            std.debug.print("Error reading stdin: {}\n", .{err});
            break;
        };

        if (maybe_line) |input_including_nl| {
            const cmd = std.mem.trim(u8, input_including_nl, " \t\r\n");

            if (std.mem.eql(u8, cmd, "c")) {
                break;
            } else if (std.mem.eql(u8, cmd, "s")) {
                step_mode = true;
                addFunctionToStepStack(function_name);
                std.debug.print("Step mode enabled for {s}().\n", .{function_name});
                break;
            }

            // Handle variable inspection
            var handled = false;
            inline for (var_values, 0..) |value, idx| {
                const name = var_names[idx];

                // Check for exact match
                if (std.mem.eql(u8, cmd, name)) {
                    debugPrint(name, value);
                    last_array_name = name;
                    last_array_page = 0;
                    handled = true;
                    break;
                }

                // Check for "print <var>" format
                if (cmd.len > 6 and std.mem.startsWith(u8, cmd, "print ")) {
                    const var_part = cmd[6..];
                    if (std.mem.eql(u8, var_part, name)) {
                        debugPrint(name, value);
                        last_array_name = name;
                        last_array_page = 0;
                        handled = true;
                        break;
                    }
                }

                // Handle paging
                if ((std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "p")) and
                    std.mem.eql(u8, last_array_name, name))
                {
                    if (std.mem.eql(u8, cmd, "n")) {
                        last_array_page += 1;
                    } else if (last_array_page > 0) {
                        last_array_page -= 1;
                    }
                    debugPrintWithPage(name, value, last_array_page);
                    handled = true;
                    break;
                }

                // Handle range syntax
                if (std.mem.startsWith(u8, cmd, name) and cmd.len > name.len and cmd[name.len] == '[') {
                    const bracket_part = cmd[name.len..];
                    if (std.mem.indexOf(u8, bracket_part, "..")) |dots| {
                        const start_str = bracket_part[1..dots];
                        if (std.mem.indexOf(u8, bracket_part[dots + 2 ..], "]")) |end_bracket| {
                            const end_str = bracket_part[dots + 2 .. dots + 2 + end_bracket];
                            if (std.fmt.parseInt(usize, start_str, 10) catch null) |start| {
                                if (std.fmt.parseInt(usize, end_str, 10) catch null) |end| {
                                    debugPrintRange(name, value, start, end);
                                    handled = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            if (!handled) {
                std.debug.print("Unknown command or variable\n", .{});
            }
        } else break;
    }
}

// Step debugging handler (before line execution)
pub fn handleStepBefore(
    function_name: []const u8,
    next_line: []const u8,
    line_number: usize,
    var_names: []const []const u8,
    var_values: anytype,
) void {
    // Auto-trim stack if we've returned to a function already on it
    autoTrimStepStack(function_name);

    // Check if we should step in this function
    if (!shouldStepInFunction(function_name)) return;

    std.debug.print("\n[{s}:{d}] about to execute: {s}\n", .{ function_name, line_number, next_line });
    std.debug.print("(s=step, c=continue, n=next, v=vars, or variable name)\n", .{});

    const io = runtime.io();
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, stdin_buf[0..]);
    const r = &stdin_reader.interface;

    while (true) {
        std.debug.print("step> ", .{});
        if (r.takeDelimiter('\n') catch null) |input| {
            const cmd = std.mem.trim(u8, input, " \t\r\n");

            if (std.mem.eql(u8, cmd, "s") or cmd.len == 0) {
                // Step to next line
                break;
            } else if (std.mem.eql(u8, cmd, "c")) {
                // Continue without stepping
                step_mode = false;
                step_function_count = 0;
                break;
            } else if (std.mem.eql(u8, cmd, "n")) {
                // Next - step over function calls
                break;
            } else if (std.mem.eql(u8, cmd, "v")) {
                // Show all variables
                std.debug.print("Variables:\n", .{});
                inline for (var_values, 0..) |value, idx| {
                    const name = var_names[idx];
                    std.debug.print("  ", .{});
                    debugPrint(name, value);
                }
            } else {
                // Try to print specific variable
                var found = false;
                inline for (var_values, 0..) |value, idx| {
                    const name = var_names[idx];
                    if (std.mem.eql(u8, cmd, name)) {
                        debugPrint(name, value);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    std.debug.print("Unknown command or variable\n", .{});
                }
            }
        }
    }
}

// Step debugging handler (after line execution)
pub fn handleStep(
    function_name: []const u8,
    executed_line: []const u8,
    line_number: usize,
    var_names: []const []const u8,
    var_values: anytype,
) void {
    // Check runtime step mode and function
    if (!shouldStepInFunction(function_name)) return;

    std.debug.print("\n[{s}:{d}] executed: {s}\n", .{ function_name, line_number, executed_line });
    std.debug.print("(s=step, c=continue, n=next (skip calls), v=vars, or variable name)\n", .{});

    const io = runtime.io();
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(io, stdin_buf[0..]);
    const r = &stdin_reader.interface;

    while (true) {
        std.debug.print("step> ", .{});
        if (r.takeDelimiter('\n') catch null) |input| {
            const cmd = std.mem.trim(u8, input, " \t\r\n");

            if (std.mem.eql(u8, cmd, "s") or cmd.len == 0) {
                // Step to next line
                break;
            } else if (std.mem.eql(u8, cmd, "c")) {
                // Continue without stepping
                step_mode = false;
                step_function_count = 0;
                break;
            } else if (std.mem.eql(u8, cmd, "n")) {
                // Next - step over function calls
                // For now, same as step, but could be enhanced
                break;
            } else if (std.mem.eql(u8, cmd, "v")) {
                // Show all variables
                std.debug.print("Variables:\n", .{});
                inline for (var_values, 0..) |value, idx| {
                    const name = var_names[idx];
                    std.debug.print("  ", .{});
                    debugPrint(name, value);
                }
            } else {
                // Try to print specific variable
                var found = false;
                inline for (var_values, 0..) |value, idx| {
                    const name = var_names[idx];
                    if (std.mem.eql(u8, cmd, name)) {
                        debugPrint(name, value);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    std.debug.print("Unknown command or variable\n", .{});
                }
            }
        }
    }
}

// Watch expression support
pub fn addWatch(name: []const u8, check_fn: *const fn () bool) void {
    // In real implementation, we'd need dynamic allocation
    _ = name;
    _ = check_fn;
    std.debug.print("Watch expressions not yet implemented\n", .{});
}

pub fn checkWatches() void {
    for (watch_expressions) |watch| {
        if (watch.check_fn()) {
            std.debug.print("\n!!! WATCH HIT: {s} !!!\n", .{watch.name});
            // Could trigger a breakpoint here
        }
    }
}
