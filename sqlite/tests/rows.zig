//! Row consumption: `read` (structs in column order, every field type, arena
//! ownership) and `read_int` (scalar aggregates).
const std = @import("std");
const sqlite = @import("publr_sqlite");

test "read maps rows into structs in column order" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL, views INTEGER)");
    try db.exec("INSERT INTO t (name, views) VALUES ('alpha', 3), ('beta', NULL)");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Row = struct { id: i64, name: []const u8, views: i64 };

    var select = try db.prepare("SELECT id, name, views FROM t ORDER BY id");
    defer select.finalize();

    try std.testing.expect(try select.step());
    const first = try select.read(Row, arena);
    try std.testing.expectEqual(@as(i64, 1), first.id);
    try std.testing.expectEqualStrings("alpha", first.name);
    try std.testing.expectEqual(@as(i64, 3), first.views);

    try std.testing.expect(try select.step());
    const second = try select.read(Row, arena);
    try std.testing.expectEqualStrings("beta", second.name);
    try std.testing.expectEqual(@as(i64, 0), second.views);

    try std.testing.expectEqual(false, try select.step());
}

test "read: f64, bool, Blob, and the optional forms see NULL as null" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (score REAL, live INTEGER, raw BLOB, note TEXT, n INTEGER)");
    try db.exec("INSERT INTO t VALUES (1.5, 1, x'0001ff', 'hi', 9), (NULL, 0, NULL, NULL, NULL)");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Row = struct {
        score: f64,
        live: bool,
        raw: sqlite.Blob,
        note: ?[]const u8,
        n: ?i64,
        score_optional: ?f64,
        raw_optional: ?sqlite.Blob,
    };

    var select = try db.prepare(
        "SELECT score, live, raw, note, n, score, raw FROM t ORDER BY live DESC",
    );
    defer select.finalize();

    try std.testing.expect(try select.step());
    const first = try select.read(Row, arena);
    try std.testing.expectEqual(@as(f64, 1.5), first.score);
    try std.testing.expect(first.live);
    try std.testing.expectEqualSlices(u8, "\x00\x01\xff", first.raw.bytes);
    try std.testing.expectEqualStrings("hi", first.note.?);
    try std.testing.expectEqual(@as(i64, 9), first.n.?);
    try std.testing.expectEqual(@as(f64, 1.5), first.score_optional.?);
    try std.testing.expectEqualSlices(u8, "\x00\x01\xff", first.raw_optional.?.bytes);

    try std.testing.expect(try select.step());
    const second = try select.read(Row, arena);
    try std.testing.expectEqual(@as(f64, 0), second.score);
    try std.testing.expect(!second.live);
    try std.testing.expectEqual(@as(usize, 0), second.raw.bytes.len);
    try std.testing.expect(second.note == null);
    try std.testing.expect(second.n == null);
    try std.testing.expect(second.score_optional == null);
    try std.testing.expect(second.raw_optional == null);
}

test "read: Any carries the storage class of each cell" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, value ANY)");
    try db.exec("INSERT INTO t (value) VALUES (7), (2.5), ('text'), (x'ab'), (NULL)");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Row = struct { value: sqlite.Any };

    var select = try db.prepare("SELECT value FROM t ORDER BY id");
    defer select.finalize();

    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(i64, 7), (try select.read(Row, arena)).value.integer);
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(@as(f64, 2.5), (try select.read(Row, arena)).value.real);
    try std.testing.expect(try select.step());
    try std.testing.expectEqualStrings("text", (try select.read(Row, arena)).value.text);
    try std.testing.expect(try select.step());
    try std.testing.expectEqualSlices(u8, "\xab", (try select.read(Row, arena)).value.blob);
    try std.testing.expect(try select.step());
    try std.testing.expectEqual(sqlite.Any.null, (try select.read(Row, arena)).value);
    try std.testing.expectEqual(false, try select.step());
}

test "read output owns its text beyond finalize" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (name TEXT NOT NULL)");
    try db.exec("INSERT INTO t (name) VALUES ('survives')");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Row = struct { name: []const u8 };

    var select = try db.prepare("SELECT name FROM t");
    _ = try select.step();
    const row_value = try select.read(Row, arena_state.allocator());
    select.finalize();

    try std.testing.expectEqualStrings("survives", row_value.name);
}

test "read_int returns the scalar aggregate" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)");
    try db.exec("INSERT INTO t (n) VALUES (1), (2), (3)");

    var count_rows = try db.prepare("SELECT COUNT(*) FROM t");
    defer count_rows.finalize();
    _ = try count_rows.step();

    try std.testing.expectEqual(@as(i64, 3), count_rows.read_int());
}
