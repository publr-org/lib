//! The process's authentication state in one value: the argon2 parameters and the
//! scratch buffer every hash runs in, the throttle table, the secret CSRF tokens
//! are signed with, and a dummy hash to verify against when the user does not
//! exist — so a sign-in takes the same time whether or not the account is real.
//! Everything is allocated in `init`; a hash or a verify never allocates again. Between hashes
//! the scratch's pages are given back to the system (`release_scratch`): the buffer stays
//! the process's, but a process that signs nobody in holds none of its memory (19 MiB at the
//! default cost).
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const password = @import("password.zig");
const throttle_module = @import("throttle.zig");
const csrf = @import("csrf.zig");

/// One per process, passed by pointer to whatever signs users in.
///
/// ```zig
/// var state: auth.State = undefined;
/// try state.init(gpa, io, .{});
/// defer state.deinit();
/// ```
pub const State = struct {
    gpa: std.mem.Allocator,
    params: password.Params,
    scratch_buffer: []align(std.heap.page_size_min) u8,
    scratch: std.heap.FixedBufferAllocator,
    /// The sign-in throttle; see `Throttle` for the shape of a sign-in.
    throttle: throttle_module.Throttle,
    /// The secret CSRF tokens are signed with — and the throttle's key — drawn at
    /// `init` from the platform CSPRNG; tokens do not survive a restart, which
    /// is what a session cookie expects anyway.
    secret: [csrf.secret_len]u8,
    dummy_hash_buffer: [password.hash_len_max]u8,
    dummy_hash_len: u32,

    /// What the session cookie is called, before any prefix: every Publr app
    /// speaks the same name.
    pub const session_cookie = "publr_session";
    /// The session cookie's name for this build: `session_cookie`, or
    /// `<prefix>_publr_session` when the app passed `cookie_prefix` to the
    /// dependency (`b.dependency("publr_auth", .{ .cookie_prefix = "tyik" })`) —
    /// which an app must do to coexist with another on one host, since browsers
    /// scope cookies by host, never by port. The prefix must be cookie-name
    /// characters (an RFC 6265 token): a compile error otherwise.
    ///
    /// ```zig
    /// const id = cookie_value(req.header("cookie"), auth.State.cookie_name);
    /// ```
    pub const cookie_name = cookie_name_for(build_options.cookie_prefix);
    /// `cookie_name` under the `__Host-` prefix, for production: a browser then
    /// refuses to store the cookie unless it is `Secure`, has `Path=/` and no
    /// `Domain`, so it can only be set over TLS and only by this host, never by
    /// a sibling subdomain. Set the cookie under this name when serving over
    /// TLS; keep `cookie_name` for plain-HTTP development, where browsers
    /// would drop the `__Host-` form.
    ///
    /// ```zig
    /// const name = if (site.tls) auth.State.secure_cookie_name else auth.State.cookie_name;
    /// ```
    pub const secure_cookie_name = "__Host-" ++ cookie_name;

    pub const Options = struct {
        /// The argon2 cost; `password.params_test` for a test suite.
        params: password.Params = password.params_default,
    };

    /// Allocates the scratch buffer for `options.params`, draws the secret, and
    /// hashes a random dummy password. Fails when the allocation fails or the
    /// platform cannot provide secure entropy.
    pub fn init(state: *State, gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
        std.debug.assert(options.params.p == 1);
        std.debug.assert(options.params.m >= 8);
        std.debug.assert(options.params.m <= password.m_max);

        state.gpa = gpa;
        state.params = options.params;
        state.scratch_buffer = try gpa.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            password.scratch_bytes(options.params),
        );
        errdefer gpa.free(state.scratch_buffer);

        state.scratch = std.heap.FixedBufferAllocator.init(state.scratch_buffer);
        io.randomSecure(&state.secret) catch return error.EntropyUnavailable;
        state.throttle = .{};
        std.crypto.auth.hmac.sha2.HmacSha256.create(&state.throttle.secret, "throttle", &state.secret);

        var dummy_password: [32]u8 = undefined;
        io.random(&dummy_password);
        const dummy_hex = std.fmt.bytesToHex(dummy_password, .lower);
        const encoded = try state.hash_password(&dummy_hex, io, &state.dummy_hash_buffer);
        state.dummy_hash_len = @intCast(encoded.len);
        state.release_scratch();

        std.debug.assert(state.dummy_hash_len > 0);
    }

    /// Frees the scratch buffer and poisons the value.
    pub fn deinit(state: *State) void {
        std.debug.assert(state.scratch_buffer.len > 0);
        std.debug.assert(state.dummy_hash_len > 0);

        state.gpa.free(state.scratch_buffer);
        state.* = undefined;
    }

    /// `password.hash` with this state's parameters and scratch: the encoded
    /// string to store, written into `out`.
    ///
    /// ```zig
    /// var out: [auth.password.hash_len_max]u8 = undefined;
    /// const encoded = try state.hash_password(plain, io, &out);
    /// ```
    pub fn hash_password(
        state: *State,
        plain: []const u8,
        io: std.Io,
        out: *[password.hash_len_max]u8,
    ) password.Error![]const u8 {
        std.debug.assert(state.scratch_buffer.len >= password.scratch_bytes(state.params));
        std.debug.assert(out.len == password.hash_len_max);

        state.scratch.reset();
        defer state.scratch.reset();
        defer state.release_scratch();

        return password.hash(plain, state.params, state.scratch.allocator(), io, out);
    }

    /// Whether `plain` matches the encoded hash. For an unknown account verify
    /// against `dummy_hash` instead of skipping the check, so the answer takes
    /// the same time either way.
    ///
    /// ```zig
    /// const stored = found.password_hash orelse state.dummy_hash();
    /// const ok = state.verify_password(stored, plain, io) and found.password_hash != null;
    /// ```
    pub fn verify_password(state: *State, encoded: []const u8, plain: []const u8, io: std.Io) bool {
        std.debug.assert(encoded.len <= password.hash_len_max);
        std.debug.assert(state.scratch_buffer.len > 0);

        state.scratch.reset();
        defer state.scratch.reset();
        defer state.release_scratch();

        password.verify(encoded, plain, state.scratch.allocator(), io) catch return false;

        return true;
    }

    /// The scratch's pages back to the system once a hash is done with them: the buffer stays
    /// allocated, its contents are dropped, and the next hash writes them afresh. Without
    /// this, one sign-in kept the whole scratch resident for the process's life. Where the
    /// system cannot be told, the pages simply stay.
    fn release_scratch(state: *State) void {
        std.debug.assert(state.scratch_buffer.len > 0);
        std.debug.assert(@intFromPtr(state.scratch_buffer.ptr) % std.heap.page_size_min == 0);

        const advice: ?u32 = comptime switch (builtin.os.tag) {
            .linux => std.posix.MADV.DONTNEED,
            .macos, .ios, .freebsd, .netbsd, .openbsd, .dragonfly => std.posix.MADV.FREE,
            else => null,
        };

        if (comptime advice == null) {
            return;
        }

        // Whole pages only: a page the buffer shares with other memory is left alone.
        const whole = state.scratch_buffer.len - state.scratch_buffer.len % std.heap.page_size_min;

        if (whole == 0) {
            return;
        }

        std.posix.madvise(state.scratch_buffer.ptr, whole, advice.?) catch return;
    }

    /// A valid hash of a password nobody knows: what to verify against when the
    /// account does not exist.
    pub fn dummy_hash(state: *const State) []const u8 {
        std.debug.assert(state.dummy_hash_len > 0);
        std.debug.assert(state.dummy_hash_len <= password.hash_len_max);

        return state.dummy_hash_buffer[0..state.dummy_hash_len];
    }
};

test "state hashes and verifies with its own scratch; dummy hash never matches" {
    var state: State = undefined;
    try state.init(std.testing.allocator, std.testing.io, .{
        .params = password.params_test,
    });
    defer state.deinit();

    var out: [password.hash_len_max]u8 = undefined;
    const encoded = try state.hash_password("open sesame", std.testing.io, &out);

    try std.testing.expect(state.verify_password(encoded, "open sesame", std.testing.io));
    try std.testing.expect(!state.verify_password(encoded, "open sesame!", std.testing.io));
    const dummy = state.verify_password(state.dummy_hash(), "open sesame", std.testing.io);
    try std.testing.expect(!dummy);
    try std.testing.expect(state.throttle.wait_ms(1, 0) == 0);
}

fn cookie_name_for(comptime prefix: []const u8) []const u8 {
    comptime {
        if (prefix.len > 32) {
            @compileError("cookie prefix \"" ++ prefix ++ "\" is longer than 32 bytes");
        }
        if (!cookie_prefix_valid(prefix)) {
            @compileError("cookie prefix \"" ++ prefix ++ "\" is not a cookie-name token");
        }
    }

    return if (prefix.len == 0) State.session_cookie else prefix ++ "_" ++ State.session_cookie;
}

fn cookie_prefix_valid(prefix: []const u8) bool {
    for (prefix) |char| {
        const separator = std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={} \t", char) != null;

        if (char <= ' ' or char >= 0x7f or separator) {
            return false;
        }
    }

    return true;
}

test "the session cookie is publr_session, optionally prefixed by the build" {
    try std.testing.expectEqualStrings("publr_session", cookie_name_for(""));
    try std.testing.expectEqualStrings("tyik_publr_session", cookie_name_for("tyik"));
    try std.testing.expect(std.mem.endsWith(u8, State.cookie_name, State.session_cookie));
    try std.testing.expectEqualStrings("__Host-" ++ State.cookie_name, State.secure_cookie_name);

    try std.testing.expect(cookie_prefix_valid("mini-cms-auth"));
    try std.testing.expect(!cookie_prefix_valid("has space"));
    try std.testing.expect(!cookie_prefix_valid("a=b"));
}

test "hashes keep working after the scratch's pages went back to the system" {
    var state: State = undefined;
    try state.init(std.testing.allocator, std.testing.io, .{
        // A cost of whole pages, so every hash below gives them back.
        .params = .{
            .t = 1,
            .m = 1024,
            .p = 1,
        },
    });
    defer state.deinit();

    try std.testing.expect(state.scratch_buffer.len >= 2 * std.heap.page_size_min);

    var out: [password.hash_len_max]u8 = undefined;
    const encoded = try state.hash_password("open sesame", std.testing.io, &out);

    try std.testing.expect(state.verify_password(encoded, "open sesame", std.testing.io));
    try std.testing.expect(state.verify_password(encoded, "open sesame", std.testing.io));
    try std.testing.expect(!state.verify_password(encoded, "open sesame!", std.testing.io));
    try std.testing.expect(!state.verify_password(state.dummy_hash(), "open sesame", std.testing.io));
}
