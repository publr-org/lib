const std = @import("std");
const helper = @import("helper.zig");

test "replay survives rebuild consumption, rejects open transactions and excludes rollback" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 0, .replay_max = 2 });
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
