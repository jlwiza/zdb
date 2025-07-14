const std = @import("std");

pub fn calculateDamage(defender_health: i32, base_damage: i32) i32 {
    const armor_reduction = @divFloor(defender_health, 10);
    var final_damage = base_damage - armor_reduction;

    _ = .breakpoint;

    if (final_damage < 1) {
        final_damage = 1; // Always do at least 1 damage
    }

    return final_damage;
}

pub fn criticalHit(damage: i32) i32 {
    return damage * 2;
}
