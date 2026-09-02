//! TESTS.md §3 — the queue: coalescing, the quiet period, sealing at
//! capacity, FIFO batches, persistence.
const std = @import("std");
const helper = @import("helper.zig");

test "3.1 nothing pending, nothing planned" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expectEqual(@as(usize, 0), (try world.flush(10_000)).len);
}

test "3.2 one change, one plan" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);
    const artifacts = try world.flush(1000);
    try std.testing.expectEqual(@as(usize, 1), artifacts.len);
    try std.testing.expectEqualStrings("/a", artifacts[0]);
}

test "3.3 repeated key coalesces" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    for (0..10) |_| try world.index.invalidate(&.{"entry:1"}, 0);
    const batch = (try world.index.take(world.arena(), 1000)).?;
    try std.testing.expectEqual(@as(usize, 1), batch.keys.len);
    try std.testing.expectEqualStrings("entry:1", batch.keys[0]);
    try world.index.done(batch);
}

test "3.4 different keys, same artifact, once" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{ "entry:1", "entry:2" });
    try world.index.invalidate(&.{"entry:1"}, 0);
    try world.index.invalidate(&.{"entry:2"}, 0);
    const artifacts = try world.flush(1000);
    try std.testing.expectEqual(@as(usize, 1), artifacts.len);
}

test "3.5 quiet period gates the flush" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 2000 });
    defer world.close();
    try world.index.invalidate(&.{"entry:1"}, 0);
    try std.testing.expect(!try world.index.due(1000));
    try std.testing.expect(try world.index.due(2000));
    try world.index.invalidate(&.{"entry:1"}, 1500);
    try std.testing.expect(!try world.index.due(2000));
    try std.testing.expect(try world.index.due(3500));
}

test "3.6 flush empties the queue" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);
    try std.testing.expectEqual(@as(usize, 1), (try world.flush(1000)).len);
    try std.testing.expectEqual(@as(usize, 0), (try world.flush(2000)).len);
}

test "3.7 keys arriving during a flush land in the next batch" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/b", &.{"entry:2"});
    try world.index.invalidate(&.{"entry:1"}, 0);

    const first = (try world.index.take(world.arena(), 1000)).?;
    // Mid-execution, a new change arrives: it must join the collecting
    // queue, not the batch being executed.
    try world.index.invalidate(&.{"entry:2"}, 1100);
    const first_plan = try world.index.plan(world.arena(), first);
    try std.testing.expectEqual(@as(usize, 1), first_plan.len);
    try std.testing.expectEqualStrings("/a", first_plan[0]);
    try world.index.done(first);

    const second_plan = try world.flush(2100);
    try std.testing.expectEqual(@as(usize, 1), second_plan.len);
    try std.testing.expectEqualStrings("/b", second_plan[0]);
}

test "3.8 cap seals a batch at once" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 60_000, .queue_cap = 3 });
    defer world.close();
    try world.index.invalidate(&.{ "entry:1", "entry:2", "entry:3" }, 0);
    // Sealed the moment the 3rd landed: due regardless of quiet.
    try std.testing.expect(try world.index.due(1));
    try world.index.invalidate(&.{"entry:4"}, 2);

    const batch = (try world.index.take(world.arena(), 3)).?;
    try std.testing.expectEqual(@as(usize, 3), batch.keys.len);
    try world.index.done(batch);
    // The 4th key is collecting, with its own quiet period.
    try std.testing.expect(!try world.index.due(3));
    try std.testing.expect(try world.index.due(60_002));
}

test "3.9 cap counts distinct keys" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 60_000, .queue_cap = 3 });
    defer world.close();
    for (0..5) |_| try world.index.invalidate(&.{"entry:1"}, 0);
    try std.testing.expect(!try world.index.due(1));
}

test "3.9a sealed batches queue in order" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 60_000, .queue_cap = 2 });
    defer world.close();
    try world.index.invalidate(&.{ "entry:1", "entry:2" }, 0);
    try world.index.invalidate(&.{ "entry:3", "entry:4" }, 1);
    try world.index.invalidate(&.{ "entry:5", "entry:6" }, 2);

    const first = (try world.index.take(world.arena(), 3)).?;
    try std.testing.expectEqualStrings("entry:1", first.keys[0]);
    try world.index.done(first);
    const second = (try world.index.take(world.arena(), 3)).?;
    try std.testing.expectEqualStrings("entry:3", second.keys[0]);
    try world.index.done(second);
    const third = (try world.index.take(world.arena(), 3)).?;
    try std.testing.expectEqualStrings("entry:5", third.keys[0]);
    try std.testing.expect(first.no < second.no and second.no < third.no);
    try world.index.done(third);
}

test "3.10 a plan is last-state" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);
    // A rebuild elsewhere changed what /a depends on before the flush.
    try world.index.record("/a", &.{"entry:2"});
    try std.testing.expectEqual(@as(usize, 0), (try world.flush(1000)).len);
}

test "3.11 pending survives the process" {
    var world: helper.World = undefined;
    try world.open(.{ .quiet_ms = 1000 });
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.invalidate(&.{"entry:1"}, 0);

    // The same database bytes in a fresh process: serialize, reopen, deserialize.
    const image = try world.db.serialize(world.arena());
    var second: helper.World = undefined;
    try second.open(.{ .quiet_ms = 1000 });
    defer second.close();
    try second.db.deserialize(image);

    const artifacts = try second.flush(1000);
    try std.testing.expectEqual(@as(usize, 1), artifacts.len);
    try std.testing.expectEqualStrings("/a", artifacts[0]);
}
