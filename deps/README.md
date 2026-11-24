# publr_deps

A dependency index for build artifacts. It knows nothing about content,
rendering, or HTML — two kinds of opaque names, and five verbs:

```zig
const deps = @import("publr_deps");

var index = try deps.Index.open(&db, .{});          // tables (deps_*) in YOUR SQLite database

// at build: what a render read, flat — references it followed included
try index.record("/posts/hello", &.{ "entry:post:7", "field:author:3:name" });

// on change: coalesced into a queue; a full queue seals into a batch at once
try index.invalidate(&.{ "entry:author:3", "field:author:3:name" }, now_ms);

// after quiet (or when a sealed batch waits): one batch at a time, FIFO
if (try index.take(arena, now_ms)) |batch| {
    const artifacts = try index.plan(arena, batch); // each once, sorted — or FanOutExceeded, batch kept
    for (artifacts) |artifact| {
        const bytes = render(artifact);
        try index.record(artifact, keys_read);
        if (try index.unchanged(artifact, bytes)) {
            index.executed(batch.no, artifact, .identical, "");
        } else {
            write(artifact, bytes);
            index.executed(batch.no, artifact, .written, "");
        }
    }
    try index.done(batch);
}
```

The contract is [TESTS.md](TESTS.md) — a test matrix the suite under
`tests/` mirrors row by row, including the caller-side key rules (type key
on every write; a query records the type key unless its result set is pinned
by immutable ids) and the safety property: the plan over-approximates and can
never miss; the render judges change, the hash judges writing; a wrong guess
costs a render, never staleness.

An `Observer` (in `Options`) is a tap for all of it — what changed, who
depends on it, the deduped plan, the execution — and can change nothing.

Beside artifacts it keeps values the caller works out and stores itself (a computed
field), checked when read instead of rebuilt in a batch:

```zig
const at = try index.revision();                     // before the work
const value = work_out();                            // noting what it reads
try index.note("computed:line/7/price", keys_read, .{ .at = at, .until_ms = ends, .stamp = code });
// later, on a read:
if (!try index.fresh("computed:line/7/price", .{ .now_ms = now, .stamp = code })) work_out_again();
```

A write costs the same however many values read its keys: `fresh` asks the change log
whether any of them changed after `at`. No plan names a value.

`record` participates in the caller's open transaction, so the index commits
with the content write it describes; the queue lives in the database and
survives restarts.

```bash
zig build test
```
