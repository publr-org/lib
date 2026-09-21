# Publr SQLite

SQLite, fully self-contained: the vendored amalgamation compiled into the
module, behind a deliberately thin binding — a few hundred lines of
hand-declared `extern fn`s against SQLite's stable C ABI. No system
libsqlite3, no header translation, no query builder, no ORM. Consumers just
import the module; the database engine rides along, and the resulting binary
needs nothing installed on the target machine.

```zig
const sqlite = @import("publr_sqlite");

var runtime = try sqlite.Runtime.init(.{});
defer runtime.deinit();

var db = try sqlite.Database.open(&runtime, "app.db", .{});
defer db.close();

try db.exec("CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, text TEXT NOT NULL)");

var insert = try db.prepare("INSERT INTO notes (text) VALUES (?1)");
defer insert.finalize();
try insert.bind_text(1, "hello");
try insert.exec();
```

## Using it in your Zig project

The library carries its own build: the amalgamation, the compile flags, and the
libc link all travel with the module. Wiring it up is one dependency entry and
one import line — a consumer's build.zig repeats nothing SQLite-specific and
can never drift from the flags the library promises:

```zig
// build.zig.zon — a sibling checkout or an in-repo vendored copy; never a URL
.dependencies = .{
    .publr_sqlite = .{ .path = "../sqlite" },
},

// build.zig
const publr_sqlite = b.dependency("publr_sqlite", .{
    .target = target,
    .release = optimize != .Debug,
});
exe_module.addImport("publr_sqlite", publr_sqlite.module("publr_sqlite"));
```

Vendoring into a self-contained repo is the same mechanism at a different
path: copy this whole directory — build.zig included — to
`vendor/publr-sqlite/` and point the dependency there. A path dependency
fetches nothing, so the single-checkout, offline-build property is preserved;
upgrading the library is replacing the directory.

## Philosophy

Like [the HTTP server](../http), this binding exists to power Publr, and
its restraint is the feature. It exposes exactly the calls its consumers need —
a runtime, open, exec, prepare, bind, step, exec, reset, rows read into
structs, changes, scoped transactions, database images — and a call is added
the day a consumer needs it, never speculatively. SQL stays SQL: strings in
the consumer's code, `?N` placeholders, no abstraction between you and the
query planner.

## The contract

**SQL is code — enforced by the compiler, not by discipline.** `exec` and
`prepare` take their SQL as a `comptime` parameter: string literals and
comptime concatenation compile, a string containing any runtime data does
not. User input therefore *cannot* reach the query text; values enter only
through `?N` placeholders and `bind_*`. SQL injection is not a rule to
follow in this library — it is unrepresentable. The one door for genuinely
dynamic SQL — a filter with a variable number of placeholders, an ORDER BY
picked from an enum — is `prepare_dynamic`, named so that every audit is a
single grep; the composed string is still built from literals and placeholder
numbers, and values still go through `bind_*`.

**A handful of errors, each an outcome.** Every failure surfaces as one of
five cases: `error.Constraint` (a violated UNIQUE / NOT NULL / CHECK / FOREIGN
KEY — map it to a 4xx), `error.Busy` (another process held the lock past the
connection's timeout — retry), `error.ReadOnly` (a write on a read-only
connection or file), `error.OutOfMemory` (a fixed heap is full; the statement
is rolled back, the connection stays usable), and `error.Sqlite` for
everything real. The full `sqlite3_errmsg` text is logged at the binding
boundary, the only place it is still alive; the expected outcomes log at
debug, real failures at error. Callers never see result codes.

**The process-global state is a value.** SQLite initializes and shuts down
once per process, and may be given a fixed heap to live in. `Runtime` is
that state made explicit: created first, passed to every `open` by pointer,
asserting on `deinit` that every connection was closed. With a heap, every
page, statement and temporary table the engine ever allocates is carved from
the slice you gave it, and running out is `error.OutOfMemory` on one statement
rather than a crash — which is what makes a process's memory bounded at
startup.

**Rows come out as structs.** The normal way to consume a row is
`Statement.read`: declare the query's shape as a struct (fields in SELECT
column order — asserted against the query, so they cannot drift apart
silently) and get a filled value back:

```zig
const Post = struct { id: i64, slug: []const u8, title: ?[]const u8, score: f64 };

while (try select.step()) {
    const post = try select.read(Post, arena);
}
```

The field type says how the column is read: `i64`, `f64`, `bool`,
`[]const u8` for text, `Blob` for bytes, `Any` for a cell whose storage class
is data rather than schema, and the optional forms (`?i64`, `?[]const u8`,
…) when NULL should come back as null rather than 0 or "". Text and bytes
are duped into the arena you pass, so the struct owns everything and lives
exactly as long as the arena — in a server, the request arena, so rows die
with the response and nothing is freed by hand. The one query shape with no
struct is the scalar aggregate, and it has its own call: `read_int()` for
`SELECT COUNT(*)` and friends (asserted single-column). The positional cell
reads underneath are private — there is no consumer-facing way to touch a raw
column.

**Bound values are copied; bind from anywhere.** Binds use `SQLITE_TRANSIENT`,
so parameters may point at arena or stack memory that is gone before the
statement runs. Slower than borrowing, and immune to lifetime bugs by
construction. A statement is run again by `reset` — the shape of a bulk
insert, one prepare for many rows — and is otherwise single-use.

**One connection, one thread, no pool.** The binding is built for a
single-threaded server (the [HTTP server](../http)'s event loop):
handlers never run concurrently, so one bare connection is safe to share with
no locks, and the process matches SQLite's single writer. Nothing here is
thread-safe, on purpose — sharing a `Database` across threads is a consumer
bug, not a supported mode. A second *process* on the same file (a CLI next to
a running server) is fine: SQLite serialises them through the file lock, and
`busy_timeout_ms` on `open` says how long to wait for it before
`error.Busy`.

**Transactions are scoped values.** `db.transaction()` returns a `Transaction`; the
calling shape is always the same three lines —

```zig
var transaction = try db.transaction();
defer transaction.rollback();
// … writes …
try transaction.commit();
```

— because rollback after a successful commit is a no-op, `defer` is safe on
every path. Nested `db.transaction()` calls become savepoints (up to 8 deep): an inner
rollback discards only the inner writes, the outer transaction lives on. The
outermost level is `BEGIN IMMEDIATE` — with one connection there is nobody to
defer the write lock for. A rollback that itself fails panics: the connection
would be left inside a transaction nobody owns, and no later query could be
trusted.

**Vendored, and the compile flags are part of the contract.** The amalgamation
(`vendor/sqlite/`, public domain, currently 3.53.4) is compiled by `build.zig`
with flags that encode the same promises the API makes: `SQLITE_THREADSAFE=0`
— no mutexes exist in the build, so the one-connection-one-thread rule is
enforced by the engine, not just documented; `SQLITE_OMIT_LOAD_EXTENSION` — no
dlopen, the binary stays self-contained; `SQLITE_OMIT_AUTOINIT` and
`SQLITE_ENABLE_MEMSYS5` — what make `Runtime` real: the engine starts when
told, inside the heap it was given; `SQLITE_ENABLE_FTS5` — the full-text
index; plus the recommended misfeature removals (`DQS=0`, `TEMP_STORE=2`,
`OMIT_DEPRECATED`, no memory statistics, WAL-synchronous NORMAL). Upgrading
SQLite is replacing two files in `vendor/sqlite/`; the binding doesn't change,
because the ABI it declares against has not broken since 2004.

**Hand-declared, not `@cImport`ed.** The header-import route generates ~10k
lines of raw C declarations for the few dozen calls used here, still needs the
same Zig wrapper on top, and `SQLITE_TRANSIENT` — the one constant this
binding's safety leans on — fails to translate at all (translate-c rejects
casting `-1` to an aligned function pointer). Declaring the inventory by hand
is smaller than what it would replace, and doubles as the audit list of
everything the binding can do.

## Known limits (deliberate scope, not oversights)

- One `Runtime` per process: SQLite's initialize/shutdown is global, and a
  second runtime would shut the first one's connections down.
- No statement cache: prepare per use, `reset` only for a loop over one
  statement.
- `exec` discards rows; reading requires `prepare`. Errors from `exec` on
  multi-statement SQL point at the batch, not the statement.

## Tests and docs

```bash
zig build test   # unit + integration
zig build docs   # browsable API reference from the doc comments → zig-out/docs
```

Two kinds of tests, split by whether a database gets opened. Truly unit tests
(pure logic, no engine) live inline next to the code in `src/`. Integration
tests — everything that exercises the real vendored engine, on `:memory:`
databases — live under `tests/`, grouped by topic: `binding.zig` (core calls
and every failure path), `rows.zig` (`read`/`read_int`, every field type),
`transactions.zig` (the scoped contract), `runtime.zig` (the fixed heap, a
second process on the file, read-only, images). "Integration" here still
means microseconds: SQLite is
a library, so spinning up a database is one in-process allocation, and the
whole suite runs in well under a second. Nothing is mocked — the binding's
biggest risk is its hand-declared externs (a wrong signature is silent UB no
header will catch), so the real engine is exactly what the tests must
include. The strategy is strict, though: a test exists only if a failure
would be *our* bug — the ABI declarations, the error mapping, the
copy/lifetime choices, the comptime mapping, the transaction bookkeeping.
SQLite's own behavior is never re-tested; its authors do that with 100%
branch coverage.

The doc comments in `src/lib.zig` and `src/transaction.zig` are the API
reference — every public declaration carries its contract (errors, lifetimes,
threading) and a usage example. This README is the philosophy; the source is
the manual.

`zig build docs` renders the amalgamation rather than the source tree: `zig build
amalgamate` writes the library as one file, `zig-out/publr_sqlite.zig`, tests
stripped, in which `pub` means exactly "a consumer can call this" (see
`../tools`). The tests run against that file too, and it is what to vendor.

Two conventions keep those comments readable once rendered:

**The first paragraph must stand on its own.** Listings — the Functions
section of a type, search results — show only the text up to the first blank
`///` line, so a paragraph that ends by introducing what comes next ("the
calling shape is always the same three lines:") renders as a sentence cut in
half. Say what the declaration does, and stop. A lead-in for an example goes
in its own paragraph, directly above the example.

**Examples go in ` ```zig ` fences, never indented blocks.** The renderer's
markdown is a restricted subset that strips leading whitespace before looking
for block structure, so it has no indented-code-block rule at all — an
indented example silently collapses into a run-on paragraph.
