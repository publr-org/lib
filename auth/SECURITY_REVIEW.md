# Security Review — publr_auth

Static security review of the new `lib/auth` library (publr_auth), cross-referenced
against OWASP ASVS 5.0 (`/Users/dawid/Documents/publr/.claude/OVASP_ASVS.csv`).
Companion to the workspace review at `cmsv2/SECURITY_REVIEW.md`, which covers the
http-server, the SQLite binding, and the mini-cms demo.

- **Scope:** `src/{lib,state,password,csrf,throttle}.zig`, plus `build/` and `README.md`.
- **Language/stack:** Zig 0.16.0, pure `std.crypto` (argon2id, HMAC-SHA256), no C, no deps.
- **Surface:** four mechanisms — password hashing, sign-in throttling, session-bound
  CSRF tokens, and the request-origin check. No user model, no session store, no cookies
  (deliberate scope; see `README.md` "Known limits").

---

## 1. Executive summary

The library is **clean of exploitable defects**. It gets the four hard parts of a
web sign-in right — an OWASP-minimum argon2id cost, a real CSPRNG-backed secret, a
constant-time token compare, a timing-flattening dummy hash, and a throttle checked
*before* hashing so a blocked subject costs nothing. The origin check fails closed.

All four low/informational findings below are now **fixed** (see each section for
the change):

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | Low | `verify` bounds the password length with `assert` only, not a runtime check (asymmetric with `hash`) | **FIXED** |
| 2 | Low | The CSRF secret is drawn via `io.random`, not the strictly-fallback-free `io.randomSecure` | **FIXED** |
| 3 | Info | The throttle key is an unkeyed non-cryptographic hash (`Wyhash`, seed 0) | **FIXED** |
| 4 | Info | `scratch_bytes`/`Params` assert a floor but no ceiling on the memory parameter | **FIXED** |

---

## 2. Findings

### 2.1 FIXED — `password.verify` length bound is assert-only

**File:** `src/password.zig:77-89`.

`hash` rejects out-of-range passwords at runtime (`plain.len < len_min or
plain.len > len_max` → `error.WeakPassword`, line 58-60). `verify` carries only
`std.debug.assert(plain.len <= len_max)` and `std.debug.assert(encoded.len <=
hash_len_max)` (lines 83-84) — assertions that a `ReleaseFast` consumer compiles
out. Consequences:

- A sign-in with an arbitrarily large `plain` still runs argon2 over it. The
  memory-hard phase is fixed-cost, but the Blake2b pre-hash of the password is
  `O(n)`, so a multi-megabyte password is a small, repeatable CPU amplification.
  The throttle bounds *attempt count per key* (and a full table evicts), so it
  does not fully close this.
- `Error.WeakPassword` is documented as covering "shorter than `len_min` or longer
  than `len_max`", but `verify` can never return it — a contract/doc mismatch.

**OWASP:** V15.2.2 (defenses against resource-demanding functionality), V6.2.8
(verify as received). **Fix:** mirror the runtime check in `verify` — return
`error.WeakPassword` (or `WrongPassword`) when `plain.len > len_max`, and guard
`encoded.len > hash_len_max` the same way. One line, keeps `hash`/`verify`
symmetric and makes the documented error set true in every build mode.

**Resolved:** `verify` now returns `error.WeakPassword` for `plain.len > len_max`
and `error.WrongPassword` for `encoded.len > hash_len_max` before reaching argon2
(`password.zig`), and the length-bounds test covers it. The mini-cms-auth
`fits` workaround was removed as redundant.

### 2.2 FIXED — CSRF secret uses `io.random`, not `randomSecure`

**File:** `src/state.zig:49`.

`io.random(&state.secret)` is CSPRNG-backed and securely seeded (arc4random_buf on
Darwin, getrandom on Linux), so the 32-byte secret holds the required 256 bits of
entropy. But `std.Io.random`'s contract allows a "less secure mechanism upon
failure" fallback, while `std.Io.randomSecure` never falls back and returns
`error.EntropyUnavailable` instead. For the single security-critical secret in the
process — the key every CSRF token is HMAC'd under — preferring the no-fallback
call is the more defensible choice.

**OWASP:** V11.5.1, V11.5.2. **Fix:** `io.randomSecure(&state.secret) catch return
error.EntropyUnavailable` (an `init` that cannot draw its secret must fail loudly).
Low priority; the current call is not wrong on any supported platform.

**Resolved:** `State.init` draws the secret with `io.randomSecure` and returns
`error.EntropyUnavailable` on failure.

### 2.3 FIXED — throttle key is an unkeyed, non-cryptographic hash

**File:** `src/throttle.zig:55-62`.

`key_for` uses `std.hash.Wyhash.hash(0, subject)` — fast, public, seed fixed at 0.
The key is not a secret, so this is not a confidentiality issue, but it is not a
MAC: an attacker can find two subjects that collide (≈2³² work for a 64-bit hash)
and merge their throttle state, or more simply spray 256 distinct subjects to evict
legitimate entries (the fixed table's documented LRU behavior). The impact is a
single user's sign-in being throttled — a DoS the throttle is already best-effort
against, not a boundary to defend.

**OWASP:** V6.1.1, V6.3.1. **Fix (optional):** key with `std.crypto.auth.hmac.sha2`
under a per-process key, or accept the collision surface and note it in the
`key_for` doc comment, which today overstates the property ("never 0" is all it
actually promises).

**Resolved:** `Throttle` now carries a 32-byte `secret` and `key_for` is a method
that HMAC-SHA256s the subject under it (first 8 bytes as the u64, 0 mapped to 1).
`State.init` shares its CSRF secret into `state.throttle.secret`, so collisions are
chance-only. `key_for` call sites (doc examples, mini-cms-auth) updated.

### 2.4 FIXED — no upper bound on the argon2 memory parameter

**File:** `src/password.zig:98-103`.

`scratch_bytes(params) = params.m * 1024 + (64 << 10)` in `u32`; `hash`, `State.init`
assert `m >= 8` but never `m <=` a ceiling. A `m ≥ ~4 MiB` overflows the `u32`
multiplication: a panic under `ReleaseSafe` (checked arithmetic), a silent wrap
under `ReleaseFast` that yields an undersized scratch and a clean `error.HashFailed`
(argon2 reports the allocator cannot satisfy it). Either way it fails, not corrupts —
the API simply accepts values it cannot serve.

**OWASP:** V15.3 (defensive coding). **Fix (optional):** assert a ceiling derived
from `scratch_bytes`'s `u32` return, so an absurd `Params` is a compile-time/assert
error rather than a runtime panic or wrap.

**Resolved:** added `password.m_max = 1 << 20` (1 GiB, far below the `u32` overflow
point) and asserts `params.m <= m_max` in `hash`, `scratch_bytes`, and
`State.init`.

---

## 3. What is done well

- **argon2id at the OWASP minimum.** `params_default = .{ .t = 2, .m = 19456, .p = 1 }`
  is exactly the OWASP Password Storage Cheat Sheet floor for argon2id; `params_test`
  is clearly scoped "never for real passwords". V11.4.2.
- **Fresh salt per hash**, test-verified (`password.zig:131-141`). V11.4.2.
- **Constant-time token compare** via `std.crypto.timing_safe.eql` over the full
  64-byte token; the only early-out is a fixed-length check, so nothing leaks. V11.2.4.
- **Timing-flattened user enumeration.** `State` hashes a random dummy password at
  `init`; an unknown account verifies against `dummy_hash()` and then fails, so a
  missing account costs the same argon2 time as a wrong password. V6.3.8.
- **Throttle before verify.** `wait_ms` is checked ahead of any hashing, so a blocked
  subject costs no CPU; failures escalate 1 min → 5 min → 15 min → 1 hour after four
  free attempts, and a success clears. Fixed 256-slot table with LRU eviction bounds
  memory. V6.1.1, V6.3.1.
- **256-bit secret + 256-bit HMAC token.** `secret_len = 32`, drawn from the system
  CSPRNG; the token is HMAC-SHA256 of the session id, hex-encoded — nothing stored per
  token, all invalidated by restart. V11.5.1, V3.5.1.
- **Origin check fails closed.** No `Host` → `.foreign`; a `Host`-less, scheme-less,
  or malformed `Origin`/`Referer` → `.foreign`; comparison is case-insensitive exact
  host match, so suffix tricks (`example.com.evil.com`) are rejected. V3.5.1.
- **No allocation after startup.** The scratch buffer is fixed at `init` and reset
  around each call; a sign-in storm cannot grow the process. V15.2.2.
- **Bounds as a form contract.** `len_min` 8, `len_max` 256 satisfy V6.2.1 and V6.2.9;
  no composition rules, no truncation or case transform (V6.2.5, V6.2.8).

---

## 4. Deliberate scope, not oversights (ASVS items the library does not own)

These are the consumer's policy and are correctly absent from a mechanism library;
each is documented in `README.md`:

- **No breached-password / top-N check** (V6.2.4, V6.2.12) — needs a wordlist/data
  feed; the library provides `hash` and leaves the check to the sign-up path.
- **No session store, cookie names, or expiry** (V7.*) — the consumer brings them;
  the token is keyed to whatever session id the consumer supplies.
- **No MFA** (V6.3.3), **no account-lockout policy** (V6.1.1 note) — throttle is
  anti-automation, not lockout; a full table evicts rather than locks.
- **No `SameSite`/cookie attributes** (V3.3.2) — the library has no cookies.
- **Single-threaded, one `State` per process** — the scratch buffer and throttle
  table are unsynchronized by contract; a multi-threaded consumer must serialize.

## 5. Bottom line

Ship it. All four findings are fixed in code: `verify` enforces the length bound at
runtime, the secret comes from `randomSecure`, the throttle key is an HMAC under a
per-process secret, and `m_max` bounds the argon2 memory parameter. The remaining
ASVS items are the consumer's policy, not this library's scope.
