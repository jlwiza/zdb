const std = @import("std");
const test_fixture = @import("test_fixture");

// Globals of various kinds
var global_counter: usize = 0;
const MAGIC: u32 = 0xDEADBEEF;
threadlocal var thread_state: u32 = 0;

const Entity = struct {
    id: u32,
    name: []const u8,
    position: struct { x: f32, y: f32 },
    health: i16,
    flags: packed struct {
        alive: bool,
        visible: bool,
        hostile: bool,
        _padding: u5 = 0,
    },
};

const State = enum { idle, running, jumping, attacking, dead };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Basic types
    var x: i32 = 41;
    var y: f64 = 3.14159;
    var flag: bool = true;
    var state: State = .idle;

    _ = .breakpoint; // Check basic types + globals

    // Strings and slices
    const name: []const u8 = "zdb stress test";
    _ = name;
    var mutable_buf: [32]u8 = undefined;
    @memcpy(mutable_buf[0..4], "test");
    const slice = mutable_buf[0..4];
    _ = slice;

    _ = .breakpoint; // Check strings

    // Fixed arrays
    const small_array = [_]i32{ 1, 2, 3, 4, 5 };
    _ = small_array;
    var big_array: [100]i32 = undefined;
    for (&big_array, 0..) |*val, i| {
        val.* = @intCast(i * i);
    }

    _ = .breakpoint; // Check arrays - test paging on big_array

    // Array of structs (table display)
    var entities: [25]Entity = undefined;
    for (&entities, 0..) |*e, i| {
        e.* = .{
            .id = @intCast(i),
            .name = if (i % 3 == 0) "goblin" else if (i % 3 == 1) "skeleton" else "dragon",
            .position = .{ .x = @floatFromInt(i * 10), .y = @floatFromInt(i * 5) },
            .health = @intCast(100 - i * 3),
            .flags = .{ .alive = i < 20, .visible = true, .hostile = i % 2 == 0 },
        };
    }

    _ = .breakpoint; // Check struct array table display

    // Dynamic allocations
    var dynamic_list: std.ArrayList(i32) = .empty;
    defer dynamic_list.deinit(allocator);
    for (0..50) |i| {
        try dynamic_list.append(allocator, @intCast(i * 2));
    }

    var hash_map = std.StringHashMap(i32).init(allocator);
    defer hash_map.deinit();
    try hash_map.put("alpha", 1);
    try hash_map.put("beta", 2);
    try hash_map.put("gamma", 3);

    _ = .breakpoint; // Check stdlib containers

    // Nested structs
    const complex = struct {
        level1: struct {
            level2: struct {
                level3: struct {
                    value: i32,
                    data: [4]u8,
                },
                count: usize,
            },
            name: []const u8,
        },
        active: bool,
    }{
        .level1 = .{
            .level2 = .{
                .level3 = .{
                    .value = 42,
                    .data = .{ 0xDE, 0xAD, 0xBE, 0xEF },
                },
                .count = 999,
            },
            .name = "nested monster",
        },
        .active = true,
    };
    _ = complex;
    _ = .breakpoint; // Check deeply nested struct

    // Optionals and error unions
    var maybe_value: ?i32 = null;
    var maybe_entity: ?Entity = null;

    _ = .breakpoint; // Check nulls

    maybe_value = 123;
    maybe_entity = entities[0];

    _ = .breakpoint; // Check non-null optionals

    // Pointers
    var value_on_stack: i32 = 9999;
    const ptr_to_stack = &value_on_stack;
    const ptr_to_entity = &entities[5];

    _ = .breakpoint; // Check pointers

    // Union
    const Result = union(enum) {
        ok: i32,
        err: []const u8,
    };
    var result: Result = .{ .ok = 42 };
    _ = .breakpoint; // Check tagged union (ok)

    result = .{ .err = "something went wrong" };
    _ = .breakpoint; // Check tagged union (err)

    // Loop with changing state - good for step mode
    state = .running;
    for (0..5) |i| {
        global_counter += 1;
        x += @intCast(i);
        if (i == 2) {
            state = .jumping;
        }
        _ = .breakpoint; // Watch values change each iteration
    }

    // Call into another function with its own scope
    const result_val = try computeStuff(allocator, &entities);
    _ = .breakpoint; // Check after function return

    // Mutate through pointers
    ptr_to_stack.* = 1234;
    ptr_to_entity.health = 0;
    ptr_to_entity.flags.alive = false;

    _ = .breakpoint; // Check mutations through pointers

    // Final state
    y = @floatFromInt(result_val);
    flag = false;
    state = .dead;

    _ = .breakpoint; // Final state check

    std.debug.print("Stress test complete. Final x={}, counter={}\n", .{ x, global_counter });
    try test_fixture.bufferedPrint();
}

fn computeStuff(allocator: std.mem.Allocator, entities: []Entity) !i32 {
    var local_sum: i32 = 0;
    var temp_list: std.ArrayList(i32) = .empty;
    defer temp_list.deinit(allocator);

    _ = .breakpoint; // Inside function - check local scope vs outer

    for (entities) |e| {
        if (e.flags.alive) {
            local_sum += e.health;
            try temp_list.append(allocator, e.health);
        }
    }

    _ = .breakpoint; // After loop in function

    global_counter += 100; // Mutate global from inner function

    return local_sum;
}

// Recursive function to test call stack
fn fibonacci(n: u32, depth: u32) u64 {
    var result: u64 = 0;

    if (depth < 3) {
        _ = .breakpoint; // Only break on shallow calls to not go insane
    }

    if (n <= 1) {
        result = n;
    } else {
        result = fibonacci(n - 1, depth + 1) + fibonacci(n - 2, depth + 1);
    }

    return result;
}
