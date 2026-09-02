//! The scoped-transaction contract: commit persists, rollback discards,
//! nesting via savepoints, and the defer-rollback shape.
const std = @import("std");
const sqlite = @import("publr_sqlite");

const Database = sqlite.Database;

test "commit persists, rollback discards, nesting via savepoints" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)");

    var outer = try db.transaction();
    try db.exec("INSERT INTO t (n) VALUES (1)");

    var inner = try db.transaction();
    try db.exec("INSERT INTO t (n) VALUES (2)");
    inner.rollback();

    var inner_two = try db.transaction();
    try db.exec("INSERT INTO t (n) VALUES (3)");
    try inner_two.commit();

    try outer.commit();
    try std.testing.expectEqual(@as(u32, 0), db.transaction_depth);
    try expect_count(&db, 2);

    var rolled = try db.transaction();
    try db.exec("INSERT INTO t (n) VALUES (4)");
    rolled.rollback();
    try expect_count(&db, 2);
}

test "defer rollback after commit is a no-op" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)");

    {
        var transaction = try db.transaction();
        defer transaction.rollback();

        try db.exec("INSERT INTO t (n) VALUES (1)");
        try transaction.commit();
    }

    try std.testing.expectEqual(@as(u32, 0), db.transaction_depth);
    try expect_count(&db, 1);
}

test "outer rollback discards an inner committed savepoint" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)");

    var outer = try db.transaction();
    var inner = try db.transaction();
    try db.exec("INSERT INTO t (n) VALUES (1)");
    try inner.commit();
    outer.rollback();

    try expect_count(&db, 0);
}

test "constraint inside a transaction rolls the whole write back" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (name TEXT NOT NULL UNIQUE)");
    try db.exec("INSERT INTO t (name) VALUES ('taken')");

    const failed = write_pair(&db);
    try std.testing.expectError(error.Constraint, failed);
    try std.testing.expectEqual(@as(u32, 0), db.transaction_depth);
    try expect_count(&db, 1);
}

fn write_pair(db: *Database) sqlite.Error!void {
    var transaction = try db.transaction();
    defer transaction.rollback();

    try db.exec("INSERT INTO t (name) VALUES ('fresh')");
    try db.exec("INSERT INTO t (name) VALUES ('taken')");

    try transaction.commit();
}

fn expect_count(db: *Database, expected: i64) !void {
    std.debug.assert(expected >= 0);
    std.debug.assert(db.transaction_depth == 0);

    var select = try db.prepare("SELECT count(*) FROM t");
    defer select.finalize();

    try std.testing.expect(try select.step());
    try std.testing.expectEqual(expected, select.read_int());
}
