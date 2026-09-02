//! Scoped transactions over one connection: `db.transaction()` returns a value
//! whose `commit`/`rollback` must be called exactly once — `defer rollback`
//! after a successful `commit` is a safe no-op.
//!
//! So the calling shape is always:
//!
//! ```zig
//! var transaction = try db.transaction();
//! defer transaction.rollback();
//! … writes …
//! try transaction.commit();
//! ```
//!
//! Nesting uses savepoints: an inner `db.transaction()` while one is open
//! joins it, and rolling the inner one back keeps the outer one alive. The outermost
//! level is `BEGIN IMMEDIATE` — with one connection there is nobody to defer
//! the write lock for. A failed rollback panics: the connection would be left
//! inside a transaction nobody owns, and no later query can be trusted.
const std = @import("std");
const lib = @import("lib.zig");

const Database = lib.Database;
const Error = lib.Error;

/// Nesting cap. Hitting its assert means a leaked transaction (begun, never
/// finished), not a legitimate need for nine levels.
pub const depth_max: u32 = 8;

/// A scoped transaction over one connection. Obtained from
/// `Database.transaction`; exactly one of `commit` or `rollback` finishes it,
/// after which the value is inert (`rollback` becomes a no-op) — which is
/// what makes `defer transaction.rollback()` safe on every path, success
/// included.
///
/// Transactions nest by value, not by reference: each `db.transaction()`
/// returns a new `Transaction` controlling only the writes made since that
/// call, and they must finish innermost-first (asserted).
pub const Transaction = struct {
    /// The connection this transaction runs on. Borrowed for the lifetime of
    /// the transaction — it must not outlive the `Database`, which asserts on
    /// `close` that no transaction is still open.
    db: *Database,
    /// This transaction's own nesting level, 1-based: 1 is the outermost
    /// (`BEGIN IMMEDIATE`), deeper levels are savepoints. Finishing asserts
    /// this still equals `db.transaction_depth`, which is what enforces
    /// innermost-first ordering.
    depth: u32,
    /// Set by the first `commit` or `rollback`. Once true the value is inert,
    /// which is what makes the deferred `rollback` after a successful commit
    /// a no-op rather than a double finish.
    finished: bool = false,

    /// Starts a transaction on `db` and returns the value that controls it.
    /// This is the mechanics behind `Database.transaction`, which is the
    /// intended call site.
    ///
    /// Both spellings are the same call:
    ///
    /// ```zig
    /// var transaction = try db.transaction();
    /// var transaction = try Transaction.begin(&db);   // identical
    /// ```
    ///
    /// At depth 0 it issues `BEGIN IMMEDIATE`: the write lock is taken up
    /// front, which on a single-connection database can never wait. Inside
    /// an already-open transaction it issues `SAVEPOINT sp_<depth>` instead,
    /// which is what makes nesting free for callees. Each call bumps
    /// `db.transaction_depth` by one; the matching `commit` or `rollback`
    /// restores it. Fails with `error.Sqlite` if SQLite refuses (already
    /// logged); nesting past `depth_max` asserts.
    pub fn begin(db: *Database) Error!Transaction {
        std.debug.assert(db.transaction_depth < depth_max);
        std.debug.assert(depth_max == savepoint_sql.len);

        if (db.transaction_depth == 0) {
            try db.exec("BEGIN IMMEDIATE");
        } else {
            switch (db.transaction_depth) {
                inline 1...depth_max - 1 => |depth| try db.exec(savepoint_sql[depth]),
                else => unreachable,
            }
        }

        db.transaction_depth += 1;

        return .{ .db = db, .depth = db.transaction_depth };
    }

    /// Makes this transaction's writes permanent: `COMMIT` at the outermost
    /// level, `RELEASE` of the savepoint when nested — released writes then
    /// belong to the enclosing transaction, which can still roll them back.
    ///
    /// The last line of the scoped shape, making the writes all-or-nothing:
    ///
    /// ```zig
    /// var transaction = try db.transaction();
    /// defer transaction.rollback();
    ///
    /// try create_post(&db, "first-post");
    /// try create_post(&db, "second-post");
    ///
    /// try transaction.commit();          // both posts, or neither
    /// ```
    ///
    /// Must be the innermost unfinished transaction (asserted). If SQLite
    /// refuses the commit, the transaction is still open and the pending
    /// `defer rollback` cleans up.
    pub fn commit(transaction: *Transaction) Error!void {
        std.debug.assert(!transaction.finished);
        std.debug.assert(transaction.depth == transaction.db.transaction_depth);

        if (transaction.depth == 1) {
            try transaction.db.exec("COMMIT");
        } else {
            switch (transaction.depth) {
                inline 2...depth_max => |depth| try transaction.db.exec(release_sql[depth - 1]),
                else => unreachable,
            }
        }

        transaction.finish();
    }

    /// Discards this transaction's writes (`ROLLBACK`, or rolling back to and
    /// releasing the savepoint when nested). A no-op once the transaction is
    /// finished — the intended use is `defer` on the line after
    /// `db.transaction()`, covering every error path with no `errdefer`
    /// bookkeeping.
    ///
    /// ```zig
    /// var transaction = try db.transaction();
    /// defer transaction.rollback();      // runs on every early `try` return
    ///
    /// try risky_writes(&db);
    /// try transaction.commit();          // from here the defer is a no-op
    /// ```
    ///
    /// Panics if SQLite refuses the rollback itself: the connection would be
    /// left inside a transaction nobody owns, and no later query could be
    /// trusted.
    pub fn rollback(transaction: *Transaction) void {
        if (transaction.finished) {
            return;
        }

        std.debug.assert(transaction.depth == transaction.db.transaction_depth);
        std.debug.assert(transaction.depth >= 1);

        if (transaction.depth == 1) {
            transaction.db.exec("ROLLBACK") catch |err| rollback_failed(err);
        } else {
            switch (transaction.depth) {
                inline 2...depth_max => |depth| {
                    transaction.db.exec(rollback_to_sql[depth - 1]) catch |err| rollback_failed(err);
                    transaction.db.exec(release_sql[depth - 1]) catch |err| rollback_failed(err);
                },
                else => unreachable,
            }
        }

        transaction.finish();
    }

    fn rollback_failed(err: Error) noreturn {
        std.debug.panic("sqlite: rollback failed ({t})", .{err});
    }

    fn finish(transaction: *Transaction) void {
        transaction.db.transaction_depth -= 1;
        transaction.finished = true;
    }
};

const savepoint_sql = sql_per_depth("SAVEPOINT sp_");
const release_sql = sql_per_depth("RELEASE sp_");
const rollback_to_sql = sql_per_depth("ROLLBACK TO sp_");

fn sql_per_depth(comptime prefix: []const u8) [depth_max][:0]const u8 {
    comptime std.debug.assert(prefix.len > 0);
    comptime std.debug.assert(depth_max <= 99);

    var table: [depth_max][:0]const u8 = undefined;

    inline for (&table, 0..) |*slot, depth| {
        slot.* = std.fmt.comptimePrint("{s}{d}", .{ prefix, depth });
    }

    return table;
}

test "savepoint sql tables are built per depth" {
    try std.testing.expectEqualStrings("SAVEPOINT sp_0", savepoint_sql[0]);
    try std.testing.expectEqualStrings("RELEASE sp_3", release_sql[3]);
    try std.testing.expectEqualStrings("ROLLBACK TO sp_7", rollback_to_sql[7]);
}
