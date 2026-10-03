//! The process-level contract: the fixed heap, a second process on the same
//! file (busy timeout), read-only connections, and database images.
const std = @import("std");
const sqlite = @import("publr_sqlite");

const heap_bytes: u32 = 16 << 20;

test "fixed heap: configured at init, exhaustion is an error, not a crash" {
    const heap = try std.testing.allocator.alignedAlloc(u8, .@"8", heap_bytes);
    defer std.testing.allocator.free(heap);

    var runtime = try sqlite.Runtime.init(.{ .heap = heap });
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE big (data BLOB)");

    var insert = try db.prepare("INSERT INTO big (data) VALUES (zeroblob(?1))");
    defer insert.finalize();

    try insert.bind_int(1, @intCast(heap_bytes * 2));
    try std.testing.expectError(error.OutOfMemory, insert.step());

    try db.exec("INSERT INTO big (data) VALUES (x'00')");
    try std.testing.expectEqual(@as(u32, 1), db.changes());
}

test "open_count follows open and close" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var first = try sqlite.Database.open(&runtime, ":memory:", .{});
    var second = try sqlite.Database.open(&runtime, ":memory:", .{});
    try std.testing.expectEqual(@as(u32, 2), runtime.open_count);

    second.close();
    try std.testing.expectEqual(@as(u32, 1), runtime.open_count);
    first.close();
    try std.testing.expectEqual(@as(u32, 0), runtime.open_count);
}

test "a second connection on the file waits busy_timeout_ms, then error.Busy" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [128]u8 = undefined;
    const path = try temporary_path(&path_buffer, &temporary, "shared.db");

    var writer = try sqlite.Database.open(&runtime, path, .{ .busy_timeout_ms = 10 });
    defer writer.close();

    var waiter = try sqlite.Database.open(&runtime, path, .{ .busy_timeout_ms = 10 });
    defer waiter.close();

    try writer.exec("CREATE TABLE t (n INTEGER)");

    var held = try writer.transaction();
    defer held.rollback();

    try writer.exec("INSERT INTO t (n) VALUES (1)");
    try std.testing.expectError(error.Busy, waiter.exec("INSERT INTO t (n) VALUES (2)"));
    try std.testing.expectError(error.Busy, waiter.transaction());
    try std.testing.expectEqual(@as(u32, 0), waiter.transaction_depth);
}

test "read_only: writes fail with error.ReadOnly, a missing file is an error" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var path_buffer: [128]u8 = undefined;
    const path = try temporary_path(&path_buffer, &temporary, "ro.db");

    try std.testing.expectError(
        error.Sqlite,
        sqlite.Database.open(&runtime, path, .{ .read_only = true }),
    );

    var rw = try sqlite.Database.open(&runtime, path, .{});
    try rw.exec("CREATE TABLE t (n INTEGER)");
    rw.close();

    var ro = try sqlite.Database.open(&runtime, path, .{ .read_only = true });
    defer ro.close();

    try std.testing.expectError(error.ReadOnly, ro.exec("INSERT INTO t (n) VALUES (1)"));

    var count_rows = try ro.prepare("SELECT count(*) FROM t");
    defer count_rows.finalize();
    _ = try count_rows.step();
    try std.testing.expectEqual(@as(i64, 0), count_rows.read_int());
}

test "serialize and deserialize round-trip an in-memory database" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var source = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer source.close();

    try source.exec("CREATE TABLE t (n INTEGER)");
    try source.exec("INSERT INTO t (n) VALUES (7)");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const bytes = try source.serialize(arena_state.allocator());
    try std.testing.expect(bytes.len > 0);

    var copy = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer copy.close();

    try copy.deserialize(bytes);

    var select = try copy.prepare("SELECT n FROM t");
    defer select.finalize();
    _ = try select.step();
    try std.testing.expectEqual(@as(i64, 7), select.read_int());
}

fn temporary_path(
    buffer: []u8,
    temporary: *const std.testing.TmpDir,
    name: []const u8,
) ![:0]u8 {
    return std.fmt.bufPrintZ(buffer, ".zig-cache/tmp/{s}/{s}", .{ &temporary.sub_path, name });
}

test "limit_work stops a statement past its budget, the same way every run" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    const counting = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n " ++
        "WHERE i < 1000000) SELECT count(*) FROM n";

    db.limit_work(10_000);

    var heavy = try db.prepare(counting);
    defer heavy.finalize();

    try std.testing.expectError(error.Interrupted, heavy.step());

    db.limit_work(null);

    var again = try db.prepare(counting);
    defer again.finalize();

    try std.testing.expect(try again.step());

    const Counted = struct { count: i64 };
    const counted = try again.read(Counted, std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 1_000_000), counted.count);
}

test "limit_size stops a value growing past its cap, then lifts" {
    var runtime = try sqlite.Runtime.init(.{});
    defer runtime.deinit();

    var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    defer db.close();

    db.limit_size(1000);

    var big = try db.prepare("SELECT length(zeroblob(5000))");
    defer big.finalize();

    try std.testing.expectError(error.TooBig, big.step());

    db.limit_size(null);

    var again = try db.prepare("SELECT length(zeroblob(5000))");
    defer again.finalize();

    try std.testing.expect(try again.step());
}
