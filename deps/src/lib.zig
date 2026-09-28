//! publr_deps — a dependency index for build artifacts.
//!
//! It knows nothing about content, rendering, or HTML. Two kinds of names,
//! both opaque byte strings the caller chooses:
//!
//!   artifact   something built to a file: "/posts/hello", "island:latest"
//!   key        something an artifact may depend on: "entry:7",
//!              "field:7:title", "type:post", "tag:nav"
//!
//! The operations, in the order a round happens:
//!
//!   record(artifact, keys)   what a build of `artifact` read — replaces the
//!                            previous set, atomically
//!   invalidate(keys, now)    something changed; coalesced into the collecting
//!                            queue; a queue that reaches capacity is sealed
//!                            into a batch at once and a fresh queue starts
//!   due(now) / take(now)     after `quiet_ms` of no changes (or as soon as a
//!                            sealed batch waits), `take` hands out one batch,
//!                            FIFO
//!   plan(arena, batch)       the affected artifacts, each once, sorted —
//!                            or error.FanOutExceeded, with the batch kept
//!   unchanged(artifact, b)   whether a rebuild produced the same bytes, so
//!                            the caller writes nothing
//!   done(batch)              the batch is executed; its keys leave the queue
//!   forget(artifact)         the artifact is gone: edges, hash, everything
//!
//! Storage is the caller's SQLite database (tables prefixed `deps_`), so
//! `record` commits in the same transaction as the content write it
//! describes, and the queue survives a restart. An injected `Observer` is
//! told everything — what changed, who depends on it, the plan, the
//! execution — and can change nothing (see TESTS.md §8).
const std = @import("std");
const sqlite = @import("publr_sqlite");

pub const Error = sqlite.Error || std.mem.Allocator.Error || error{
    /// A batch would rebuild more artifacts than `Options.fanout_max` — the
    /// "you are misusing SSG" signal. The batch is kept; nothing was planned.
    FanOutExceeded,
    /// An artifact or key name is longer than `Options.name_len_max`.
    NameTooLong,
    /// An option is out of range (a zero capacity or limit).
    InvalidLimit,
    UncommittedRead,
};

/// How an executed artifact of a plan turned out — reported by the caller
/// through `executed`, for the observer.
pub const Outcome = enum { written, identical, removed, failed };

/// A tap, not a source of truth: no return values, no way to change
/// behaviour, and everything it is shown is also available through the API.
/// Any callback may be null. Slices passed to callbacks are valid only for
/// the duration of the call.
pub const Observer = struct {
    context: ?*anyopaque = null,
    /// A key entered the queue (`first_time`), or was already pending.
    invalidated: ?*const fn (context: ?*anyopaque, key: []const u8, first_time: bool) void = null,
    /// A collecting queue became a batch: capacity reached, or quiet elapsed.
    sealed: ?*const fn (context: ?*anyopaque, batch: u64, keys: []const []const u8) void = null,
    /// One changed key of a batch, with the artifacts that depend on it — the
    /// resolved graph, one call per key.
    planned: ?*const fn (context: ?*anyopaque, batch: u64, key: []const u8, artifacts: []const []const u8) void = null,
    /// The batch's deduped plan: every affected artifact once, sorted.
    plan: ?*const fn (context: ?*anyopaque, batch: u64, artifacts: []const []const u8) void = null,
    /// The caller executed one artifact of the plan.
    executed: ?*const fn (context: ?*anyopaque, batch: u64, artifact: []const u8, outcome: Outcome, detail: []const u8) void = null,
    /// The batch was refused: it would rebuild `count` artifacts, over the limit.
    refused: ?*const fn (context: ?*anyopaque, batch: u64, count: u64, limit: u64) void = null,
};

pub const Options = struct {
    /// Milliseconds of queue inactivity before the collecting queue is due.
    quiet_ms: u32 = 5_000,
    /// Distinct pending keys that seal the collecting queue into a batch.
    queue_cap: u32 = 10_000,
    /// The most artifacts one batch may rebuild before it is refused.
    fanout_max: u32 = 10_000,
    /// Longest artifact or key name, in bytes.
    name_len_max: u32 = 1024,
    observer: Observer = .{},
    /// Maximum committed revisions retained for independent client replay.
    replay_max: u32 = 10_000,
    /// The most keys one `changes_since` returns; past it, the client is asked
    /// to revalidate in full instead.
    keys_max: u32 = 4_096,
};

/// One sealed set of changed keys, taken FIFO. The keys are duped into the
/// arena `take` was given.
pub const Batch = struct {
    no: u64,
    keys: []const []const u8,
};

const schema =
    \\CREATE TABLE IF NOT EXISTS deps_changes (
    \\    revision INTEGER NOT NULL,
    \\    key TEXT NOT NULL,
    \\    PRIMARY KEY (revision, key)
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS deps_edges (
    \\    artifact TEXT NOT NULL,
    \\    key TEXT NOT NULL,
    \\    PRIMARY KEY (artifact, key)
    \\) WITHOUT ROWID;
    \\CREATE INDEX IF NOT EXISTS deps_edges_by_key ON deps_edges (key);
    \\CREATE TABLE IF NOT EXISTS deps_artifacts (
    \\    artifact TEXT PRIMARY KEY,
    \\    hash INTEGER NOT NULL
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS deps_pending (
    \\    key TEXT PRIMARY KEY,
    \\    batch INTEGER NOT NULL DEFAULT 0
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS deps_meta (
    \\    name TEXT PRIMARY KEY,
    \\    value INTEGER NOT NULL
    \\) WITHOUT ROWID;
;

pub const Index = struct {
    db: *sqlite.Database,
    options: Options,

    /// Creates the `deps_` tables (idempotently) in the caller's open
    /// database and validates the options.
    pub fn open(db: *sqlite.Database, options: Options) Error!Index {
        if (options.queue_cap == 0 or options.fanout_max == 0 or options.name_len_max == 0 or options.replay_max == 0 or options.keys_max == 0) {
            return error.InvalidLimit;
        }
        try db.exec(schema);
        return .{ .db = db, .options = options };
    }

    fn check_name(index: *const Index, name: []const u8) Error!void {
        if (name.len > index.options.name_len_max) return error.NameTooLong;
    }

    fn emit(index: *const Index, comptime callback: anytype, args: anytype) void {
        if (@field(index.options.observer, @tagName(callback))) |function| {
            @call(.auto, function, .{index.options.observer.context} ++ args);
        }
    }

    // ---- recording -----------------------------------------------------------

    /// The dependency set of `artifact` is exactly `keys`, replacing whatever
    /// its previous build recorded. Atomic: on failure the old set survives
    /// whole. Never touches the artifact's hash.
    pub fn record(index: *Index, artifact: []const u8, keys: []const []const u8) Error!void {
        try index.check_name(artifact);
        for (keys) |key| try index.check_name(key);

        var transaction = try index.db.transaction();
        defer transaction.rollback();

        var remove = try index.db.prepare("DELETE FROM deps_edges WHERE artifact = ?1");
        defer remove.finalize();
        try remove.bind_text(1, artifact);
        try remove.exec();

        var insert = try index.db.prepare("INSERT OR IGNORE INTO deps_edges (artifact, key) VALUES (?1, ?2)");
        defer insert.finalize();
        for (keys) |key| {
            insert.reset();
            try insert.bind_text(1, artifact);
            try insert.bind_text(2, key);
            try insert.exec();
        }

        try transaction.commit();
    }

    /// The artifact is gone: its edges and its hash. It stops appearing in
    /// every `affected` answer.
    pub fn forget(index: *Index, artifact: []const u8) Error!void {
        try index.check_name(artifact);

        var transaction = try index.db.transaction();
        defer transaction.rollback();

        var edges = try index.db.prepare("DELETE FROM deps_edges WHERE artifact = ?1");
        defer edges.finalize();
        try edges.bind_text(1, artifact);
        try edges.exec();

        var hashes = try index.db.prepare("DELETE FROM deps_artifacts WHERE artifact = ?1");
        defer hashes.finalize();
        try hashes.bind_text(1, artifact);
        try hashes.exec();

        try transaction.commit();
    }

    // ---- lookup --------------------------------------------------------------

    /// The keys `artifact` recorded when it was last built, sorted, duped into
    /// `arena`: `affected` the other way round. None for an artifact never
    /// recorded. One indexed query.
    pub fn keys_of(index: *Index, arena: std.mem.Allocator, artifact: []const u8) Error![]const []const u8 {
        try index.check_name(artifact);

        var select = try index.db.prepare("SELECT key FROM deps_edges WHERE artifact = ?1 ORDER BY key");
        defer select.finalize();
        try select.bind_text(1, artifact);

        var keys: std.ArrayList([]const u8) = .empty;
        while (try select.step()) {
            const row = try select.read(struct { key: []const u8 }, arena);
            try keys.append(arena, row.key);
        }
        return keys.toOwnedSlice(arena);
    }

    /// The artifacts that recorded any of `keys`: each once, sorted by name,
    /// duped into `arena`. One indexed query per key, never a scan.
    pub fn affected(index: *Index, arena: std.mem.Allocator, keys: []const []const u8) Error![]const []const u8 {
        var set: std.StringArrayHashMapUnmanaged(void) = .empty;
        var select = try index.db.prepare("SELECT artifact FROM deps_edges WHERE key = ?1");
        defer select.finalize();

        for (keys) |key| {
            try index.check_name(key);
            select.reset();
            try select.bind_text(1, key);
            while (try select.step()) {
                const artifact = try select.read(struct { artifact: []const u8 }, arena);
                try set.put(arena, artifact.artifact, {});
            }
        }

        const artifacts = try arena.dupe([]const u8, set.keys());
        std.mem.sort([]const u8, artifacts, {}, string_less_than);
        return artifacts;
    }

    /// Durable revision independent of the destructive artifact rebuild queue.
    pub fn revision(index: *Index) Error!u64 {
        return @intCast((try index.get_meta("revision")) orelse 0);
    }

    pub const Changes = struct {
        revision: u64,
        reset: bool,
        keys: []const []const u8,
    };

    /// Call after commit on a request-owned connection. An old cursor, or more
    /// than `keys_max` changed keys, requests full revalidation instead.
    ///
    /// Reads without a transaction so polling never takes the write lock: the
    /// keys are bounded above by the revision read first, and the floor is
    /// read again afterwards, so a prune that lands in between is caught.
    pub fn changes_since(index: *Index, arena: std.mem.Allocator, after: u64) Error!Changes {
        if (index.db.transaction_depth != 0) return error.UncommittedRead;
        const latest = try index.revision();
        const reset: Changes = .{ .revision = latest, .reset = true, .keys = &.{} };
        if (after < try index.replay_floor() or after > latest) return reset;
        var select = try index.db.prepare("SELECT DISTINCT key FROM deps_changes WHERE revision > ?1 AND revision <= ?2 ORDER BY key LIMIT ?3");
        defer select.finalize();
        try select.bind_int(1, @intCast(after));
        try select.bind_int(2, @intCast(latest));
        try select.bind_int(3, @as(i64, index.options.keys_max) + 1);
        var keys: std.ArrayList([]const u8) = .empty;
        while (try select.step()) {
            if (keys.items.len == index.options.keys_max) return reset;
            const row = try select.read(struct { key: []const u8 }, arena);
            try keys.append(arena, row.key);
        }
        if (after < try index.replay_floor()) return reset;
        return .{ .revision = latest, .reset = false, .keys = try keys.toOwnedSlice(arena) };
    }

    fn replay_floor(index: *Index) Error!u64 {
        return @intCast((try index.get_meta("replay_floor")) orelse 0);
    }

    // ---- the queue -----------------------------------------------------------

    /// Something changed. Coalesced: a key already pending stays one key. A
    /// collecting queue that reaches `queue_cap` distinct keys is sealed into
    /// a batch immediately; the next change starts a fresh queue with a fresh
    /// quiet period.
    pub fn invalidate(index: *Index, keys: []const []const u8, now_ms: i64) Error!void {
        for (keys) |key| try index.check_name(key);

        var transaction = try index.db.transaction();
        defer transaction.rollback();

        var insert = try index.db.prepare("INSERT OR IGNORE INTO deps_pending (key, batch) VALUES (?1, 0)");
        defer insert.finalize();
        for (keys) |key| {
            insert.reset();
            try insert.bind_text(1, key);
            try insert.exec();
            index.emit(.invalidated, .{ key, index.db.changes() == 1 });
        }

        const next = (try index.revision()) + 1;
        var log = try index.db.prepare("INSERT OR IGNORE INTO deps_changes (revision, key) VALUES (?1, ?2)");
        defer log.finalize();
        for (keys) |key| {
            log.reset();
            try log.bind_int(1, @intCast(next));
            try log.bind_text(2, key);
            try log.exec();
        }
        try index.put_meta("revision", @intCast(next));
        const floor = next -| index.options.replay_max;
        var prune = try index.db.prepare("DELETE FROM deps_changes WHERE revision <= ?1");
        defer prune.finalize();
        try prune.bind_int(1, @intCast(floor));
        try prune.exec();
        try index.put_meta("replay_floor", @intCast(floor));
        try index.put_meta("last_change_ms", now_ms);
        if (try index.collecting_count() >= index.options.queue_cap) {
            _ = try index.seal();
        }

        try transaction.commit();
    }

    /// Whether `take` would return a batch: a sealed one waits, or the
    /// collecting queue is non-empty and has been quiet for `quiet_ms`.
    pub fn due(index: *Index, now_ms: i64) Error!bool {
        if (try index.oldest_sealed() != null) return true;
        if (try index.collecting_count() == 0) return false;
        const last = (try index.get_meta("last_change_ms")) orelse return false;
        return now_ms - last >= index.options.quiet_ms;
    }

    /// The oldest sealed batch — sealing the collecting queue first if it is
    /// due — or null. The batch's keys stay in the database (marked with its
    /// number) until `done`, so a crash between `take` and `done` re-takes
    /// the same batch on restart. Keys are duped into `arena`, sorted.
    pub fn take(index: *Index, arena: std.mem.Allocator, now_ms: i64) Error!?Batch {
        var transaction = try index.db.transaction();
        defer transaction.rollback();

        var number = try index.oldest_sealed();
        if (number == null and try index.collecting_count() > 0) {
            const last = (try index.get_meta("last_change_ms")) orelse 0;
            if (now_ms - last >= index.options.quiet_ms) number = try index.seal();
        }
        try transaction.commit();
        const batch_no = number orelse return null;

        var select = try index.db.prepare("SELECT key FROM deps_pending WHERE batch = ?1");
        defer select.finalize();
        try select.bind_int(1, @intCast(batch_no));
        var keys: std.ArrayList([]const u8) = .empty;
        while (try select.step()) {
            const row = try select.read(struct { key: []const u8 }, arena);
            try keys.append(arena, row.key);
        }
        std.mem.sort([]const u8, keys.items, {}, string_less_than);
        return .{ .no = batch_no, .keys = keys.items };
    }

    /// The batch's affected artifacts — each once, sorted — computed against
    /// the index as it is now. Tells the observer the resolved graph (one
    /// `planned` per key) and the deduped plan. `error.FanOutExceeded` when
    /// the plan would exceed `fanout_max`: the batch is kept, nothing else
    /// happens.
    pub fn plan(index: *Index, arena: std.mem.Allocator, batch: Batch) Error![]const []const u8 {
        const artifacts = try index.affected(arena, batch.keys);
        if (artifacts.len > index.options.fanout_max) {
            index.emit(.refused, .{ batch.no, @as(u64, artifacts.len), @as(u64, index.options.fanout_max) });
            return error.FanOutExceeded;
        }
        if (index.options.observer.planned != null) {
            for (batch.keys) |key| {
                index.emit(.planned, .{ batch.no, key, try index.affected(arena, &.{key}) });
            }
        }
        index.emit(.plan, .{ batch.no, artifacts });
        return artifacts;
    }

    /// The observer's window into execution — a pure tap the caller feeds as
    /// it works through a plan.
    pub fn executed(index: *const Index, batch: u64, artifact: []const u8, outcome: Outcome, detail: []const u8) void {
        index.emit(.executed, .{ batch, artifact, outcome, detail });
    }

    /// The batch was executed: its keys leave the queue.
    pub fn done(index: *Index, batch: Batch) Error!void {
        var remove = try index.db.prepare("DELETE FROM deps_pending WHERE batch = ?1");
        defer remove.finalize();
        try remove.bind_int(1, @intCast(batch.no));
        try remove.exec();
    }

    // ---- no-op rebuilds ------------------------------------------------------

    /// Whether a rebuild of `artifact` produced the same bytes as the build
    /// before it. Either way, `bytes`' hash is now the stored one.
    pub fn unchanged(index: *Index, artifact: []const u8, bytes: []const u8) Error!bool {
        try index.check_name(artifact);
        const hash: i64 = @bitCast(std.hash.XxHash3.hash(0, bytes));

        var select = try index.db.prepare("SELECT hash FROM deps_artifacts WHERE artifact = ?1");
        defer select.finalize();
        try select.bind_text(1, artifact);
        const previous: ?i64 = if (try select.step()) select.read_int() else null;
        if (previous == hash) return true;

        var upsert = try index.db.prepare("INSERT INTO deps_artifacts (artifact, hash) VALUES (?1, ?2) ON CONFLICT (artifact) DO UPDATE SET hash = ?2");
        defer upsert.finalize();
        try upsert.bind_text(1, artifact);
        try upsert.bind_int(2, hash);
        try upsert.exec();
        return false;
    }

    // ---- plumbing ------------------------------------------------------------

    fn collecting_count(index: *Index) Error!u32 {
        var count = try index.db.prepare("SELECT COUNT(*) FROM deps_pending WHERE batch = 0");
        defer count.finalize();
        _ = try count.step();
        return @intCast(count.read_int());
    }

    fn oldest_sealed(index: *Index) Error!?u64 {
        var select = try index.db.prepare("SELECT MIN(batch) FROM deps_pending WHERE batch > 0");
        defer select.finalize();
        _ = try select.step();
        const number = select.read_int();
        return if (number > 0) @intCast(number) else null;
    }

    /// Seals the collecting queue as the next batch number and tells the
    /// observer. The caller holds the transaction.
    fn seal(index: *Index) Error!u64 {
        const number: u64 = @intCast(((try index.get_meta("batch_seq")) orelse 0) + 1);
        try index.put_meta("batch_seq", @intCast(number));

        var update = try index.db.prepare("UPDATE deps_pending SET batch = ?1 WHERE batch = 0");
        defer update.finalize();
        try update.bind_int(1, @intCast(number));
        try update.exec();

        if (index.options.observer.sealed != null) {
            var buffer: [4096]u8 = undefined;
            var fixed = std.heap.FixedBufferAllocator.init(&buffer);
            var keys: std.ArrayList([]const u8) = .empty;
            var select = try index.db.prepare("SELECT key FROM deps_pending WHERE batch = ?1");
            defer select.finalize();
            try select.bind_int(1, @intCast(number));
            const collected = while (try select.step()) {
                const row = select.read(struct { key: []const u8 }, fixed.allocator()) catch break false;
                keys.append(fixed.allocator(), row.key) catch break false;
            } else true;
            // A batch too large for the buffer is still sealed; the observer
            // just sees the keys that fit.
            _ = collected;
            index.emit(.sealed, .{ number, keys.items });
        }
        return number;
    }

    fn get_meta(index: *Index, comptime name: []const u8) Error!?i64 {
        var select = try index.db.prepare("SELECT value FROM deps_meta WHERE name = '" ++ name ++ "'");
        defer select.finalize();
        if (!try select.step()) return null;
        return select.read_int();
    }

    fn put_meta(index: *Index, comptime name: []const u8, value: i64) Error!void {
        var upsert = try index.db.prepare("INSERT INTO deps_meta (name, value) VALUES ('" ++ name ++ "', ?1) ON CONFLICT (name) DO UPDATE SET value = ?1");
        defer upsert.finalize();
        try upsert.bind_int(1, value);
        try upsert.exec();
    }
};

fn string_less_than(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "options are validated" {
    // No database is touched before validation, so a plain struct suffices.
    var db: sqlite.Database = undefined;
    try std.testing.expectError(error.InvalidLimit, Index.open(&db, .{ .queue_cap = 0 }));
    try std.testing.expectError(error.InvalidLimit, Index.open(&db, .{ .fanout_max = 0 }));
    try std.testing.expectError(error.InvalidLimit, Index.open(&db, .{ .name_len_max = 0 }));
}
