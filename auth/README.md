# Publr Auth

What a sign-in needs, and nothing about where users live: argon2id password
hashing with a fixed scratch budget, a throttle table for failed attempts, CSRF
tokens bound to a session, and the request-origin check. Pure Zig over
`std.crypto`: nothing to link, nothing vendored, and after `init` nothing is
allocated again.

```zig
const auth = @import("publr_auth");

var state: auth.State = undefined;
try state.init(gpa, io, .{});
defer state.deinit();

var out: [auth.password.hash_len_max]u8 = undefined;
const encoded = try state.hash_password("correct horse battery", io, &out);

const ok = state.verify_password(encoded, "correct horse battery", io);
```

## Using it in your Zig project

```zig
// build.zig.zon — a sibling checkout or an in-repo vendored copy; never a URL
.dependencies = .{
    .publr_auth = .{ .path = "../auth" },
},

// build.zig
const publr_auth = b.dependency("publr_auth", .{
    .target = target,
    .release = optimize != .Debug,
    .cookie_prefix = "myapp", // optional: the session cookie becomes myapp_publr_session
});
exe_module.addImport("publr_auth", publr_auth.module("publr_auth"));
```

Vendoring is the same mechanism at a different path, or the amalgamation
(`zig build amalgamate` → `zig-out/publr_auth.zig`) as one file.

## Philosophy

Like [the HTTP server](../http) and [the SQLite binding](../sqlite), this
library exists to power Publr, and its restraint is the feature. It is the four
mechanisms every web sign-in has and every web app gets subtly wrong — hashing,
throttling, CSRF, origin — with the policy left out: no users table, no session
store. A consumer brings those and calls four things. The one name the library
does own is the session cookie's — `State.cookie_name`: `publr_session`, or
`<prefix>_publr_session` when the app builds the dependency with
`.cookie_prefix = "<prefix>"` — so every Publr app agrees on it. In production
the same name goes under `__Host-` (`State.secure_cookie_name`), which makes
the browser enforce `Secure`, `Path=/` and host scoping.

Two of the mechanisms come at two strengths, because what protects a deployment
is only friction on a developer's laptop: the cookie name above, and the origin
check — `csrf.origin_of` compares the request's `Host` (plain HTTP, any port),
`csrf.origin_in` compares scheme and host against the origins the site is
really served at. The consumer picks by mode.

## The contract

**Hashes are argon2id strings.** `hash` produces the encoded form
(`$argon2id$v=19$m=…,t=…,p=…$salt$hash`), so the parameters travel with the
hash and an old cost still verifies after the default changes. The default cost
is the OWASP minimum (19 MiB, two passes); `params_test` (8 KiB, one pass) keeps
a test suite fast and is never for real passwords. Passwords shorter than 8 or
longer than 256 bytes are refused before any hashing.

**Hashing allocates only at startup.** argon2 needs its memory parameter's worth
of scratch; `State.init` allocates exactly `scratch_bytes(params)` once, and every
`hash_password` / `verify_password` runs in that buffer through a fixed-buffer
allocator that is reset around each call. A sign-in storm cannot grow the
process.

**A missing account costs the same as a wrong password.** `State` hashes a
random dummy password at `init`; a sign-in for an unknown email verifies the
attempt against `dummy_hash()` and then fails, so timing does not reveal which
emails exist.

**Throttling is a table, not a clock.** `Throttle` holds 256 subjects; after four
free failures a subject waits a minute, then five, fifteen, an hour, until a
success clears it. The caller supplies `now_ms`, so the table is deterministic
and testable, and a full table evicts the least recently touched subject — a
reset, never a lockout — which bounds memory without a list of "known
attackers".

**CSRF tokens are derived, not stored.** A token is the HMAC-SHA256 of the
session id under a per-process secret drawn at `init`, as hex. A page embeds the
session's token; a write presents it; `verify` recomputes and compares in
constant time. Nothing is stored per token, and a restart invalidates them all —
the same lifetime a session cookie already lives under.

**Origin is checked from headers, not trusted from the client.** `origin_of`
compares the host of `Origin` (or `Referer`) with `Host`: `.same`, `.foreign`, or
`.absent` when neither was sent. What `.absent` means is the caller's policy — a
token-less API client may pass, a session must still present its token — and the
function takes plain optional strings so it is usable with any HTTP layer.

## Known limits (deliberate scope, not oversights)

- One `State` per process and one thread: the scratch buffer and the throttle
  table are shared by everything that signs in, unsynchronized, which matches a
  single-threaded server.
- No session store, no user model. Those are the consumer's tables; the library
  only names the cookie (`State.cookie_name` and its `__Host-` form
  `State.secure_cookie_name`, from the build option) and validates nothing
  about what is stored under it.
- argon2 parameters are fixed at `init`; changing them means a new `State`.

## Tests and docs

```bash
zig build test   # every test, on the source tree and on the amalgamation
zig build docs   # browsable API reference from the doc comments → zig-out/docs
```

Everything here is pure logic, so every test is a unit test inline with the code
it checks: the round trips, the bounds, the salt, the throttle's schedule and
eviction, the token's determinism and constant-time compare, the origin
classification. The argon2 and HMAC implementations themselves are `std`'s and
are not re-tested.
