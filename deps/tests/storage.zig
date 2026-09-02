//! TESTS.md §6 — storage shape and cost: idempotent schema, a guest in the
//! caller's database, indexed lookups, name limits, exact byte comparison.
const std = @import("std");
const sqlite = @import("publr_sqlite");
const deps = @import("publr_deps");
const helper = @import("helper.zig");

test "6.1 schema is created on open, idempotently" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    _ = try deps.Index.open(&world.db, .{});
    try world.index.record("/a", &.{"entry:1"});
    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
}

test "6.2 opens inside the caller's database, caller's tables untouched" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.db.exec("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)");
    try world.db.exec("INSERT INTO posts (title) VALUES ('hello')");
    _ = try deps.Index.open(&world.db, .{});

    var count = try world.db.prepare("SELECT COUNT(*) FROM posts");
    defer count.finalize();
    _ = try count.step();
    try std.testing.expectEqual(@as(i64, 1), count.read_int());
}

test "6.3 lookup is indexed, never a scan" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    var explain = try world.db.prepare("EXPLAIN QUERY PLAN SELECT artifact FROM deps_edges WHERE key = 'entry:1'");
    defer explain.finalize();
    var used_index = false;
    while (try explain.step()) {
        const row = try explain.read(struct { id: i64, parent: i64, aux: i64, detail: []const u8 }, world.arena());
        if (std.mem.indexOf(u8, row.detail, "deps_edges_by_key") != null) used_index = true;
        try std.testing.expect(std.mem.indexOf(u8, row.detail, "SCAN deps_edges") == null);
    }
    try std.testing.expect(used_index);
}

test "6.4 replace is indexed" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    var explain = try world.db.prepare("EXPLAIN QUERY PLAN DELETE FROM deps_edges WHERE artifact = '/a'");
    defer explain.finalize();
    while (try explain.step()) {
        const row = try explain.read(struct { id: i64, parent: i64, aux: i64, detail: []const u8 }, world.arena());
        try std.testing.expect(std.mem.indexOf(u8, row.detail, "SCAN deps_edges") == null);
    }
}

test "6.5 key and artifact length limits" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    const too_long = "k" ** 1025;
    try std.testing.expectError(error.NameTooLong, world.index.record(too_long, &.{"entry:1"}));
    try std.testing.expectError(error.NameTooLong, world.index.record("/a", &.{too_long}));
    try std.testing.expectError(error.NameTooLong, world.index.invalidate(&.{too_long}, 0));
    try std.testing.expectError(error.NameTooLong, world.index.affected(world.arena(), &.{too_long}));
    try std.testing.expectError(error.NameTooLong, world.index.unchanged(too_long, "x"));
    try world.expect_affected(&.{"entry:1"}, &.{}); // nothing was written
}

test "6.6 names are bytes, compared exactly" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/A", &.{"entry:1"});
    try world.index.record("/a", &.{"entry:1"});
    try world.expect_affected(&.{"entry:1"}, &.{ "/A", "/a" });
    try world.expect_affected(&.{"ENTRY:1"}, &.{});
}
