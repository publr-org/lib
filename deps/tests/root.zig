//! Integration-test root: every test opens a real `:memory:` database.
//! The suite is TESTS.md — one file per matrix section, each test named by
//! its row. "flush" in the matrix is `take` + `plan` + `done` here: the
//! matrix speaks in rounds, the API in batches.
//!
//! Strategy (per TESTING.md): a test exists only if a failure would be OUR
//! bug — the set-replacement bookkeeping, the queue sealing, the fan-out
//! arithmetic, the hash comparison, the observer taps, the indexed query
//! shape. SQLite's semantics are never what is under test.
test {
    _ = @import("lookup.zig");
    _ = @import("recording.zig");
    _ = @import("batching.zig");
    _ = @import("limits_and_hashing.zig");
    _ = @import("storage.zig");
    _ = @import("observer.zig");
}
