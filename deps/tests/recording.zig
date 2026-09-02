//! TESTS.md §2 — `record(artifact, keys)`: an artifact's dependency set is
//! exactly the keys of its last build. Everything is asserted through
//! `affected`.
const std = @import("std");
const helper = @import("helper.zig");

test "2.1 records a set" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{ "entry:1", "entry:2" });
    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
    try world.expect_affected(&.{"entry:2"}, &.{"/a"});
}

test "2.2 replaces, never accumulates" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{ "entry:1", "entry:2" });
    try world.index.record("/a", &.{ "entry:2", "entry:3" });
    try world.expect_affected(&.{"entry:1"}, &.{});
    try world.expect_affected(&.{"entry:3"}, &.{"/a"});
}

test "2.3 empty set is a valid build" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try std.testing.expect(!try world.index.unchanged("/a", "bytes"));
    try world.index.record("/a", &.{});
    try world.expect_affected(&.{"entry:1"}, &.{});
    // The artifact still exists: its hash survived the empty recording (5.7).
    try std.testing.expect(try world.index.unchanged("/a", "bytes"));
}

test "2.4 duplicate keys in one call collapse" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{ "entry:1", "entry:1" });
    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
}

test "2.5 artifacts are independent" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/b", &.{"entry:1"});
    try world.expect_affected(&.{"entry:1"}, &.{ "/a", "/b" });
    try world.index.record("/b", &.{"entry:2"});
    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
}

test "2.6 a page and an island are peers" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/posts/hello", &.{"entry:7"});
    try world.index.record("island:latest", &.{"type:post"});
    try world.expect_affected(&.{"type:post"}, &.{"island:latest"});
}

test "2.7 recording is transactional with the caller" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});

    var transaction = try world.db.transaction();
    try world.index.record("/a", &.{"entry:2"});
    transaction.rollback();

    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
    try world.expect_affected(&.{"entry:2"}, &.{});
}

test "2.8 a replaced set is atomic under failure" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});

    const too_long = "x" ** 1025;
    try std.testing.expectError(error.NameTooLong, world.index.record("/a", &.{ "entry:2", too_long }));
    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
    try world.expect_affected(&.{"entry:2"}, &.{});
}

test "2.9 forget an artifact" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try std.testing.expect(!try world.index.unchanged("/a", "bytes"));
    try world.index.forget("/a");
    try world.expect_affected(&.{"entry:1"}, &.{});
    try std.testing.expect(!try world.index.unchanged("/a", "bytes")); // its hash is gone (5.5)
}
