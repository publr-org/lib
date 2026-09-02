//! What every integration test needs: an index over a fresh `:memory:`
//! database, and an arena.
const std = @import("std");
const sqlite = @import("publr_sqlite");
const deps = @import("publr_deps");

pub const World = struct {
    runtime: sqlite.Runtime,
    db: sqlite.Database,
    index: deps.Index,
    arena_state: std.heap.ArenaAllocator,

    /// Initializes in place: `index` holds a pointer to `db`, and `db` to
    /// `runtime`, so the struct must never be moved after this.
    pub fn open(world: *World, options: deps.Options) !void {
        world.runtime = try sqlite.Runtime.init(.{});
        errdefer world.runtime.deinit();
        world.db = try sqlite.Database.open(&world.runtime, ":memory:", .{});
        errdefer world.db.close();
        world.index = try deps.Index.open(&world.db, options);
        world.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    }

    pub fn close(world: *World) void {
        world.arena_state.deinit();
        world.db.close();
        world.runtime.deinit();
    }

    pub fn arena(world: *World) std.mem.Allocator {
        return world.arena_state.allocator();
    }

    /// `affected` as a comparison against an expected sorted list.
    pub fn expect_affected(world: *World, keys: []const []const u8, expected: []const []const u8) !void {
        const artifacts = try world.index.affected(world.arena(), keys);
        try std.testing.expectEqual(expected.len, artifacts.len);
        for (expected, artifacts) |want, got| {
            try std.testing.expectEqualStrings(want, got);
        }
    }

    /// The matrix's "flush": take the due batch, plan it, mark it done.
    /// Returns the plan (empty when nothing was due).
    pub fn flush(world: *World, now_ms: i64) ![]const []const u8 {
        const batch = (try world.index.take(world.arena(), now_ms)) orelse return &.{};
        const artifacts = try world.index.plan(world.arena(), batch);
        try world.index.done(batch);
        return artifacts;
    }
};
