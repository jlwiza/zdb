const std = @import("std");
const combat = @import("systems/combat.zig");

pub fn updatePlayer(player: anytype, damage: i32) void {
    const new_health = player.health - damage;

    _ = .breakpoint;

    player.health = new_health;
    std.debug.print("Player {s} health: {} -> {}\n", .{ player.name, player.health + damage, player.health });
}

pub fn healPlayer(player: anytype, amount: i32) void {
    const old_health = player.health;
    player.health += amount;
    if (player.health > 100) {
        player.health = 100;
    }
    std.debug.print("Healed {} from {} to {}\n", .{ player.name, old_health, player.health });
}
