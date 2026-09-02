//! TESTS.md §4 (fan-out) and §5 (no-op rebuilds).
const std = @import("std");
const helper = @import("helper.zig");

fn record_many(world: *helper.World, comptime prefix: []const u8, count: usize, key: []const u8) !void {
    var buffer: [64]u8 = undefined;
    for (0..count) |i| {
        try world.index.record(try std.fmt.bufPrint(&buffer, prefix ++ "{d}", .{i}), &.{key});
    }
}

test "4.1 under the limit" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000, .fanout_max = 100 });
    defer world.close();
    try record_many(&world, "/a", 99, "entry:1");
    try world.index.invalidate(&.{"entry:1"}, 0);
    try std.testing.expectEqual(@as(usize, 99), (try world.flush(1000)).len);
}

test "4.2 at the limit" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000, .fanout_max = 100 });
    defer world.close();
    try record_many(&world, "/a", 100, "entry:1");
    try world.index.invalidate(&.{"entry:1"}, 0);
    try std.testing.expectEqual(@as(usize, 100), (try world.flush(1000)).len);
}

test "4.3 over the limit refuses and keeps the batch" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000, .fanout_max = 100 });
    defer world.close();
    try record_many(&world, "/a", 101, "entry:1");
    try world.index.invalidate(&.{"entry:1"}, 0);

    const batch = (try world.index.take(world.arena(), 1000)).?;
    try std.testing.expectError(error.FanOutExceeded, world.index.plan(world.arena(), batch));
    // Not `done`: the batch is re-taken — the caller decides what changes.
    const again = (try world.index.take(world.arena(), 2000)).?;
    try std.testing.expectEqual(batch.no, again.no);
    try std.testing.expectEqual(@as(usize, 1), again.keys.len);
}

test "4.4 the limit is per batch, across keys" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000, .fanout_max = 100 });
    defer world.close();
    try record_many(&world, "/a", 60, "entry:1");
    try record_many(&world, "/b", 60, "entry:2");
    try world.index.invalidate(&.{ "entry:1", "entry:2" }, 0);
    const batch = (try world.index.take(world.arena(), 1000)).?;
    try std.testing.expectError(error.FanOutExceeded, world.index.plan(world.arena(), batch));
}

test "4.5 a key with no dependents never trips it" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000, .fanout_max = 1 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:999"}, 0);
    try std.testing.expectEqual(@as(usize, 0), (try world.flush(1000)).len);
}

test "5.1-5.3 first build is a change, same bytes again, different bytes" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expect(!try world.index.unchanged("/a", "x"));
    try std.testing.expect(try world.index.unchanged("/a", "x"));
    try std.testing.expect(!try world.index.unchanged("/a", "y"));
    try std.testing.expect(try world.index.unchanged("/a", "y"));
}

test "5.4 hash is per artifact" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expect(!try world.index.unchanged("/a", "x"));
    try std.testing.expect(!try world.index.unchanged("/b", "x"));
}

test "5.5 forget clears the hash" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expect(!try world.index.unchanged("/a", "x"));
    try world.index.forget("/a");
    try std.testing.expect(!try world.index.unchanged("/a", "x"));
}

test "5.6 the hash is of the bytes, not the length" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expect(!try world.index.unchanged("/a", "ab"));
    try std.testing.expect(!try world.index.unchanged("/a", "ba"));
}

test "5.7 record and hash are independent" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expect(!try world.index.unchanged("/a", "x"));
    try world.index.record("/a", &.{"entry:1"});
    try std.testing.expect(try world.index.unchanged("/a", "x")); // record never touched the hash
    try world.expect_affected(&.{"entry:1"}, &.{"/a"}); // unchanged never touched the set
}
