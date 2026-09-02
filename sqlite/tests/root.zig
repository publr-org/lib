//! Integration-test root: every test under tests/ opens a real `:memory:`
//! database. Truly unit tests (no database) live inline in src/; `zig build
//! test` runs both.
//!
//! Strategy: a test exists only if a failure would be OUR bug — the
//! hand-declared externs (the ABI risk nothing else can catch), the error
//! mapping, the copy/lifetime choices (TRANSIENT, arena dupes), the comptime
//! row mapping, the transaction depth bookkeeping, the runtime's heap and
//! open-count accounting. SQLite's own behavior (durability, SQL semantics)
//! is never re-tested here: its authors test it with 100% branch coverage,
//! and a test that can only catch their bugs is dead weight.
test {
    _ = @import("binding.zig");
    _ = @import("rows.zig");
    _ = @import("transactions.zig");
    _ = @import("runtime.zig");
}
