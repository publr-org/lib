# publr_groq

GROQ, the query language at [spec.groq.dev](https://spec.groq.dev), as specified in
**GROQ-1.revision5**: a query from text to value, parsed, validated and evaluated over a
dataset you provide. Pure Zig over `std`.

```zig
const groq = @import("publr_groq");

var memory: groq.Memory = .{ .documents = documents };
var problem: groq.Problem = .{};
const answer = try groq.execute(arena, query, memory.dataset(), .{ .params = params }, &problem);
const json = try groq.values.to_json(arena, answer.value);
```

## What it covers

All of revision 5 except what is left out on purpose: the extensions (Portable Text, geo,
documents), custom functions, delta mode with `diff::` and `delta::`, and the vendor
functions (`identity()`, `path()`).

## Datasets

`*` reads from a `Dataset`, an interface: `everything`, `candidates` (a superset of the
documents a filter can match, given its hints: the `attribute == value` clauses of the
filter's top-level `&&` whose value does not depend on the document) and `find` (a
document by `_id`, or why it may not be read). `Memory` holds documents in memory and
indexes hinted attributes on first use. An application's own dataset can push the hints
into its storage; the evaluator always applies the whole filter after.

## Conformance

```bash
zig build conformance -- suite.ndjson [--movies movies.ndjson] [--show N]
```

Runs [the GROQ test suite](https://github.com/sanity-io/groq-test-suite) (`suite.ndjson`
from its v1.0.4 release, the movies dataset from the URL in it). Tests of what is left out
on purpose are skipped and counted. Result on 2026-10-03: **6,885 passed, 0 failed**, 3,363
skipped (geo 2,371, `diff::` 577, GROQ 0.x 280, vendor functions 82, Portable Text 22,
custom functions 16, content releases 10, internal documents 5).

Where the suite and the spec text differ, the suite is followed: datasets are read in
`_id` order, a flat-mapped traversal keeps values that are not arrays, slices clamp like
JavaScript's, `score()` starts from 0, `string::lower`/`upper` exist beside the global ones,
and `$params` count as constants inside `[...]`.
