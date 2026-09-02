# deps — the contract, as a test matrix

`deps` is a dependency index for build artifacts. It knows nothing about
content, rendering, or HTML. It records what a build of an artifact read,
answers "what must be rebuilt now that these keys changed", batches changes
until the caller is quiet, refuses absurd fan-out, tells the caller when a
rebuild produced the same bytes so nothing is written, and narrates all of it
to an injected observer (§8).

Two kinds of names, both opaque to the library:

- **artifact** — something that gets built to a file and has an identity:
  `/posts/hello`, `island:latest-posts-bec6826b`. The library never interprets
  it.
- **key** — something an artifact may depend on: `entry:7`, `field:7:title`,
  `type:post`, `tag:nav`. Also opaque. The *caller* decides which keys a read
  produces and which keys a change raises; the library only matches them.

Storage is one SQLite database the caller already has open, so `record` and
the content write it describes commit in one transaction.

Every row below is one test. Each is *our* bug if it fails: SQLite's
semantics are never what is under test, the bookkeeping on top of them is.

---

## 1. Lookup — `affected(keys) → artifacts`

The question the index exists to answer: these keys changed — which
artifacts are affected? One indexed query, never a scan. Edges are written
artifact → keys (that is how the information arrives: a render knows what it
read) and queried key → artifacts; one edge table, two indexes, no
duplication. Transitivity is the caller's: a render that followed a
reference read the referenced entry, so it is recorded flat.

| # | name | setup | action | expect |
|---|---|---|---|---|
| 1.1 | direct dependents | `/a`→{entry:1}, `/b`→{entry:2} | `affected({entry:1})` | = {/a} |
| 1.2 | several keys, union, each artifact once | `/a`→{entry:1}, `/b`→{entry:1, entry:2}, `/c`→{entry:2} | `affected({entry:1, entry:2})` | = {/a, /b, /c}, `/b` exactly once |
| 1.3 | unknown key | — | `affected({entry:999})` | = {} |
| 1.4 | 145 dependents, exact | 145 artifacts each →{author:3, …own entry}, 55 artifacts →{author:4} | `affected({author:3})` | = exactly the 145; none of the 55 |
| 1.5 | nested references recorded flat | `/posts/hello`→{entry:7, entry:3 (author), entry:1 (team), entry:9 (logo)} | `affected({entry:1})` | = {/posts/hello} — no traversal needed or performed (assert a single query; see 6.3) |
| 1.6 | a field key is narrower than its entry key | `/a`→{field:3:name}, `/b`→{field:3:bio} | `affected({field:3:bio})` | = {/b}; the caller raising an entry change raises every changed field, so editing only the bio never touches `/a` |
| 1.7 | type key covers open result sets | `/posts`→{type:post}, `/posts/hello`→{entry:7} | `affected({type:post})` | = {/posts}; `/posts/hello` is not a candidate |
| 1.8 | tag key is just a key | `/a`→{tag:nav} | `affected({tag:nav})` | = {/a} |
| 1.9 | order is stable | `/b`, `/a`, `/c` recorded in that order, all →{entry:1} | `affected({entry:1})` | returned sorted by artifact name — a plan is reproducible |

**Caller-side rules the demo pins** (the library only matches keys; these are
about which keys the CMS produces, tested end-to-end in §7):

- **The type key is raised on *every* write to an entry of that type** —
  create, update, delete — not just create. An update can change a query's
  membership (a backdated `published_at` entering "newest 3"); the false
  positives this causes are absorbed by the no-op hash, never written.
- **A query records `type:<t>` unless its result set is provably closed.**
  Closed means membership is pinned by immutable ids: `{ ids: […] }`, or a
  reference-field traversal (a list of ids under the hood). Any other
  predicate — order, window, tag, author, slug — is evaluated against data
  that can change, so it is open and records the type key. Decided by the
  compiler from the options struct; the default is open, and a wrong guess
  can only over-invalidate, never go stale.
- **A closed query records the ids it *asked for*, not the ids it returned** —
  a member filtered out today (unpublished) re-enters by an edit to itself,
  which must find the artifact.
- **Query artifacts also record the concrete rows they showed** (their field
  keys), which is what makes edits to a shown row surgical, and edits to an
  unshown row of the same type a hash-skip.

## 2. Recording — `record(artifact, keys)`

The dependency set of an artifact is exactly the keys of its last build.
There is no read-by-artifact operation: everything is asserted through
`affected`, the one question the index answers. (Replacing a set needs the
index on `artifact` — 6.4 — but that is storage, not API.)

| # | name | setup | action | expect |
|---|---|---|---|---|
| 2.1 | records a set | — | `record("/a", {entry:1, entry:2})` | `affected({entry:1})` = {/a}; `affected({entry:2})` = {/a} |
| 2.2 | replaces, never accumulates | `record("/a", {entry:1, entry:2})` | `record("/a", {entry:2, entry:3})` | `affected({entry:1})` = {}; `affected({entry:3})` = {/a} |
| 2.3 | empty set is a valid build | `record("/a", {entry:1})` | `record("/a", {})` | `affected({entry:1})` = {}; `/a` still exists as an artifact (its hash survives, 5.7) |
| 2.4 | duplicate keys in one call collapse | — | `record("/a", {entry:1, entry:1})` | one edge row; `affected({entry:1})` = {/a}, once |
| 2.5 | artifacts are independent | `record("/a", {entry:1})` | `record("/b", {entry:1})` | `affected({entry:1})` = {/a, /b}; replacing `/b`'s set leaves `/a` untouched |
| 2.6 | a page and an island are peers | `record("/posts/hello", {entry:7})`, `record("island:latest", {type:post})` | `affected({type:post})` | = {island:latest} only — the page does not depend on what the island read |
| 2.7 | recording is transactional with the caller | caller opens a transaction, `record`, then rolls back | — | `affected` answers as before the transaction; no partial set |
| 2.8 | a replaced set is atomic under failure | `record("/a", {entry:1})`; a `record` whose insert fails midway (simulated: a key longer than the limit in position 2) | — | `affected({entry:1})` = {/a} still — the old set survives whole, not empty and not partial |
| 2.9 | forget an artifact | `record("/a", …)` | `forget("/a")` | `/a` absent from every `affected` answer; its hash gone |

## 3. Batching — `invalidate(keys)`, `flush()`

Changes coalesce until the caller is quiet; a flush is a plan, computed once.
A queue that reaches capacity is **sealed into a batch immediately** and a
fresh queue starts collecting with its own quiet period; sealed batches wait
in FIFO order and execute one at a time. The collecting queue can therefore
never exceed the capacity, and no key is ever dropped.

| # | name | setup | action | expect |
|---|---|---|---|---|
| 3.1 | nothing pending, nothing planned | — | `flush()` | plan is empty; no time recorded |
| 3.2 | one change, one plan | `/a`→{entry:1} | `invalidate({entry:1})`, `flush()` | plan = {/a} |
| 3.3 | repeated key coalesces | `/a`→{entry:1} | `invalidate({entry:1})` ×10, `flush()` | plan = {/a}, once; pending count was 1, not 10 |
| 3.4 | different keys, same artifact, once | `/a`→{entry:1, entry:2} | `invalidate({entry:1})`, `invalidate({entry:2})`, `flush()` | plan = {/a} once |
| 3.5 | quiet period gates the flush | `quiet = 2s` (injected clock) | `invalidate` at t=0, `due(t=1s)` | false; `due(t=2s)` true; `invalidate` at t=1.5s resets: `due(t=2s)` false, `due(t=3.5s)` true |
| 3.6 | flush empties the queue | pending {entry:1} | `flush()`, `flush()` | second plan empty |
| 3.7 | keys arriving during a flush are not lost | pending {entry:1}; during the caller's processing of plan 1 (between `flush` and `done`) `invalidate({entry:2})` | `flush()` | plan 2 = affected({entry:2}); nothing dropped, nothing repeated |
| 3.8 | cap seals a batch at once | `cap = 3` | `invalidate` of 3 distinct keys, then a 4th | the first 3 are sealed as a batch the moment the 3rd lands; the 4th sits in a fresh collecting queue with a fresh quiet period; nothing dropped |
| 3.9 | cap counts distinct keys | `cap = 3` | `invalidate({entry:1})` ×5 | nothing sealed (1 distinct key) |
| 3.9a | sealed batches queue in order | `cap = 2`; 6 distinct keys arrive fast | three sealed batches, taken FIFO; each `flush(batch)` plans only its own keys against the index as it is then |
| 3.10 | a plan is last-state | `/a`→{entry:1}; queue {entry:1}; before the flush, `record("/a", {entry:2})` (a rebuild elsewhere changed what `/a` depends on) | `flush()` | plan computed against the index *now*: {} — `/a` no longer depends on entry:1 |
| 3.11 | pending survives the process | `invalidate({entry:1})`, close the database, reopen | `flush()` | plan = affected({entry:1}) — the queue is in the database, not in memory |

## 4. Limits — fan-out

A change that would rebuild more than the cap is an error naming the key, not
a slow build. Checked before any rebuild starts.

| # | name | setup | action | expect |
|---|---|---|---|---|
| 4.1 | under the limit | `fanout_max = 100`; 99 artifacts →{entry:1} | `flush()` | plan of 99 |
| 4.2 | at the limit | 100 artifacts →{entry:1} | `flush()` | plan of 100 |
| 4.3 | over the limit | 101 artifacts →{entry:1} | `flush()` | `error.FanOutExceeded`; the error carries key `entry:1` and the count 101; the queue is **not** emptied (the caller decides: raise the limit, or fix the site) |
| 4.4 | the limit is per flush, across keys | `fanout_max = 100`; 60 artifacts →{entry:1}, 60 others →{entry:2} | `invalidate({entry:1, entry:2})`, `flush()` | `error.FanOutExceeded` with the total 120 (what would be rebuilt is what is limited) |
| 4.5 | a key with no dependents never trips it | `fanout_max = 0` is rejected at configuration (`error.InvalidLimit`); `fanout_max = 1`, `/a`→{entry:1} | `invalidate({entry:999})`, `flush()` | plan empty, no error |

## 5. No-op rebuilds — `unchanged(artifact, bytes)`

A rebuild that produces the same bytes must write nothing, so files, ETags
and CDN caches stay warm.

| # | name | setup | action | expect |
|---|---|---|---|---|
| 5.1 | first build is a change | — | `unchanged("/a", "x")` | false; the hash of "x" is now stored for `/a` |
| 5.2 | same bytes again | after 5.1 | `unchanged("/a", "x")` | true |
| 5.3 | different bytes | after 5.1 | `unchanged("/a", "y")` | false; stored hash is now of "y" |
| 5.4 | hash is per artifact | `/a` built with "x" | `unchanged("/b", "x")` | false — identical bytes elsewhere are a different artifact |
| 5.5 | forget clears the hash | `/a` built with "x"; `forget("/a")` | `unchanged("/a", "x")` | false |
| 5.6 | the hash is of the bytes, not the length | `/a` built with "ab" | `unchanged("/a", "ba")` | false |
| 5.7 | record and hash are independent | `record("/a", {entry:1})` never sets a hash; `unchanged` never changes the dependency set | — | assert both |

## 6. Storage — shape and cost

| # | name | setup | action | expect |
|---|---|---|---|---|
| 6.1 | schema is created on open, idempotently | fresh database | `open` twice | no error; tables `deps_edges`, `deps_artifacts`, `deps_pending` exist once |
| 6.2 | opens inside the caller's database | a database with the caller's own tables | `open` | the caller's tables are untouched; ours use a `deps_` prefix |
| 6.3 | lookup is indexed | 100k edges across 10k artifacts | `EXPLAIN QUERY PLAN` of the `affected` statement | uses the index on `key` — no `SCAN` of edges |
| 6.4 | replace is indexed | same | plan of the delete in `record` | uses the index on `artifact` |
| 6.5 | key and artifact length limits | — | a key of 1025 bytes | `error.NameTooLong` (limit 1024, configurable); nothing written |
| 6.6 | names are bytes, compared exactly | `record("/A", …)`, `record("/a", …)` | `affected` | two distinct artifacts; no case folding, no normalisation |

## 7. End to end — in the demo, against real renders

These are the scenarios the library exists for. They run in the demo
(`full-cms-deps`), with a store of `post`, `author`, `team`, `tag`, `media`
and real references, rendering real pages and islands through the index. A
"planted" file is one the test overwrites with marker bytes before the change,
to prove it was not rewritten.

| # | name | change | rebuilt | untouched (planted bytes survive) |
|---|---|---|---|---|
| 7.1 | edit a public entry's own field | post 7 body | `/posts/seven` | every other page; every island; the listing (`/posts` shows only titles, and the body is `field:7:body`) |
| 7.2 | edit a field a listing shows | post 7 title | `/posts/seven`, `/posts`, `island:latest-posts` (it lists titles) | other post pages |
| 7.3 | edit a referenced entry, one level | author 3 name; 145 posts reference author 3, 55 reference author 4 | the 145 post pages | the 55; the listing (it does not show authors) |
| 7.4 | edit a referenced entry, two levels | team 1 name; author 3 → team 1; post pages show the author's team | the post pages of author 3's posts | author 4's posts, even though author 4's team is also team 1 but the page never reads it (if it does, they are rebuilt — assert from the recorded keys, not from the schema) |
| 7.5 | edit a field nobody renders | author 3 bio (no template shows bios) | nothing | everything |
| 7.6 | create a public entry | new post | `/posts/new` created; `/posts`; `island:latest-posts`; the sitemap | every existing post page |
| 7.7 | soft-delete a referenced entry, optional field | delete author 4 (post.author is optional) | the 55 pages, rendered without an author | the 145 |
| 7.8 | soft-delete a referenced entry, required field | delete team 1 (author.team is required); authors 3 and 4 are now invalid | plan lists their posts; each rebuild **fails** with the artifact and field named; the old files stay; the failures are reported as a batch result, not a panic | — |
| 7.9 | soft-delete a public entry | delete post 7 | `/posts/seven` removed, its dependency set and hash forgotten; `/posts`, `island:latest-posts`, sitemap | other post pages |
| 7.10 | an island is a peer, not a child | edit post 7 title; every post page names `island:latest-posts` | `island:latest-posts` once; `/posts/seven` | the other 144 post pages — the island is their placeholder, not their content |
| 7.11 | a prerendered dynamic island is part of its page | the home page prerenders `<Welcome dynamic prerender>` which read the newest post; edit that post's title | `/` | — |
| 7.12 | a dynamic island has no artifact | edit anything | no `island:greeting` in any plan, ever | — |
| 7.13 | batch: ten edits, one plan | edit post 7 ten times within the quiet window | one flush; `/posts/seven` rebuilt once | — |
| 7.14 | batch: a release | create 50 posts, edit 3 authors, all within the window | one flush; each affected artifact rebuilt once; the listing once | — |
| 7.15 | no-op: rebuild yields the same bytes | edit post 7's body, then edit it back, within one window | plan includes `/posts/seven`; the file's mtime/ETag is unchanged after the flush | — |
| 7.16 | no-op: an unrelated field of a dependency | author 3's `bio` is not rendered; but the template reads the *entry* (entry-level key) | if the demo records entry-level: `/posts/…` are in the plan, rendered, hashed as identical, **not written**; if field-level: not in the plan at all — the test pins which, and both leave the files untouched |
| 7.17 | fan-out refusal | `fanout_max = 100`; edit team 1 referenced through 200 posts | `error.FanOutExceeded` naming `entry:1` and 200; nothing rebuilt; the queue still holds the change | everything |
| 7.18 | the index survives restarts | edit, stop the server before the quiet window elapses, start it | the flush happens on start; the plan is the same | — |
| 7.19 | the record is the render, not the schema | a template that reads `post.author` only when the post has a `featured` flag; post A featured, post B not | editing the author rebuilds A only | B |
| 7.21 | open query, unaffected window | `island:oldest-3` (open query); create a post | the island is in the plan, rendered, identical bytes, **not written** — the plan over-approximates, the hash judges | its file |
| 7.22 | open query, membership change by edit | posts ordered by `published_at`; backdate an old post into the newest-3 window | `island:latest-posts` is in the plan (the type key is raised on updates too), rendered, **written** with the new member | — |
| 7.23 | closed query is inert to creation | a curated trio fetched with `{ ids: [3,7,9] }` | create a post; the trio's artifact is not a candidate — not even rendered | it |
| 7.24 | closed query records absent members | the trio with post 7 unpublished (filtered out of the result) | republish post 7 | the trio's artifact is rebuilt — `entry:7` was recorded although it was not shown |
| 7.25 | two spellings, one recording | the same trio as three `getEntry` calls vs `{ ids: [3,7,9] }` | compare recorded keys | identical sets — closedness is a property of the result set, not of the API used |
| 7.20 | code changes are not invalidations | edit a template and rebuild the binary | a full `build` is required and documented; the index is rebuilt from scratch by it (every artifact re-recorded) — asserted by `record` replacing sets on a full build | — |

---

## 8. Observability — an injected observer

The caller may inject an observer at `open`; null observes nothing and costs
nothing. The observer is told, with typed events, everything needed to answer
four questions: *what changed*, *who depends on each changed key*, *what the
deduped plan was*, and *how it was executed*. Events carry data, not
formatted text — the demo renders them as terminal lines (like the access
log), a test renders them as assertions, a future admin UI as a panel. The
observer can never change behaviour: it has no return value, and everything
it is shown is also available through the API (it is a tap, not a source of
truth).

Event stream, in order, for one round:

```
invalidated  key, first_time            what changed (repeats marked as coalesced)
sealed       batch_no, keys             a queue reached capacity, or went quiet
planned      batch_no,
             per key: affected artifacts    the graph, resolved — who depends on what
             plan: deduped artifacts        the union, sorted
executed     batch_no, artifact, outcome    written | identical | removed | failed(reason)
refused      batch_no, key, count, limit    fan-out exceeded, nothing executed
```

| # | name | setup | action | expect |
|---|---|---|---|---|
| 8.1 | silence is free | no observer | full round | no events, no allocation for events |
| 8.2 | what changed | observer; `/a`→{entry:1} | `invalidate({entry:1})` ×3 | one `invalidated(entry:1, first_time=true)`, two with `first_time=false` — the coalescing is visible |
| 8.3 | the resolved graph | `/a`→{entry:1}, `/b`→{entry:1, entry:2} | invalidate both keys, flush | `planned` carries `entry:1 → {/a, /b}` and `entry:2 → {/b}`, and the deduped plan `{/a, /b}` — per-key lists overlap, the plan does not |
| 8.4 | execution, per artifact | plan of 3: one changed, one identical, one whose render fails | run the plan | three `executed` events with outcomes `written`, `identical`, `failed(reason)`, all carrying the batch number |
| 8.5 | a refusal is an event | fan-out limit 1, two dependents | flush | `refused(key, 2, 1)`; no `executed` events |
| 8.6 | batches are distinguishable | cap 2; 4 keys fast | events for batch 1 and batch 2 interleave nowhere: sealed₁, planned₁, executed₁…, sealed₂, planned₂, … |
| 8.7 | the observer sees what the API would say | any round | for every `planned` event, its per-key lists equal `affected({key})` asked directly at that moment |

## The safety property, stated once

The plan is a correct over-approximation: it may include artifacts a change
turns out not to affect (rendered, hashed identical, not written), but it can
never miss one — nothing except an immutable-id pin ever suppresses a coarse
key, and every write raises its type key. The render is the judge of change;
the hash is the judge of writing. A wrong guess anywhere costs a render,
never staleness.

## What is deliberately not here

- Query-shape awareness (`newest 3` unaffected by an edit to the oldest post
  at plan time, rather than at hash time) — `type:<t>` is the key for now;
  the key format leaves room.
- Rendering, files, HTTP — the caller's. The library never touches the
  filesystem.
- Triggers — who calls `invalidate` is the caller's business, by design.
