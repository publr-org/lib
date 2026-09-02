//! What a sign-in needs and nothing about where users live: argon2id password
//! hashing with a fixed scratch budget, a throttle table for failed attempts, CSRF
//! tokens bound to a session, and the request-origin check — pure Zig over
//! `std.crypto`, allocating only at startup.
//!
//! ## Set up
//!
//! One `State` per process holds the parameters, the scratch buffer every hash
//! runs in, the throttle, and the token secret:
//!
//! ```zig
//! const auth = @import("publr_auth");
//!
//! var state: auth.State = undefined;
//! try state.init(gpa, io, .{});
//! defer state.deinit();
//! ```
//!
//! ## Sign up and sign in
//!
//! Store the encoded hash; at sign-in check the throttle first, verify against the
//! stored hash (or the dummy one, so a missing account costs the same time), and
//! record the outcome:
//!
//! ```zig
//! var out: [auth.password.hash_len_max]u8 = undefined;
//! const encoded = try state.hash_password(plain, io, &out);
//!
//! const key = state.throttle.key_for(email);
//!
//! if (state.throttle.wait_ms(key, now_ms) > 0) {
//!     return error.Throttled;
//! }
//!
//! const stored = found.password_hash orelse state.dummy_hash();
//!
//! if (!state.verify_password(stored, plain, io) or found.password_hash == null) {
//!     _ = state.throttle.record_failure(key, now_ms);
//!     return error.BadCredentials;
//! }
//!
//! state.throttle.record_success(key);
//! ```
//!
//! ## Guard writes
//!
//! A page embeds the session's token; a write handler refuses a foreign origin and
//! checks the token a signed-in session presents:
//!
//! ```zig
//! var buffer: [auth.csrf.token_len]u8 = undefined;
//! const csrf_token = auth.csrf.token(state.secret, session.id, &buffer);
//!
//! const origin = auth.csrf.origin_of(req.header("host"), req.header("origin"), req.header("referer"));
//!
//! if (origin == .foreign or !auth.csrf.verify(state.secret, session.id, provided)) {
//!     return res.text(.forbidden, "cross-site request refused");
//! }
//! ```
const impl_password = @import("password.zig");
const impl_throttle = @import("throttle.zig");
const impl_csrf = @import("csrf.zig");
const impl_state = @import("state.zig");

/// The process's auth state: parameters, scratch, throttle, secret, dummy hash.
pub const State = impl_state.State;
/// The sign-in throttle table; `State.throttle` is the process's instance.
pub const Throttle = impl_throttle.Throttle;
/// argon2id hashing as encoded strings: `hash`, `verify`, the cost parameters.
pub const password = impl_password;
/// Session-bound CSRF tokens and the request-origin check.
pub const csrf = impl_csrf;

test {
    _ = impl_password;
    _ = impl_throttle;
    _ = impl_csrf;
    _ = impl_state;
}
