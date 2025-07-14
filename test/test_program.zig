// test/test_program.zig - Enhanced with globals and more!
// debug the test with zig build test-debug
// run the test with zig build test-debug
const std = @import("std");
const game = @import("game.zig");
const combat = @import("systems/combat.zig");

// Global variables
var global_counter: i32 = 0;
pub var global_name: []const u8 = "GlobalPlayer";
const GLOBAL_CONSTANT: i32 = 42;

// Thread-local variable
threadlocal var tls_request_id: u64 = 0;
threadlocal var tls_buffer: [256]u8 = undefined;

// Compile-time constants
const MAX_PLAYERS = 100;
const VERSION = "1.2.3";
const DEBUG_MODE = true;

// Comptime computed value
const MAGIC_NUMBER = blk: {
    var x: u32 = 1;
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        x = x * 2;
    }
    break :blk x;
};

const Player = struct {
    name: []const u8,
    health: i32,
    position: struct { x: f32, y: f32 },
    items: []const u8,

    // Static constant in struct
    const MAX_HEALTH = 200;
    const DEFAULT_NAME = "Unknown";
};

pub fn main() !void {
    // Modify some globals
    global_counter += 1;
    tls_request_id = 12345;

    var x: i32 = 42;
    var y: i32 = 99;
    const name: []const u8 = "Jon";
    _ = name;
    const numbers = [_]i32{ 1, 2, 3, 4, 5 };
    _ = numbers;
    const matrix = [_][3]f32{
        .{ 1.0, 2.0, 3.0 },
        .{ 4.0, 5.0, 6.0 },
    };
    _ = matrix;

    // Test large array
    var big_numbers: [100]i32 = undefined;
    for (&big_numbers, 0..) |*n, i| {
        n.* = @intCast(i * 10);
    }

    // Test slice
    const slice_numbers = big_numbers[25..35];
    _ = slice_numbers;

    var player = Player{
        .name = "Hero",
        .health = 100,
        .position = .{ .x = 10.5, .y = 20.3 },
        .items = "sword",
    };

    var players = [_]Player{
        .{
            .name = "Warrior",
            .health = 120,
            .position = .{ .x = 0.0, .y = 0.0 },
            .items = "axe",
        },
        .{
            .name = "Mage",
            .health = 80,
            .position = .{ .x = 5.0, .y = 10.0 },
            .items = "staff",
        },
        .{
            .name = "Rogue",
            .health = 90,
            .position = .{ .x = -3.0, .y = 7.5 },
            .items = "daggers",
        },
        .{
            .name = "Water",
            .health = 10,
            .position = .{ .x = 0.0, .y = 0.0 },
            .items = "ase",
        },
    };

    // Test with many players
    var many_players: [20]Player = undefined;
    for (&many_players, 0..) |*p, i| {
        p.* = Player{
            .name = if (i % 2 == 0) "Fighter" else "Healer",
            .health = 100 - @as(i32, @intCast(i * 5)),
            .position = .{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) },
            .items = if (i % 3 == 0) "sword" else if (i % 3 == 1) "shield" else "potion",
        };
    }

    std.debug.print("Starting program...\n", .{});

    x += 10;
    y *= 2;
    player.health -= 10;
    players[1].health -= 20; // Mage takes damage

    // Update globals
    global_counter += 5;
    tls_request_id += 1;

    _ = .breakpoint;

    // Test the multi-file functionality
    const damage = combat.calculateDamage(player.health, 15);
    std.debug.print("Damage calculated: {}\n", .{damage});

    game.updatePlayer(&player, damage);

    x += 5;
    std.debug.print("Final: x = {}, y = {}\n", .{ x, y });
    std.debug.print("Global counter: {}\n", .{global_counter});
}
