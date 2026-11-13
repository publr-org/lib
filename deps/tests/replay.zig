const std = @import("std");
const helper = @import("helper.zig");

test "replay survives rebuild consumption, rejects open transactions and excludes rollback" {
    var world: helper.World = undefined;
    try world.open(.{
        .quiet_ms = 0,
        .replay_max = 2,
    });
    defer world.close();
    var transaction = try world.db.transaction();
    try world.index.invalidate(&.{"record:rolled-back"}, 0);
    try std.testing.expectError(error.UncommittedRead, world.index.changes_since(world.arena(), 0));
    transaction.rollback();
    try std.testing.expectEqual(@as(u64, 0), try world.index.revision());
    try world.index.invalidate(&.{"record:one"}, 0);
    const batch = (try world.index.take(world.arena(), 1)).?;
    try world.index.done(batch);
    const changes = try world.index.changes_since(world.arena(), 0);
    try std.testing.expectEqual(@as(u64, 1), changes.revision);
    try std.testing.expectEqualStrings("record:one", changes.keys[0]);
    try world.index.invalidate(&.{"record:two"}, 2);
    try world.index.invalidate(&.{"record:three"}, 3);
    try std.testing.expect((try world.index.changes_since(world.arena(), 0)).reset);
    try std.testing.expect(!(try world.index.changes_since(world.arena(), 1)).reset);
}

test "what was published: a changed hash, a forgotten artifact, a name given; replayed by revision" {
    var world: helper.World = undefined;
    try world.open(.{
        .quiet_ms = 0,
        .replay_max = 3,
    });
    defer world.close();
    try std.testing.expectEqual(@as(u64, 0), try world.index.published_revision());
    try std.testing.expect(!try world.index.unchanged("www:/a", "one"));
    try std.testing.expect(try world.index.unchanged("www:/a", "one"));
    try std.testing.expectEqual(@as(u64, 1), try world.index.published_revision());
    try world.index.forget("www:/a");
    try world.index.publish(&.{"www"});
    const all = try world.index.published_since(world.arena(), 0);
    try std.testing.expectEqual(@as(u64, 3), all.revision);
    try std.testing.expect(!all.reset);
    try std.testing.expectEqual(@as(usize, 2), all.names.len);
    try std.testing.expectEqualStrings("www", all.names[0]);
    try std.testing.expectEqualStrings("www:/a", all.names[1]);
    const latest = try world.index.published_since(world.arena(), 2);
    try std.testing.expectEqual(@as(usize, 1), latest.names.len);
    try std.testing.expectEqual(@as(usize, 0), (try world.index.published_since(world.arena(), 3)).names.len);
    try world.index.publish(&.{"x"});
    try std.testing.expect((try world.index.published_since(world.arena(), 0)).reset);
    try std.testing.expect((try world.index.published_since(world.arena(), 9)).reset);
    try std.testing.expectEqual(@as(u64, 0), (try world.index.changes_since(world.arena(), 0)).revision);
}
