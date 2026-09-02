# Security Review — cmsv2 workspace (re-audit)

Second-pass static security review, after the author's hardening changes. Scope,
method, and OWASP ASVS 5.0 mapping are the same as the first pass; this edition
records what changed, what is now resolved, and what remains.

- **Scope:** `lib/http-server` (publr_http — final), `lib/sqlite` (publr_sqlite — final),
  `demos/mini-cms` (POC, see its `SECURITY_NOTE.md`), `zig-tools` (build-time only).
- **Language/stack:** Zig 0.16.0, single-threaded HTTP/1.1, vendored SQLite 3.53.4.
- **Changes reviewed this pass:** `lib/http-server/src/{cli,connection,engine}.zig`,
  `lib/http-server/src/extensions/websocket.zig`, `demos/mini-cms/src/main.zig`,
  `demos/mini-cms/{README,SECURITY_NOTE}.md`.

---

## 0. What changed and why

| Change | Effect | Verdict |
|--------|--------|---------|
| WebSocket liveness (engine + websocket) | Upgraded connections now time out via ping/pong; a vanished peer holds a slot for at most two `idle_timeout_ms` intervals. | **Resolves prior finding 2.3.** Correct and covered by new tests. |
| `Config.defaults` in `cli.zig` | Apps can set their own starting options (mini-cms pins `127.0.0.1`). | **Resolves the bind half of prior 2.2.** Semantics are sound. |
| `SECURITY_NOTE.md` + loopback default in mini-cms | Demo's known omissions are documented as intentional POC scope. | **Resolves the demo-side actionability of 2.1/2.2/2.4/2.5/2.7/2.8/2.9.** |
| `socket.open_under` symlink walk (static + socket layer) | Every path component is opened with `O_NOFOLLOW` via `openat`; intermediate-directory symlinks no longer escape the root. | **Resolves prior finding 2.6 (symlink half).** macOS tests pass; Linux/Windows cross-compile clean. |

---

## 1. Executive summary

The **final libraries are now clean of exploitable defects**. Every material
issue from the first pass — the WebSocket slot-exhaustion gap, the demo's default
`0.0.0.0` bind, and the static-serving symlink escape — is fixed, and every
remaining mini-cms finding is explicitly declared out of scope in
`demos/mini-cms/SECURITY_NOTE.md`.

One policy item remains for a "100% secure" library, a documented residual rather
than a hidden bug:

| # | Severity | Finding |
|---|----------|---------|
| 1 | ~~Low~~ | ~~`.svg` is served inline as `image/svg+xml` — stored XSS if the served tree ever holds untrusted content~~ — **FIXED** (§2.2) |

Plus two minor observations (not vulnerabilities) introduced by the `defaults`
feature, in §4.

---

## 2. Remaining library findings

### 2.1 FIXED — intermediate-directory symlink escape in `static.serve_file`

**Files:** `lib/http-server/src/static.zig`, `lib/http-server/src/platform/socket{,_linux,_posix,_windows}.zig`.

`serve_file` now resolves the URL to a root-relative path and opens it with
`socket.open_under`, which walks each path component with `openat` +
`O_NOFOLLOW` (`O_DIRECTORY` on intermediate components), so a symlink in **any**
component — intermediate or final — is refused rather than followed. The walk is one
syscall per component, so no component can be swapped for a symlink between check and
use (TOCTOU-free). On Windows (dev-grade) a `GetFileAttributesW` per-prefix
reparse-point check provides the same refusal.

`root/sub -> /etc` now yields `GET /sub/passwd` → `.not_found`, never `/etc/passwd`.

**OWASP:** V5.3.2, V1.3.6 — resolved.

### 2.2 FIXED — `.svg` served inline as `image/svg+xml`

**File:** `lib/http-server/src/static.zig`.

`content_type` maps `.svg` → `image/svg+xml`, and `serve_file` adds
`X-Content-Type-Options: nosniff`. SVG is scriptable, so a user-controlled `.svg` in
the served tree is a stored-XSS primitive in a browser. For a trusted asset folder
this is fine; the moment the served tree is upload-influenced it is not.

**OWASP:** V1.3.4, V3.2.1. **Fix:** for untrusted trees, force
`Content-Disposition: attachment` on SVG, or serve uploads from a separate origin /
`sandbox` CSP.

**Resolved:** `serve_file` now adds `Content-Disposition: attachment` to any `.svg`
(so a stored SVG downloads rather than rendering inline — never an XSS primitive),
with an `is_svg` helper and test. Module doc and `Serve` doc updated.

---

## 3. Resolved / out-of-scope (prior findings)

| Prior § | Finding | Status |
|---------|---------|--------|
| 2.1 | mini-cms CSRF on writes | **Out of scope** — `SECURITY_NOTE.md` §2.1 (no ambient credential ⇒ CSRF is a non-event). |
| 2.2 (bind) | mini-cms default `0.0.0.0` | **Fixed** — `.defaults = .{ .address = .{ 127,0,0,1 } }` (`main.zig:36`). |
| 2.2 (auth) | mini-cms unauthenticated | **Out of scope** — `SECURITY_NOTE.md` §2.2 (no user model by design). |
| 2.3 | WebSocket never times out | **Fixed** — see §5 (ping/pong liveness + `on_expired`). |
| 2.4 | No rate limiting | **Out of scope** — `SECURITY_NOTE.md` §2.4. |
| 2.5 | No TLS / security headers | **Out of scope** — `SECURITY_NOTE.md` §2.5 (TLS is proxy-terminated per `ARCHITECTURE.md`). |
| 2.6 | Static symlink + SVG | **Both fixed** — symlink (§2.1), SVG attachment (§2.2). |
| 2.7 | `/stats`,`/health` disclosure | **Out of scope** — `SECURITY_NOTE.md` §2.7. |
| 2.8 | `mini-cms.db*` in tree | **Out of scope** — `SECURITY_NOTE.md` §2.8. |
| 2.9 | No field-length validation | **Out of scope** — `SECURITY_NOTE.md` §2.9. |

The `SECURITY_NOTE.md` table covers the demo faithfully and its "only while
loopback-only" caveat is the correct boundary condition. The library findings (2.6,
now §2.1/§2.2) were correctly *not* declared demo-scope, because they are the
library's to own.

---

## 4. New observations from the hardening changes (not vulnerabilities)

### 4.1 FIXED — `defaults` is silently discarded by `--config`

`cli.zig` previously returned `defaults` only when no `--config` path is present; a
`--config` file parsed into a **fresh** `Options`, so app-provided `defaults` did not
merge. Consequence for mini-cms: its loopback default is `127.0.0.1`, but a
`--config file.zon` (a file that omits `.address`) reverted the bind to the
library's build-mode default — `0.0.0.0` in release.

**Resolved:** config files now parse into an all-optional `ConfigOptions` and
**overlay** the app's `defaults` (via `overlay`), so a field the file omits keeps
the app's default; flags still override either. For the standalone server
(`defaults = .{}`) behavior is unchanged. The `defaults` doc comment,
`config.example.zon`, and the corresponding cli test were updated.

### 4.2 `--help` text does not reflect app-provided `defaults`

`cli.zig:237-252` hardcodes the library defaults in the help table, so an app that
overrides `defaults` (mini-cms's `127.0.0.1`) still prints "release builds: 0.0.0.0".
Cosmetic, but it means the operator-facing help can contradict the actual behavior.
Not a security issue; worth fixing for accuracy.

### 4.3 WebSocket liveness raises the bar but does not cap an actively-signaling attacker

The ping/pong mechanism reclaims slots from **vanished** peers. A determined attacker
who sends one tiny frame per `idle_timeout_ms` from many connections still holds slots
indefinitely. That is inherent to idle-timeout design and is not a bug; the residual
control is `connections_max` plus consumer rate-limiting/connection caps. Recorded so
the "100% secure" claim is understood precisely.

---

## 5. Verification of the WebSocket liveness hardening (correct)

The new mechanism is well-implemented and test-backed:

- `connection.zig:219` arms an upgraded slot with `idle_timeout_ms` (was `maxInt`).
- `engine.zig:295-299` adds the `on_expired` vtable hook; `engine.zig:747-754` routes an
  expired `.upgraded` slot to it (or closes it, counted in `timed_out_total`).
- `websocket.zig:412-434` (`service_expired`) pings on first expiry, closes with **1001**
  on the second; `websocket.zig:474-477` re-arms on **any complete frame** (so a partial
  frame does not count as proof of life — a drip-feed peer still times out).
- Entry reuse is safe: `upgrade` re-assigns the whole `Entry`, so `ping_pending` resets
  to `false` on reconnect (`websocket.zig:242`).
- New tests cover "silent peer pinged then closed" and "pong keeps a silent peer alive"
  (`websocket.zig:1128-1203`).

No correctness or memory-safety defects found in the new code.

---

## 6. What is done well (unchanged from the first pass, still true)

- **SQL injection unrepresentable** — comptime SQL + `bind_*` only (`lib/sqlite/src/lib.zig:233-276, 336-364`).
- **Request-smuggling resistance** — Content-Length-only framing; `Transfer-Encoding`,
  duplicate/conflicting `Content-Length`, duplicate `Host` all rejected
  (`request.zig:282-334`).
- **Response-splitting resistance** — header name/value validation at `set_header` time
  in every build mode; framing headers owned by the writer (`response.zig:77-113`).
- **Traversal/dotfile/FIFO defense** — dot-segments, `\`, NUL, symlinks in **any**
  component, and non-regular files refused (`static.zig:112-165`, `socket_*.zig`
  `open_under`).
- **WebSocket frame hardening** — client masking enforced, RSV rejected, control-frame
  rules enforced, UTF-8 validated (`websocket.zig:493-557`).
- **Error information-hiding** — handler errors become generic 500s; error names stay
  server-side (`server.zig:263-276`).
- **Memory safety** — Zig; checked arithmetic on untrusted sizes; no overflow/UAF found.

---

## 7. Bottom line and recommendations

1. **Library: `static.serve_file` symlink containment — DONE.** `socket.open_under` walks
   every component with `O_NOFOLLOW` (Linux + POSIX via `openat`; Windows via
   `GetFileAttributesW` reparse-point checks). macOS tests pass; Linux/Windows
   cross-compile clean.
2. **Library: SVG contract — DONE** (§2.2). `serve_file` now forces
   `Content-Disposition: attachment` on `.svg`, so a stored SVG can never be a
   stored-XSS primitive. This was the only remaining item.
3. **Demo: `--config` footgun — DONE** (§4.1). Config files now overlay the app's
   `defaults`, so a config that omits `.address` keeps the loopback pin instead of
   reverting to `0.0.0.0` in release.
4. **Demo: keep `SECURITY_NOTE.md` in sync** if more findings are added — its table is
   keyed to this report's section numbers.

Everything else is resolved or intentionally scoped.
