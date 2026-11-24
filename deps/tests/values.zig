//! §9 Values kept fresh — `note(value, keys, made)`, `fresh(value, asked)`.
const std = @import("std");
const helper = @import("helper.zig");

test "9.1 a value never noted is not fresh" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.2 a noted value stays fresh until one of its keys changes" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    const at = try world.index.revision();
    try world.index.note("computed:line/1/price", &.{ "internal:shop/product/7", "internal:tax/rate" }, .{ .at = at });
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
    try world.index.invalidate(&.{"internal:shop/product/8"}, 0);
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
    try world.index.invalidate(&.{"internal:tax/rate"}, 1);
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.3 a change made while the work ran leaves it stale" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    const at = try world.index.revision();
    try world.index.invalidate(&.{"internal:shop/product/7"}, 0);
    try world.index.note("computed:line/1/price", &.{"internal:shop/product/7"}, .{ .at = at });
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.4 noting again replaces what it read and when" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.note("computed:line/1/price", &.{"internal:shop/product/7"}, .{ .at = try world.index.revision() });
    try world.index.invalidate(&.{"internal:shop/product/7"}, 0);
    try world.index.note("computed:line/1/price", &.{"internal:shop/product/9"}, .{ .at = try world.index.revision() });
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
    try world.index.invalidate(&.{"internal:shop/product/7"}, 1);
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.5 a value noted before the oldest revision kept is not fresh" {
    var world: helper.World = undefined;
    try world.open(.{
        .replay_max = 2,
    });
    defer world.close();
    try world.index.note("computed:line/1/price", &.{"internal:shop/product/7"}, .{ .at = try world.index.revision() });
    try world.index.invalidate(&.{"internal:other/a"}, 0);
    try world.index.invalidate(&.{"internal:other/b"}, 1);
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
    try world.index.invalidate(&.{"internal:other/c"}, 2);
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.6 values are not artifacts: no plan names them, affected never does" {
    var world: helper.World = undefined;
    try world.open(.{
        .quiet_ms = 0,
    });
    defer world.close();
    try world.index.note("computed:line/1/price", &.{"internal:tax/rate"}, .{ .at = try world.index.revision() });
    try world.index.record("/cart", &.{"internal:tax/rate"});
    try world.expect_affected(&.{"internal:tax/rate"}, &.{"/cart"});
    try world.index.invalidate(&.{"internal:tax/rate"}, 0);
    const plan = try world.flush(1);
    try std.testing.expectEqual(@as(usize, 1), plan.len);
    try std.testing.expectEqualStrings("/cart", plan[0]);
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.7 a forgotten value is not fresh and reads nothing" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.note("computed:line/1/price", &.{"internal:tax/rate"}, .{ .at = try world.index.revision() });
    try world.index.forget_value("computed:line/1/price");
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.8 a rolled-back note leaves no value" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    var transaction = try world.db.transaction();
    try world.index.note("computed:line/1/price", &.{"internal:tax/rate"}, .{ .at = try world.index.revision() });
    transaction.rollback();
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 0 }));
}

test "9.9 a value's keys, for a build that reads the stored value" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try std.testing.expectEqual(@as(usize, 0), (try world.index.value_keys(world.arena(), "computed:line/1/price")).len);
    try world.index.note("computed:line/1/price", &.{ "internal:tax/rate", "internal:shop/product/7" }, .{ .at = try world.index.revision() });
    const keys = try world.index.value_keys(world.arena(), "computed:line/1/price");
    try std.testing.expectEqual(@as(usize, 2), keys.len);
    try std.testing.expectEqualStrings("internal:shop/product/7", keys[0]);
    try std.testing.expectEqualStrings("internal:tax/rate", keys[1]);
}

test "9.10 a value that holds until a time is not fresh from then" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.note("computed:line/1/price", &.{"internal:sale/7"}, .{
        .at = try world.index.revision(),
        .until_ms = 1_000,
    });
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{ .now_ms = 999 }));
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{ .now_ms = 1_000 }));
}

test "9.11 a value asked for under another stamp is not fresh" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.note("computed:line/1/price", &.{"internal:tax/rate"}, .{
        .at = try world.index.revision(),
        .stamp = 0xffff_ffff_ffff_fff0,
    });
    try std.testing.expect(try world.index.fresh("computed:line/1/price", .{
        .now_ms = 0,
        .stamp = 0xffff_ffff_ffff_fff0,
    }));
    try std.testing.expect(!try world.index.fresh("computed:line/1/price", .{
        .now_ms = 0,
        .stamp = 7,
    }));
}
