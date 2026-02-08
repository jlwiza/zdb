const std = @import("std");

pub const Timer = struct {
    start_ns: u64,

    pub fn start() !Timer {
        return .{ .start_ns = try nowNs() };
    }

    pub fn read(self: *const Timer) u64 {
        // elapsed nanoseconds
        const now = nowNs() catch return 0;
        return now - self.start_ns;
    }

    fn nowNs() !u64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) {
            return error.Unexpected;
        }
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
            @as(u64, @intCast(ts.nsec));
    }
};
