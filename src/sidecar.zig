const std = @import("std");
const abi = @import("sidecar_abi.zig");
const options = @import("zdb_sidecar_options");

export fn zdb_sidecar_abi_version() callconv(.c) u32 {
    return abi.version;
}

export fn zdb_sidecar_on_pause(event: *const abi.PauseEvent, reply: *abi.PauseReply) callconv(.c) void {
    const function_name = event.function_name_ptr[0..event.function_name_len];
    var copied_value: ?u32 = null;
    var mutated_from: ?u32 = null;
    if (event.locals_ptr) |locals_ptr| {
        for (locals_ptr[0..event.locals_len]) |local| {
            const name = local.name_ptr[0..local.name_len];
            const type_name = local.type_name_ptr[0..local.type_name_len];
            if (local.bytes_len != @sizeOf(u32) or !std.mem.eql(u8, type_name, "u32")) continue;
            const value: *u32 = @ptrCast(@alignCast(local.bytes_ptr));
            if (local.storage == .copied_value and std.mem.eql(u8, name, options.read_u32_name)) {
                copied_value = value.*;
            }
            if (local.storage == .mutable_pointer and std.mem.eql(u8, name, options.mutate_u32_name)) {
                mutated_from = value.*;
                value.* = options.mutate_u32_value;
            }
        }
    }
    const message = std.fmt.bufPrint(
        &reply.message,
        "generation {d} handling {s} breakpoint #{d}; copied={?d}; mutable={?d}->{d}",
        .{ options.generation, function_name, event.breakpoint_count, copied_value, mutated_from, options.mutate_u32_value },
    ) catch "sidecar reply was too long";
    reply.generation = options.generation;
    reply.message_len = message.len;
    reply.outcome = @enumFromInt(options.outcome);
}
