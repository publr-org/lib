//! The core binding surface: open, exec, prepare, bind, step, exec, reset,
//! changes — happy paths and every failure path of the error set.
const std = @import("std");
const sqlite = @import("publr_sqlite");

test "open, exec, prepare, bind, step, read back" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)");

    var insert = try db.prepare("INSERT INTO t (name) VALUES (?1)");
    try insert.bind_text(1, "alpha");
    try std.testing.expectEqual(false, try insert.step());
    insert.finalize();

    try std.testing.expectEqual(@as(u32, 1), db.changes());
    try std.testing.expectEqual(@as(i64, 1), db.last_insert_rowid());

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Row = struct { id: i64, name: []const u8 };

    var select = try db.prepare("SELECT id, name FROM t");
    defer select.finalize();
    try std.testing.expect(try select.step());
    const first = try select.read(Row, arena_state.allocator());
    try std.testing.expectEqual(@as(i64, 1), first.id);
    try std.testing.expectEqualStrings("alpha", first.name);
    try std.testing.expectEqual(false, try select.step());
}

test "exec on a statement runs a write to completion; reset runs it again" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER NOT NULL)");

    var insert = try db.prepare("INSERT INTO t (n) VALUES (?1)");
    defer insert.finalize();

    for ([_]i64{ 1, 2, 3 }) |number| {
        insert.reset();
        try insert.bind_int(1, number);
        try insert.exec();
    }

    var sum = try db.prepare("SELECT sum(n) FROM t");
    defer sum.finalize();
    _ = try sum.step();
    try std.testing.expectEqual(@as(i64, 6), sum.read_int());
}

test "reset clears bindings: an unbound parameter is NULL again" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)");

    var insert = try db.prepare("INSERT INTO t (n) VALUES (?1)");
    defer insert.finalize();
    try insert.bind_int(1, 7);
    try insert.exec();
    insert.reset();
    try insert.exec();

    var nulls = try db.prepare("SELECT count(*) FROM t WHERE n IS NULL");
    defer nulls.finalize();
    _ = try nulls.step();
    try std.testing.expectEqual(@as(i64, 1), nulls.read_int());
}

test "violated unique constraint surfaces as error.Constraint" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (name TEXT NOT NULL UNIQUE)");
    try db.exec("INSERT INTO t (name) VALUES ('taken')");

    var insert = try db.prepare("INSERT INTO t (name) VALUES (?1)");
    defer insert.finalize();
    try insert.bind_text(1, "taken");
    try std.testing.expectError(error.Constraint, insert.step());
}

test "exec surfaces bad SQL as error.Sqlite" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try std.testing.expectError(error.Sqlite, db.exec("NOT REAL SQL"));
}

test "prepare surfaces an unknown table as error.Sqlite" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try std.testing.expectError(error.Sqlite, db.prepare("SELECT id FROM missing"));
}

test "prepare_dynamic takes runtime SQL and the same placeholders" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (n INTEGER)");
    try db.exec("INSERT INTO t (n) VALUES (1), (2), (3), (4)");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var sql: std.Io.Writer.Allocating = .init(arena_state.allocator());
    try sql.writer.writeAll("SELECT count(*) FROM t WHERE n IN (");

    const wanted = [_]i64{ 2, 4, 9 };

    for (wanted, 1..) |_, index| {
        const separator: []const u8 = if (index == 1) "" else ", ";
        try sql.writer.print("{s}?{d}", .{ separator, index });
    }

    try sql.writer.writeAll(")");

    var select = try db.prepare_dynamic(sql.written());
    defer select.finalize();

    for (wanted, 1..) |number, index| {
        try select.bind_int(@intCast(index), number);
    }

    _ = try select.step();
    try std.testing.expectEqual(@as(i64, 2), select.read_int());
    try std.testing.expectError(error.Sqlite, db.prepare_dynamic("SELECT FROM nothing"));
}

test "open fails on a path whose directory does not exist" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    try std.testing.expectError(
        error.Sqlite,
        sqlite.Database.open(&runtime, "/publr-sqlite-no-such-directory/x.db", .{}),
    );
    try std.testing.expectEqual(@as(u32, 0), runtime.open_count);
}

test "bind_int round-trips through a WHERE clause" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)");
    try db.exec("INSERT INTO t (id, name) VALUES (1, 'one'), (2, 'two')");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Row = struct { name: []const u8 };

    var select = try db.prepare("SELECT name FROM t WHERE id = ?1");
    defer select.finalize();
    try select.bind_int(1, 2);

    try std.testing.expect(try select.step());
    const found = try select.read(Row, arena_state.allocator());
    try std.testing.expectEqualStrings("two", found.name);
    try std.testing.expectEqual(false, try select.step());
}

test "bind_real, bind_null, bind_optional_text and bind_blob store what they say" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (score REAL, note TEXT, tag TEXT, raw BLOB)");

    var insert = try db.prepare("INSERT INTO t (score, note, tag, raw) VALUES (?1, ?2, ?3, ?4)");
    defer insert.finalize();
    try insert.bind_real(1, 1.5);
    try insert.bind_null(2);
    try insert.bind_optional_text(3, "tagged");
    try insert.bind_blob(4, "\x00\x01\x02");
    try insert.exec();

    insert.reset();
    try insert.bind_real(1, 2.5);
    try insert.bind_optional_text(2, "noted");
    try insert.bind_optional_text(3, null);
    try insert.bind_blob(4, "");
    try insert.exec();

    var types = try db.prepare(
        "SELECT typeof(score) || ',' || typeof(note) || ',' || typeof(tag) || ',' || typeof(raw)" ++
            " FROM t ORDER BY score",
    );
    defer types.finalize();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Row = struct { types: []const u8 };

    try std.testing.expect(try types.step());
    const first = try types.read(Row, arena_state.allocator());
    try std.testing.expectEqualStrings("real,null,text,blob", first.types);
    try std.testing.expect(try types.step());
    const second = try types.read(Row, arena_state.allocator());
    try std.testing.expectEqualStrings("real,text,null,blob", second.types);
}

test "bound text is copied: the source buffer may die before step" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (name TEXT NOT NULL)");

    var insert = try db.prepare("INSERT INTO t (name) VALUES (?1)");
    var buffer = [_]u8{ 'k', 'e', 'p', 't' };
    try insert.bind_text(1, &buffer);
    @memset(&buffer, 'X');
    try insert.exec();
    insert.finalize();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Row = struct { name: []const u8 };

    var select = try db.prepare("SELECT name FROM t");
    defer select.finalize();
    try std.testing.expect(try select.step());
    const found = try select.read(Row, arena_state.allocator());
    try std.testing.expectEqualStrings("kept", found.name);
}

test "empty text binds and reads back as empty" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (name TEXT NOT NULL)");

    var insert = try db.prepare("INSERT INTO t (name) VALUES (?1)");
    try insert.bind_text(1, "");
    try insert.exec();
    insert.finalize();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Row = struct { name: []const u8 };

    var select = try db.prepare("SELECT name FROM t");
    defer select.finalize();
    try std.testing.expect(try select.step());
    const found = try select.read(Row, arena_state.allocator());
    try std.testing.expectEqualStrings("", found.name);
}

test "fts5 is compiled in" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE VIRTUAL TABLE f USING fts5(body)");
    try db.exec("INSERT INTO f (body) VALUES ('publr keeps content small')");

    var select = try db.prepare("SELECT count(*) FROM f WHERE f MATCH 'content'");
    defer select.finalize();
    _ = try select.step();
    try std.testing.expectEqual(@as(i64, 1), select.read_int());
}
