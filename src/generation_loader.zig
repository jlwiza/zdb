//! Shared, generation-safe dynamic-library snapshots.
//!
//! Build outputs are never opened directly: macOS caches images by path, and
//! a build may replace a file while a host still executes the prior image.
//! Each open therefore copies the completed build output to a unique path.
//! The caller validates symbols before replacing its current `Generation`.

const std = @import("std");

pub const Generation = struct {
    dl: std.DynLib,
    snapshot_path: []u8,

    pub fn deinit(self: *Generation, allocator: std.mem.Allocator, io: std.Io) void {
        self.dl.close();
        std.Io.Dir.cwd().deleteFile(io, self.snapshot_path) catch {};
        allocator.free(self.snapshot_path);
        self.* = undefined;
    }
};

/// Snapshot one completed Zig build output to a unique path and open it.
/// Ownership of the returned handle and path transfers to the caller.
pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    build_path: []const u8,
    live_dir: []const u8,
    serial: u64,
) !Generation {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, live_dir);
    const snapshot_path = try std.fmt.allocPrint(allocator, "{s}/{s}.{d}", .{
        live_dir,
        std.fs.path.basename(build_path),
        serial,
    });
    errdefer allocator.free(snapshot_path);
    errdefer cwd.deleteFile(io, snapshot_path) catch {};

    try cwd.copyFile(build_path, cwd, snapshot_path, io, .{});
    return .{
        .dl = try std.DynLib.open(snapshot_path),
        .snapshot_path = snapshot_path,
    };
}
