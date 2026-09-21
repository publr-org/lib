//! A thin binding over the vendored SQLite amalgamation (compiled into this
//! module by build.zig, so consumers are fully self-contained): exactly the
//! calls its consumers need, declared by hand against SQLite's stable C ABI —
//! no header translation, no @cImport.
//!
//! Quick start:
//!
//! ```zig
//! const sqlite = @import("publr_sqlite");
//!
//! var runtime = try sqlite.Runtime.init(.{});
//! defer runtime.deinit();
//!
//! var db = try sqlite.Database.open(&runtime, "app.db", .{});
//! defer db.close();
//!
//! try db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT)");
//!
//! var insert = try db.prepare("INSERT INTO notes (text) VALUES (?1)");
//! defer insert.finalize();
//! try insert.bind_text(1, "hello");
//! try insert.exec();
//! ```
//!
//! Errors: every failure is logged here with `sqlite3_errmsg` — the only place
//! the message is still alive — and surfaced as the small `Error` set.
//! Callers never see SQLite result codes.
//!
//! Threading: none, by contract. The vendored build is compiled with
//! SQLITE_THREADSAFE=0, so no mutexes exist in the binary; a `Database` and
//! everything derived from it must only ever be touched from one thread. That
//! is the deal a single-threaded server (the sibling http library) provides.
const std = @import("std");
const builtin = @import("builtin");
const transaction_module = @import("transaction.zig");

const DbHandle = opaque {};
const StmtHandle = opaque {};

// Primary result codes, from sqlite3.h.
const ok: c_int = 0; // SQLITE_OK
const row: c_int = 100; // SQLITE_ROW
const done: c_int = 101; // SQLITE_DONE
const busy: c_int = 5; // SQLITE_BUSY
const locked: c_int = 6; // SQLITE_LOCKED
const nomem: c_int = 7; // SQLITE_NOMEM
const dbconfig_defensive: c_int = 1010; // SQLITE_DBCONFIG_DEFENSIVE
const readonly: c_int = 8; // SQLITE_READONLY
const constraint: c_int = 19; // SQLITE_CONSTRAINT
const misuse: c_int = 21; // SQLITE_MISUSE

// Fundamental datatypes, from sqlite3.h.
const type_integer: c_int = 1; // SQLITE_INTEGER
const type_float: c_int = 2; // SQLITE_FLOAT
const type_text: c_int = 3; // SQLITE_TEXT
const type_blob: c_int = 4; // SQLITE_BLOB
const type_null: c_int = 5; // SQLITE_NULL

// Flags and options, from sqlite3.h.
const config_heap: c_int = 8; // SQLITE_CONFIG_HEAP
const open_readonly: c_int = 0x1; // SQLITE_OPEN_READONLY
const open_readwrite: c_int = 0x2; // SQLITE_OPEN_READWRITE
const open_create: c_int = 0x4; // SQLITE_OPEN_CREATE
const deserialize_freeonclose: c_uint = 1; // SQLITE_DESERIALIZE_FREEONCLOSE
const deserialize_resizeable: c_uint = 2; // SQLITE_DESERIALIZE_RESIZEABLE

// SQLITE_TRANSIENT, as *anyopaque (ABI-identical to the destructor fn pointer)
// because Zig refuses `@ptrFromInt` of -1 for aligned function pointers.
const transient: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

extern fn sqlite3_initialize() c_int;
extern fn sqlite3_shutdown() c_int;
extern fn sqlite3_config(option: c_int, ...) c_int;
extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    db: *?*DbHandle,
    flags: c_int,
    vfs: ?[*:0]const u8,
) c_int;
extern fn sqlite3_close(db: ?*DbHandle) c_int;
extern fn sqlite3_busy_timeout(db: ?*DbHandle, ms: c_int) c_int;
extern fn sqlite3_db_config(db: ?*DbHandle, op: c_int, ...) c_int;
extern fn sqlite3_errcode(db: ?*DbHandle) c_int;
extern fn sqlite3_errmsg(db: ?*DbHandle) [*:0]const u8;
extern fn sqlite3_exec(
    db: ?*DbHandle,
    sql: [*:0]const u8,
    callback: ?*const anyopaque,
    callback_arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern fn sqlite3_prepare_v2(
    db: ?*DbHandle,
    sql: [*]const u8,
    sql_len: c_int,
    stmt: *?*StmtHandle,
    tail: ?*[*]const u8,
) c_int;
extern fn sqlite3_bind_text(
    stmt: ?*StmtHandle,
    index: c_int,
    text: [*]const u8,
    text_len: c_int,
    destructor: ?*anyopaque,
) c_int;
extern fn sqlite3_bind_blob(
    stmt: ?*StmtHandle,
    index: c_int,
    bytes: [*]const u8,
    bytes_len: c_int,
    destructor: ?*anyopaque,
) c_int;
extern fn sqlite3_bind_int64(stmt: ?*StmtHandle, index: c_int, value: i64) c_int;
extern fn sqlite3_bind_double(stmt: ?*StmtHandle, index: c_int, value: f64) c_int;
extern fn sqlite3_bind_null(stmt: ?*StmtHandle, index: c_int) c_int;
extern fn sqlite3_bind_parameter_count(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_step(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_reset(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_clear_bindings(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_stmt_readonly(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_column_count(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_column_type(stmt: ?*StmtHandle, column: c_int) c_int;
extern fn sqlite3_column_text(stmt: ?*StmtHandle, column: c_int) ?[*:0]const u8;
extern fn sqlite3_column_blob(stmt: ?*StmtHandle, column: c_int) ?*const anyopaque;
extern fn sqlite3_column_bytes(stmt: ?*StmtHandle, column: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*StmtHandle, column: c_int) i64;
extern fn sqlite3_column_double(stmt: ?*StmtHandle, column: c_int) f64;
extern fn sqlite3_finalize(stmt: ?*StmtHandle) c_int;
extern fn sqlite3_changes(db: ?*DbHandle) c_int;
extern fn sqlite3_last_insert_rowid(db: ?*DbHandle) i64;
extern fn sqlite3_serialize(
    db: ?*DbHandle,
    schema: [*:0]const u8,
    size: *i64,
    flags: c_uint,
) ?[*]u8;
extern fn sqlite3_deserialize(
    db: ?*DbHandle,
    schema: [*:0]const u8,
    data: [*]u8,
    db_size: i64,
    buffer_size: i64,
    flags: c_uint,
) c_int;
extern fn sqlite3_malloc64(size: u64) ?*anyopaque;
extern fn sqlite3_free(ptr: ?*anyopaque) void;

/// The complete error set of every fallible call in this library.
///
/// The intended handling shape:
///
/// ```zig
/// store.create_post(slug, title) catch |err| switch (err) {
///     error.Constraint => return respond_conflict(res),  // expected: slug taken
///     error.Busy => return respond_retry(res),           // another process holds the lock
///     else => return err,                                // real failure, already logged
/// };
/// ```
pub const Error = error{
    /// Everything that is not one of the cases below: I/O failure, corrupt
    /// file, syntax error, a refused open. The full `sqlite3_errmsg` text has
    /// already been logged at error level by the time the caller sees this.
    Sqlite,
    /// A violated UNIQUE / NOT NULL / CHECK / FOREIGN KEY constraint. An
    /// expected outcome, not a failure: map it to a 409/4xx or a retry.
    /// Logged at debug level only.
    Constraint,
    /// Another process held the database lock for longer than the
    /// connection's `busy_timeout_ms`. Expected whenever two processes share
    /// a file (a CLI next to a running server): retry or tell the user.
    /// Logged at debug level only.
    Busy,
    /// A write on a connection opened with `read_only`, or on a file the
    /// process cannot write.
    ReadOnly,
    /// SQLite's own allocator is out of memory — on a `Runtime` with a fixed
    /// heap, the heap is full. The statement that hit it is rolled back by
    /// SQLite; the connection stays usable.
    OutOfMemory,
};

/// The minimum size of a fixed heap handed to `Runtime.init`.
pub const heap_bytes_min: u64 = 1 << 20;

/// The largest `busy_timeout_ms` a `Database` accepts.
pub const busy_timeout_ms_max: u32 = 60_000;

/// Scoped transactions with savepoint nesting — obtained via
/// `Database.transaction`; the contract lives on the type (see
/// `transaction.zig`).
pub const Transaction = transaction_module.Transaction;

/// SQLite's process-global state as an explicit value: `sqlite3_initialize`
/// on `init`, `sqlite3_shutdown` on `deinit`, and optionally the fixed heap
/// every allocation the engine makes comes out of. One per process, created
/// before the first `Database.open` and passed to it by pointer.
///
/// ```zig
/// var runtime = try sqlite.Runtime.init(.{});
/// defer runtime.deinit();
/// ```
///
/// With a heap, SQLite never calls `malloc` again: every page cache entry,
/// statement and temporary table is carved from the slice, and exhausting it
/// is `error.OutOfMemory` on the statement that needed more — a bounded,
/// recoverable outcome rather than a crash or an unbounded process.
///
/// ```zig
/// const heap = try gpa.alignedAlloc(u8, .@"8", 64 << 20);
/// defer gpa.free(heap);
///
/// var runtime = try sqlite.Runtime.init(.{ .heap = heap });
/// defer runtime.deinit();
/// ```
pub const Runtime = struct {
    /// The fixed heap given at `init`, or null when the engine uses `malloc`.
    /// Borrowed: the caller frees it after `deinit`.
    heap: ?[]align(8) u8,
    /// Connections opened on this runtime and not yet closed. `deinit`
    /// asserts it is zero — a leaked connection is a bug, not a cleanup job.
    open_count: u32 = 0,

    pub const Options = struct {
        /// At least `heap_bytes_min` bytes and a power of two (asserted).
        heap: ?[]align(8) u8 = null,
        /// The smallest allocation the fixed heap hands out; SQLite rounds
        /// every request up to a multiple of it.
        heap_alloc_min: u32 = 8,
    };

    /// Configures and initializes the engine. Fails with `error.Sqlite` if
    /// SQLite refuses — in practice only when it was already initialized by
    /// another `Runtime` in the same process, which is a caller bug.
    pub fn init(options: Options) Error!Runtime {
        if (options.heap) |heap| {
            std.debug.assert(heap.len >= heap_bytes_min);
            std.debug.assert(std.math.isPowerOfTwo(heap.len));

            const heap_len: c_int = @intCast(heap.len);
            const alloc_min: c_int = @intCast(options.heap_alloc_min);
            const heap_ptr: ?*anyopaque = heap.ptr;
            const code = sqlite3_config(config_heap, heap_ptr, heap_len, alloc_min);

            if (code != ok) {
                log_failure("sqlite: cannot configure a fixed heap (code {d})", .{code});
                return error.Sqlite;
            }
        }

        const code = sqlite3_initialize();

        if (code != ok) {
            log_failure("sqlite: cannot initialize (code {d})", .{code});
            return error.Sqlite;
        }

        return .{ .heap = options.heap };
    }

    /// Shuts the engine down and poisons the value. Every `Database` must be
    /// closed first (asserted).
    pub fn deinit(runtime: *Runtime) void {
        std.debug.assert(runtime.open_count == 0);

        const code = sqlite3_shutdown();
        std.debug.assert(code == ok);

        if (runtime.heap != null) {
            const none: ?*anyopaque = null;
            const zero: c_int = 0;
            const reset = sqlite3_config(config_heap, none, zero, zero);

            std.debug.assert(reset == ok);
        }

        runtime.* = undefined;
    }
};

/// One open connection. The intended shape is a single long-lived value per
/// process, shared by all handlers without locks, because in a
/// single-threaded server handlers never run concurrently.
///
/// ```zig
/// var db = try sqlite.Database.open(&runtime, "app.db", .{});
/// defer db.close();
/// ```
///
/// There is no pool: one process, one connection. A *second process* on the
/// same file (a CLI next to a running server) is fine — SQLite serialises
/// writers through the file lock, and `Options.busy_timeout_ms` says how long
/// this connection waits for it before `error.Busy`.
pub const Database = struct {
    /// The runtime this connection was opened on. Borrowed; `close` decrements
    /// its `open_count`.
    runtime: *Runtime,
    /// The `sqlite3 *` this value wraps, opaque because nothing outside the
    /// binding may dereference it. Valid from `open` until `close`, which
    /// poisons the whole `Database`.
    handle: *DbHandle,
    /// Savepoint nesting depth: 0 when no transaction is open, incremented by
    /// each `transaction` and restored by the matching commit or rollback.
    /// Owned by `Transaction`; consumers read it at most, never write it.
    transaction_depth: u32 = 0,

    pub const Options = struct {
        /// How long a statement waits for another process's lock before
        /// failing with `error.Busy`. Zero never waits. At most
        /// `busy_timeout_ms_max` (asserted).
        busy_timeout_ms: u32 = 0,
        /// Open without write access: every write fails with
        /// `error.ReadOnly`, and a missing file is an error rather than
        /// created.
        read_only: bool = false,
    };

    /// Opens the database file at `path`, creating it if absent, or an
    /// in-memory database for `":memory:"` (every test in this library runs
    /// on one). The path must be NUL-terminated; a runtime slice gets there
    /// with `std.fmt.bufPrintZ`.
    ///
    /// ```zig
    /// var path_buffer: [1024]u8 = undefined;
    /// const path = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{flag_value});
    /// var db = try Database.open(&runtime, path, .{ .busy_timeout_ms = 5_000 });
    /// ```
    ///
    /// Fails with `error.Sqlite` (already logged) when the file exists but is
    /// not a database, or its directory is missing or unwritable. Apply
    /// consumer PRAGMAs (`journal_mode = WAL`) with `exec` right after.
    pub fn open(runtime: *Runtime, path: [*:0]const u8, options: Options) Error!Database {
        std.debug.assert(options.busy_timeout_ms <= busy_timeout_ms_max);

        const flags: c_int = if (options.read_only)
            open_readonly
        else
            open_readwrite | open_create;

        var handle: ?*DbHandle = null;
        const code = sqlite3_open_v2(path, &handle, flags, null);

        if (code != ok) {
            log_failure("sqlite: cannot open {s}: {s}", .{ path, sqlite3_errmsg(handle) });
            _ = sqlite3_close(handle);
            return error.Sqlite;
        }

        // Defensive mode: no writes to the schema or the internal tables
        // through SQL, so a hostile image or statement cannot corrupt the
        // engine's own structures.
        _ = sqlite3_db_config(handle, dbconfig_defensive, @as(c_int, 1), @as(?*c_int, null));

        runtime.open_count += 1;

        const timeout: c_int = @intCast(options.busy_timeout_ms);
        const timeout_code = sqlite3_busy_timeout(handle, timeout);
        std.debug.assert(timeout_code == ok);

        return .{ .runtime = runtime, .handle = handle.? };
    }

    /// Closes the connection and poisons the value. Every `Statement` must be
    /// finalized and every `Transaction` finished first — an open transaction
    /// here is a caller bug, and asserts. Pair it with `open` via `defer`.
    ///
    /// ```zig
    /// var db = try sqlite.Database.open(&runtime, "app.db", .{});
    /// defer db.close();
    /// ```
    pub fn close(db: *Database) void {
        std.debug.assert(db.transaction_depth == 0);
        std.debug.assert(db.runtime.open_count > 0);

        const code = sqlite3_close(db.handle);
        std.debug.assert(code == ok);

        db.runtime.open_count -= 1;
        db.* = undefined;
    }

    /// Opens a scoped transaction, which exactly one of `commit` or
    /// `rollback` must finish — deferring the rollback makes that safe on
    /// every path, success included.
    ///
    /// The calling shape is always the same three lines:
    ///
    /// ```zig
    /// var transaction = try db.transaction();
    /// defer transaction.rollback();
    /// // … writes …
    /// try transaction.commit();
    /// ```
    ///
    /// At depth 0 this is `BEGIN IMMEDIATE`: the write lock is taken up
    /// front, so contention with another process surfaces here, as
    /// `error.Busy`, rather than mid-transaction. While a transaction is
    /// already open, the call opens a savepoint instead, so a callee can wrap
    /// its own writes without caring whether a caller already did:
    ///
    /// ```zig
    /// var outer = try db.transaction();
    /// defer outer.rollback();
    ///
    /// var inner = try db.transaction();  // a savepoint inside `outer`
    /// defer inner.rollback();
    /// // … writes that can fail as a unit …
    /// try inner.commit();                // kept — unless `outer` rolls back
    ///
    /// try outer.commit();
    /// ```
    ///
    /// Fails with `error.Sqlite` if SQLite refuses (already logged); nesting
    /// past `depth_max` (8) asserts. See `Transaction` for the
    /// commit/rollback contract.
    pub fn transaction(db: *Database) Error!Transaction {
        return Transaction.begin(db);
    }

    /// Runs one or more `;`-separated statements that return no rows: DDL,
    /// PRAGMAs, fixed seed INSERTs.
    ///
    /// ```zig
    /// try db.exec("PRAGMA journal_mode = WAL");
    /// try db.exec(
    ///     \\CREATE TABLE IF NOT EXISTS notes (
    ///     \\    id INTEGER PRIMARY KEY,
    ///     \\    text TEXT NOT NULL
    ///     \\);
    /// );
    /// ```
    ///
    /// Anything with parameters or results goes through `prepare` — `exec`
    /// discards rows. On failure in a multi-statement batch, the error (and
    /// the logged message) points at the batch, not the individual statement.
    ///
    /// `sql` is `comptime`: SQL is code, and the compiler enforces it. A
    /// string containing runtime data — user input especially — does not
    /// compile; data reaches the database only through `prepare` + `bind_*`.
    pub fn exec(db: *Database, comptime sql: [*:0]const u8) Error!void {
        const code = sqlite3_exec(db.handle, sql, null, null, null);

        if (code != ok) {
            return db.fail(code);
        }
    }

    /// Compiles the first statement in `sql`; anything after its terminating
    /// `;` is ignored. The caller owns the result until `finalize`.
    /// Parameters are `?N` placeholders (1-based), bound with the statement's
    /// `bind_*` methods before the first `step`.
    ///
    /// ```zig
    /// var select = try db.prepare("SELECT id FROM notes WHERE text = ?1");
    /// defer select.finalize();
    /// try select.bind_text(1, "hello");
    ///
    /// while (try select.step()) {
    ///     const id = select.read_int();
    /// }
    /// ```
    ///
    /// Fails with `error.Sqlite` on a syntax error or an unknown
    /// table/column. Preparing is cheap; this library prepares per use and
    /// finalizes with it — there is deliberately no statement cache.
    ///
    /// `sql` is `comptime`: SQL is code, and the compiler enforces it —
    /// comptime concatenation (`select_post ++ " WHERE slug = ?1"`) works,
    /// runtime data in the string does not compile. Values reach the query
    /// only through `?N` placeholders and `bind_*`, which is what makes SQL
    /// injection unrepresentable in a consumer of this library. The one
    /// exception is `prepare_dynamic`, named so every use is a grep away.
    pub fn prepare(db: *Database, comptime sql: []const u8) Error!Statement {
        comptime std.debug.assert(sql.len > 0);

        return db.prepare_dynamic(sql);
    }

    /// `prepare` for SQL composed at runtime — a filter with a variable number
    /// of `?N` placeholders, an ORDER BY picked from an enum, paging.
    ///
    /// ```zig
    /// var sql: std.Io.Writer.Allocating = .init(arena);
    /// try sql.writer.writeAll("SELECT id FROM posts WHERE status IN (");
    /// for (statuses, 1..) |_, index| try sql.writer.print("{s}?{d}", .{ sep(index), index });
    /// try sql.writer.writeAll(")");
    ///
    /// var select = try db.prepare_dynamic(sql.written());
    /// defer select.finalize();
    /// for (statuses, 1..) |status, index| try select.bind_text(@intCast(index), status);
    /// ```
    ///
    /// The only door through which runtime text reaches the query planner, so
    /// the rule is the one `prepare` enforces by type: the composed string is
    /// built from the consumer's own literals and placeholder numbers, never
    /// from data. Values still go through `bind_*`. Audit every call site;
    /// there should be very few.
    pub fn prepare_dynamic(db: *Database, sql: []const u8) Error!Statement {
        std.debug.assert(sql.len > 0);
        std.debug.assert(sql.len <= std.math.maxInt(c_int));

        var handle: ?*StmtHandle = null;
        const code = sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &handle, null);

        if (code != ok) {
            return db.fail(code);
        }

        return .{ .db = db.handle, .handle = handle.? };
    }

    /// Rows changed by the most recent INSERT, UPDATE, or DELETE on this
    /// connection — how a consumer tells "deleted" from "was never there".
    ///
    /// ```zig
    /// try delete_statement.exec();
    /// const existed = db.changes() > 0;
    /// ```
    pub fn changes(db: *Database) u32 {
        return @intCast(sqlite3_changes(db.handle));
    }

    /// The rowid of the most recent successful INSERT on this connection —
    /// the `INTEGER PRIMARY KEY` a table without an application-chosen id
    /// just assigned.
    ///
    /// ```zig
    /// try insert.exec();
    /// const note_id = db.last_insert_rowid();
    /// ```
    pub fn last_insert_rowid(db: *Database) i64 {
        return sqlite3_last_insert_rowid(db.handle);
    }

    /// The whole database as one byte string — the file SQLite would write —
    /// duped into `arena`. How an in-memory database leaves a process: a
    /// browser tab saving its state, a snapshot, a test fixture.
    ///
    /// ```zig
    /// const bytes = try db.serialize(arena);
    /// try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "backup.db", .data = bytes });
    /// ```
    ///
    /// No transaction may be open (asserted). Fails with `error.OutOfMemory`
    /// when the arena — or SQLite's heap, for the intermediate copy — cannot
    /// hold the image.
    pub fn serialize(db: *Database, arena: std.mem.Allocator) Error![]u8 {
        std.debug.assert(db.transaction_depth == 0);

        var size: i64 = 0;
        const data = sqlite3_serialize(db.handle, "main", &size, 0);

        if (data == null or size <= 0) {
            return db.fail(nomem);
        }

        defer sqlite3_free(data);

        const len: usize = @intCast(size);
        return arena.dupe(u8, data.?[0..len]) catch return error.OutOfMemory;
    }

    /// Replaces the database with the image `bytes` — the inverse of
    /// `serialize`. The bytes are copied into SQLite's own memory, so the
    /// caller's buffer may go right after.
    ///
    /// ```zig
    /// var db = try sqlite.Database.open(&runtime, ":memory:", .{});
    /// defer db.close();
    /// try db.deserialize(saved_bytes);
    /// ```
    ///
    /// No transaction may be open (asserted). Fails with `error.Sqlite` when
    /// the bytes are not a database image or its integrity check fails (the
    /// image is untrusted input; close the database after), `error.OutOfMemory`
    /// when SQLite's heap cannot hold the copy.
    pub fn deserialize(db: *Database, bytes: []const u8) Error!void {
        std.debug.assert(db.transaction_depth == 0);
        std.debug.assert(bytes.len > 0);

        const copy: ?[*]u8 = @ptrCast(sqlite3_malloc64(bytes.len));
        const buffer = copy orelse return db.fail(nomem);
        @memcpy(buffer[0..bytes.len], bytes);

        const flags = deserialize_freeonclose | deserialize_resizeable;
        const len: i64 = @intCast(bytes.len);
        const code = sqlite3_deserialize(db.handle, "main", buffer, len, len, flags);

        if (code != ok) {
            return db.fail(code);
        }

        var check = try db.prepare("PRAGMA quick_check");
        defer check.finalize();
        const verdict = if (try check.step()) sqlite3_column_text(check.handle, 0) else null;
        if (verdict == null or !std.mem.eql(u8, std.mem.span(verdict.?), "ok")) {
            log_failure("sqlite: deserialize: the image fails its integrity check", .{});
            return error.Sqlite;
        }
    }

    fn fail(db: *Database, code: c_int) Error {
        return fail_on(db.handle, code);
    }
};

/// A BLOB column in a `Statement.read` row struct: the bytes as stored, duped
/// into the arena. `[]const u8` reads a column as text; `Blob` says the
/// column holds bytes — a hash, an image — so a NULL comes back as empty
/// bytes (or null, for `?Blob`) and nothing ever treats it as a string.
///
/// ```zig
/// const Session = struct { secret_hash: sqlite.Blob, user_id: []const u8 };
/// const session = try select.read(Session, arena);
/// if (session.secret_hash.bytes.len == 32) { … }
/// ```
pub const Blob = struct {
    bytes: []const u8,
};

/// A column of any storage class in a `Statement.read` row struct: what the
/// cell actually holds, tagged. For the `ANY` column of a table whose rows
/// store values of different types (an EAV table, a JSON-like document
/// flattened into rows), where the type is data, not schema.
///
/// ```zig
/// const Cell = struct { field: []const u8, value: sqlite.Any };
///
/// while (try select.step()) {
///     const cell = try select.read(Cell, arena);
///     switch (cell.value) {
///         .integer => |number| …,
///         .real => |number| …,
///         .text => |text| …,
///         .blob => |bytes| …,
///         .null => …,
///     }
/// }
/// ```
pub const Any = union(enum) {
    null,
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
};

/// One compiled statement. Lifecycle, in order: `Database.prepare` → `bind_*`
/// each `?N` parameter → `step` until it returns false, calling `read` (or
/// `read_int` for a scalar aggregate) after every true → `finalize`. A write
/// is the same with `exec` in place of the `step` loop. To run the statement
/// again with other values — a bulk insert — `reset` it; otherwise it is
/// single-use, and preparing a fresh one is cheap.
pub const Statement = struct {
    /// The connection this statement was compiled on, kept only so a failing
    /// call can reach `sqlite3_errmsg` — the one place the message is still
    /// alive. Borrowed, never closed here.
    db: *DbHandle,
    /// The `sqlite3_stmt *` this value wraps, opaque because nothing outside
    /// the binding may dereference it. Valid from `Database.prepare` until
    /// `finalize`, which poisons the whole `Statement`.
    handle: *StmtHandle,

    /// Releases the statement and poisons the value. Pair every `prepare`
    /// with exactly one `finalize`, normally via `defer`.
    ///
    /// ```zig
    /// var select = try db.prepare("SELECT id FROM notes");
    /// defer select.finalize();
    /// ```
    ///
    /// Infallible from the caller's point of view: an error at finalize time
    /// was already surfaced by the `step` that caused it.
    pub fn finalize(stmt: *Statement) void {
        _ = sqlite3_finalize(stmt.handle);
        stmt.* = undefined;
    }

    /// Rewinds the statement and clears every binding, so it can be bound
    /// and run again — the shape of a bulk insert, one prepare for many rows.
    ///
    /// ```zig
    /// var insert = try db.prepare("INSERT INTO cells (field, value) VALUES (?1, ?2)");
    /// defer insert.finalize();
    ///
    /// for (cells) |cell| {
    ///     insert.reset();
    ///     try insert.bind_text(1, cell.field);
    ///     try insert.bind_int(2, cell.value);
    ///     try insert.exec();
    /// }
    /// ```
    ///
    /// Infallible: an error the previous run hit was already surfaced by the
    /// `step` or `exec` that caused it.
    pub fn reset(stmt: *Statement) void {
        _ = sqlite3_reset(stmt.handle);
        _ = sqlite3_clear_bindings(stmt.handle);
    }

    /// Binds a text parameter (`?N` indexes are 1-based). SQLite copies the
    /// bytes before returning (SQLITE_TRANSIENT), so `value` may point at
    /// arena or stack memory that is gone before the statement runs.
    ///
    /// ```zig
    /// var insert = try db.prepare("INSERT INTO notes (text) VALUES (?1)");
    /// defer insert.finalize();
    /// try insert.bind_text(1, text_from_request_arena);
    /// try insert.exec();
    /// ```
    ///
    /// An empty slice binds as empty text, never NULL.
    pub fn bind_text(stmt: *Statement, index: u31, value: []const u8) Error!void {
        stmt.assert_parameter(index);
        std.debug.assert(value.len <= std.math.maxInt(c_int));

        const ptr: [*]const u8 = if (value.len == 0) "" else value.ptr;
        const code = sqlite3_bind_text(stmt.handle, index, ptr, @intCast(value.len), transient);

        if (code != ok) {
            return stmt.fail(code);
        }
    }

    /// Binds text, or NULL for `null` — the shape of a nullable column fed
    /// from an optional (`updated_by`, an absent filter value).
    ///
    /// ```zig
    /// try insert.bind_optional_text(3, row.created_by);
    /// ```
    pub fn bind_optional_text(stmt: *Statement, index: u31, value: ?[]const u8) Error!void {
        std.debug.assert(index > 0);

        if (value) |text| {
            return stmt.bind_text(index, text);
        }

        return stmt.bind_null(index);
    }

    /// Binds a BLOB parameter (`?N` indexes are 1-based): bytes stored as
    /// bytes, never text. Copied like `bind_text`, so the source may die
    /// before the statement runs.
    ///
    /// ```zig
    /// try insert.bind_blob(2, &secret_hash);
    /// ```
    pub fn bind_blob(stmt: *Statement, index: u31, value: []const u8) Error!void {
        stmt.assert_parameter(index);
        std.debug.assert(value.len <= std.math.maxInt(c_int));

        const ptr: [*]const u8 = if (value.len == 0) "" else value.ptr;
        const code = sqlite3_bind_blob(stmt.handle, index, ptr, @intCast(value.len), transient);

        if (code != ok) {
            return stmt.fail(code);
        }
    }

    /// Binds an integer parameter (`?N` indexes are 1-based). Also the way
    /// to bind INTEGER row ids and booleans (0/1) — SQLite has no separate
    /// types for either.
    ///
    /// ```zig
    /// var select = try db.prepare("SELECT text FROM notes WHERE id = ?1");
    /// defer select.finalize();
    /// try select.bind_int(1, note_id);
    /// ```
    pub fn bind_int(stmt: *Statement, index: u31, value: i64) Error!void {
        stmt.assert_parameter(index);

        const code = sqlite3_bind_int64(stmt.handle, index, value);

        if (code != ok) {
            return stmt.fail(code);
        }
    }

    /// Binds a REAL parameter (`?N` indexes are 1-based).
    ///
    /// ```zig
    /// try insert.bind_real(2, score);
    /// ```
    pub fn bind_real(stmt: *Statement, index: u31, value: f64) Error!void {
        stmt.assert_parameter(index);

        const code = sqlite3_bind_double(stmt.handle, index, value);

        if (code != ok) {
            return stmt.fail(code);
        }
    }

    /// Binds NULL (`?N` indexes are 1-based). Every parameter starts out NULL
    /// after `prepare` and `reset`, so this is for saying so explicitly.
    ///
    /// ```zig
    /// try update.bind_null(2);
    /// ```
    pub fn bind_null(stmt: *Statement, index: u31) Error!void {
        stmt.assert_parameter(index);

        const code = sqlite3_bind_null(stmt.handle, index);

        if (code != ok) {
            return stmt.fail(code);
        }
    }

    /// Advances one row: true when a row is available (read it with `read`
    /// or `read_int`), false when the statement is done.
    ///
    /// The row loop:
    ///
    /// ```zig
    /// while (try select.step()) {
    ///     const post = try select.read(Post, arena);
    /// }
    /// ```
    ///
    /// For INSERT / UPDATE / DELETE, prefer `exec`. A violated constraint
    /// surfaces here as `error.Constraint` — for an INSERT inside a
    /// transaction, the shape in `transaction.zig` turns that into a clean
    /// full rollback.
    pub fn step(stmt: *Statement) Error!bool {
        const code = sqlite3_step(stmt.handle);

        return switch (code) {
            row => true,
            done => false,
            else => stmt.fail(code),
        };
    }

    /// Runs a statement that produces no rows — INSERT, UPDATE, DELETE — to
    /// completion. The write counterpart of the `step` loop.
    ///
    /// ```zig
    /// var insert = try db.prepare("INSERT INTO notes (text) VALUES (?1)");
    /// defer insert.finalize();
    /// try insert.bind_text(1, "hello");
    /// try insert.exec();
    /// ```
    ///
    /// A statement that is a SELECT, or that uses RETURNING, is a caller bug
    /// (asserted). Errors are those of `step`.
    pub fn exec(stmt: *Statement) Error!void {
        std.debug.assert(sqlite3_stmt_readonly(stmt.handle) == 0);

        const produced_row = try stmt.step();

        std.debug.assert(!produced_row);
    }

    /// Reads the current row into a struct — the normal way to consume rows.
    /// Columns map to fields in declaration order: field 0 is column 0, and
    /// so on, so the struct is the query's shape written as a type.
    ///
    /// ```zig
    /// const Post = struct { id: i64, slug: []const u8, title: ?[]const u8 };
    ///
    /// var select = try db.prepare("SELECT id, slug, title FROM posts");
    /// defer select.finalize();
    ///
    /// while (try select.step()) {
    ///     const post = try select.read(Post, arena);
    ///     _ = post;
    /// }
    /// ```
    ///
    /// Field types say how each column is read: `i64`, `f64`, `bool` (an
    /// INTEGER 0/1), `[]const u8` (text), `Blob` (bytes), `Any` (whatever the
    /// cell holds, tagged). A NULL reads as 0, 0.0, false, "" or empty bytes
    /// — or, for the optional forms `?i64`, `?f64`, `?[]const u8` and
    /// `?Blob`, as null. Text and bytes are duped into `arena`, so the
    /// returned struct owns nothing borrowed and lives as long as the arena
    /// (in a server: the response). Any other field type is a compile error.
    /// The struct's field count must match the query's column count —
    /// asserted, so a SELECT and its struct cannot drift apart silently.
    pub fn read(stmt: *Statement, comptime Row: type, arena: std.mem.Allocator) Error!Row {
        const fields = @typeInfo(Row).@"struct".fields;
        comptime std.debug.assert(fields.len > 0);
        std.debug.assert(fields.len == @as(usize, @intCast(sqlite3_column_count(stmt.handle))));

        var row_value: Row = undefined;

        inline for (fields, 0..) |field, column| {
            @field(row_value, field.name) = try stmt.read_cell(field.type, column, arena);
        }

        return row_value;
    }

    /// The one-value read, for queries whose whole answer is a single
    /// number — aggregates like COUNT, SUM, MAX.
    ///
    /// ```zig
    /// var count_posts = try db.prepare("SELECT COUNT(*) FROM posts");
    /// defer count_posts.finalize();
    /// _ = try count_posts.step();
    /// const total = count_posts.read_int();
    /// ```
    ///
    /// The result must have exactly one column (asserted). NULL reads as 0.
    pub fn read_int(stmt: *Statement) i64 {
        std.debug.assert(sqlite3_column_count(stmt.handle) == 1);

        return stmt.column_int(0);
    }

    fn read_cell(
        stmt: *Statement,
        comptime Cell: type,
        column: u31,
        arena: std.mem.Allocator,
    ) Error!Cell {
        const is_null = sqlite3_column_type(stmt.handle, column) == type_null;

        return switch (Cell) {
            i64 => stmt.column_int(column),
            f64 => stmt.column_real(column),
            bool => stmt.column_int(column) != 0,
            []const u8 => try stmt.column_text(column, arena),
            Blob => .{ .bytes = try stmt.column_blob(column, arena) },
            Any => try stmt.column_any(column, arena),
            ?i64 => if (is_null) null else stmt.column_int(column),
            ?f64 => if (is_null) null else stmt.column_real(column),
            ?[]const u8 => if (is_null) null else try stmt.column_text(column, arena),
            ?Blob => if (is_null) null else .{ .bytes = try stmt.column_blob(column, arena) },
            else => @compileError("publr_sqlite: a row field must be i64, f64, bool, " ++
                "[]const u8, Blob, Any or an optional of one, found " ++ @typeName(Cell)),
        };
    }

    fn column_any(stmt: *Statement, column: u31, arena: std.mem.Allocator) Error!Any {
        return switch (sqlite3_column_type(stmt.handle, column)) {
            type_integer => .{ .integer = stmt.column_int(column) },
            type_float => .{ .real = stmt.column_real(column) },
            type_text => .{ .text = try stmt.column_text(column, arena) },
            type_blob => .{ .blob = try stmt.column_blob(column, arena) },
            else => .null,
        };
    }

    /// A null pointer from SQLite is a SQL NULL — or the engine failing to
    /// convert the value for want of memory, which must not read as "".
    fn column_null(stmt: *Statement) Error![]const u8 {
        if (sqlite3_errcode(stmt.db) & 0xff == nomem) return error.OutOfMemory;
        return "";
    }

    fn column_text(stmt: *Statement, column: u31, arena: std.mem.Allocator) Error![]const u8 {
        const ptr = sqlite3_column_text(stmt.handle, column) orelse return stmt.column_null();
        const len: usize = @intCast(sqlite3_column_bytes(stmt.handle, column));

        return arena.dupe(u8, ptr[0..len]) catch return error.OutOfMemory;
    }

    fn column_blob(stmt: *Statement, column: u31, arena: std.mem.Allocator) Error![]const u8 {
        const raw = sqlite3_column_blob(stmt.handle, column) orelse return stmt.column_null();
        const ptr: [*]const u8 = @ptrCast(raw);
        const len: usize = @intCast(sqlite3_column_bytes(stmt.handle, column));

        return arena.dupe(u8, ptr[0..len]) catch return error.OutOfMemory;
    }

    fn column_int(stmt: *Statement, column: u31) i64 {
        return sqlite3_column_int64(stmt.handle, column);
    }

    fn column_real(stmt: *Statement, column: u31) f64 {
        return sqlite3_column_double(stmt.handle, column);
    }

    fn assert_parameter(stmt: *Statement, index: u31) void {
        std.debug.assert(index > 0);
        std.debug.assert(index <= sqlite3_bind_parameter_count(stmt.handle));
    }

    fn fail(stmt: *Statement, code: c_int) Error {
        return fail_on(stmt.db, code);
    }
};

fn fail_on(handle: *DbHandle, code: c_int) Error {
    std.debug.assert(code != ok);
    std.debug.assert(code != row);
    std.debug.assert(code != done);
    std.debug.assert(code & 0xff != misuse);

    switch (code & 0xff) {
        constraint => {
            std.log.debug("sqlite: {s} (code {d})", .{ sqlite3_errmsg(handle), code });
            return error.Constraint;
        },
        busy, locked => {
            std.log.debug("sqlite: {s} (code {d})", .{ sqlite3_errmsg(handle), code });
            return error.Busy;
        },
        readonly => {
            log_failure("sqlite: {s} (code {d})", .{ sqlite3_errmsg(handle), code });
            return error.ReadOnly;
        },
        nomem => {
            log_failure("sqlite: {s} (code {d})", .{ sqlite3_errmsg(handle), code });
            return error.OutOfMemory;
        },
        else => {
            log_failure("sqlite: {s} (code {d})", .{ sqlite3_errmsg(handle), code });
            return error.Sqlite;
        },
    }
}

// Real failures log at err — except in test builds, where the test runner
// fails any test that logs an error, and the failure paths are exactly what
// the integration tests exercise.
fn log_failure(comptime format: []const u8, args: anytype) void {
    if (builtin.is_test) {
        std.log.debug(format, args);
    } else {
        std.log.err(format, args);
    }
}

test {
    _ = transaction_module;
}
