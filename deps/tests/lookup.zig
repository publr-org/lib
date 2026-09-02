//! TESTS.md §1 — `affected(keys) → artifacts`: the question the index
//! exists to answer.
const std = @import("std");
const helper = @import("helper.zig");

test "1.1 direct dependents" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/b", &.{"entry:2"});
    try world.expect_affected(&.{"entry:1"}, &.{"/a"});
}

test "1.2 several keys, union, each artifact once" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/b", &.{ "entry:1", "entry:2" });
    try world.index.record("/c", &.{"entry:2"});
    try world.expect_affected(&.{ "entry:1", "entry:2" }, &.{ "/a", "/b", "/c" });
}

test "1.3 unknown key" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"entry:1"});
    try world.expect_affected(&.{"entry:999"}, &.{});
}

test "1.4 145 dependents, exact" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    var buffer: [64]u8 = undefined;
    for (0..145) |i| {
        try world.index.record(try std.fmt.bufPrint(&buffer, "/posts/a{d}", .{i}), &.{"author:3"});
    }
    for (0..55) |i| {
        try world.index.record(try std.fmt.bufPrint(&buffer, "/posts/b{d}", .{i}), &.{"author:4"});
    }
    const artifacts = try world.index.affected(world.arena(), &.{"author:3"});
    try std.testing.expectEqual(@as(usize, 145), artifacts.len);
    for (artifacts) |artifact| {
        try std.testing.expect(std.mem.startsWith(u8, artifact, "/posts/a"));
    }
}

test "1.5 nested references recorded flat" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/posts/hello", &.{ "entry:7", "entry:3", "entry:1", "entry:9" });
    try world.expect_affected(&.{"entry:1"}, &.{"/posts/hello"});
}

test "1.6 a field key is narrower than its entry key" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"field:3:name"});
    try world.index.record("/b", &.{"field:3:bio"});
    try world.expect_affected(&.{"field:3:bio"}, &.{"/b"});
}

test "1.7 type key covers open result sets" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/posts", &.{"type:post"});
    try world.index.record("/posts/hello", &.{"entry:7"});
    try world.expect_affected(&.{"type:post"}, &.{"/posts"});
}

test "1.8 tag key is just a key" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/a", &.{"tag:nav"});
    try world.expect_affected(&.{"tag:nav"}, &.{"/a"});
}

test "1.9 order is stable" {
    var world: helper.World = undefined;
    try world.open(.{});
    defer world.close();
    try world.index.record("/b", &.{"entry:1"});
    try world.index.record("/a", &.{"entry:1"});
    try world.index.record("/c", &.{"entry:1"});
    try world.expect_affected(&.{"entry:1"}, &.{ "/a", "/b", "/c" });
}
