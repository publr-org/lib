//! Password hashing: argon2id from `std.crypto`, as the encoded string a database
//! stores (`$argon2id$v=19$m=...,t=...,p=...$salt$hash`), with the length bounds a
//! sign-up form enforces and a fixed scratch budget so a hash never allocates from
//! the process heap. `State` wraps these two calls with that scratch buffer; use
//! them directly only when you manage the buffer yourself.
const std = @import("std");

const argon2 = std.crypto.pwhash.argon2;

/// Shortest password `hash` accepts, in characters (Unicode code points);
/// shorter, or not UTF-8, is `error.WeakPassword`.
pub const len_min: u32 = 8;
/// Longest password `hash` and `verify` accept, in bytes.
pub const len_max: u32 = 256;
/// Longest encoded hash `hash` produces — the size of the buffer it writes into,
/// and what a `password_hash` column needs.
pub const hash_len_max: u32 = 128;

/// argon2 cost parameters: passes `t`, memory `m` in KiB, lanes `p` (always 1).
pub const Params = argon2.Params;

/// The production cost: 19 MiB, two passes — the OWASP minimum for argon2id.
pub const params_default: Params = .{ .t = 2, .m = 19456, .p = 1 };
/// A cost for tests: 8 KiB, one pass, so a suite that signs in a hundred times
/// still runs in milliseconds. Never for real passwords.
pub const params_test: Params = .{ .t = 1, .m = 8, .p = 1 };
/// Largest memory parameter `hash`, `verify`, and `scratch_bytes` accept — 1 GiB,
/// far above the default, and below the point `scratch_bytes` overflows `u32`.
pub const m_max: u32 = 1 << 20;

/// What hashing and verifying can fail with.
pub const Error = error{
    /// The password is shorter than `len_min` or longer than `len_max`.
    WeakPassword,
    /// argon2 could not run — in practice, `scratch` was too small for `params`
    /// (size it with `scratch_bytes`).
    HashFailed,
    /// The password does not match the encoded hash, or the hash is not a
    /// well-formed argon2 string.
    WrongPassword,
};

/// Hashes `plain` with a fresh random salt into `out` and returns the encoded
/// string (a slice of `out`). `scratch` must offer `scratch_bytes(params)`; a
/// `FixedBufferAllocator` over a buffer of that size is the intended shape.
///
/// ```zig
/// var out: [auth.password.hash_len_max]u8 = undefined;
/// const encoded = try auth.password.hash(plain, auth.password.params_default, scratch, io, &out);
/// try store.set_password(user_id, encoded);
/// ```
pub fn hash(
    plain: []const u8,
    params: Params,
    scratch: std.mem.Allocator,
    io: std.Io,
    out: *[hash_len_max]u8,
) Error![]const u8 {
    std.debug.assert(params.p == 1);
    std.debug.assert(params.m >= 8);
    std.debug.assert(params.m <= m_max);

    if (plain.len > len_max) {
        return error.WeakPassword;
    }
    const characters = std.unicode.utf8CountCodepoints(plain) catch return error.WeakPassword;
    if (characters < len_min) {
        return error.WeakPassword;
    }

    const options: argon2.HashOptions = .{ .allocator = scratch, .params = params };
    const encoded = argon2.strHash(plain, options, out, io) catch return error.HashFailed;

    std.debug.assert(encoded.len <= hash_len_max);
    std.debug.assert(std.mem.startsWith(u8, encoded, "$argon2id$"));

    return encoded;
}

/// Checks `plain` against an encoded hash; the parameters come from the string, so
/// a hash made with older costs still verifies. Refuses a `plain` longer than
/// `len_max` (`error.WeakPassword`) and an `encoded` longer than `hash_len_max`
/// (`error.WrongPassword`), mirroring the bounds `hash` enforces. `scratch` is
/// sized as for `hash`.
///
/// ```zig
/// auth.password.verify(stored.password_hash, plain, scratch, io) catch return error.BadCredentials;
/// ```
pub fn verify(
    encoded: []const u8,
    plain: []const u8,
    scratch: std.mem.Allocator,
    io: std.Io,
) Error!void {
    if (plain.len > len_max) {
        return error.WeakPassword;
    }

    if (encoded.len > hash_len_max) {
        return error.WrongPassword;
    }

    argon2.strVerify(encoded, plain, .{ .allocator = scratch }, io) catch {
        return error.WrongPassword;
    };
}

/// The scratch a hash or verify with `params` needs: the argon2 memory plus a
/// margin for its bookkeeping. Allocate it once, at startup.
///
/// ```zig
/// const buffer = try gpa.alloc(u8, auth.password.scratch_bytes(params));
/// var fixed = std.heap.FixedBufferAllocator.init(buffer);
/// ```
pub fn scratch_bytes(params: Params) u32 {
    std.debug.assert(params.m >= 8);
    std.debug.assert(params.m <= m_max);
    std.debug.assert(params.p == 1);

    return params.m * 1024 + (64 << 10);
}

test "hash and verify round trip; wrong password and tampered hash fail" {
    var out: [hash_len_max]u8 = undefined;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const encoded = try hash("correct horse", params_test, gpa, io, &out);

    try verify(encoded, "correct horse", gpa, io);
    try std.testing.expectError(error.WrongPassword, verify(encoded, "wrong horse", gpa, io));

    var tampered: [hash_len_max]u8 = undefined;
    @memcpy(tampered[0..encoded.len], encoded);
    tampered[encoded.len - 1] ^= 1;
    const tampered_result = verify(tampered[0..encoded.len], "correct horse", gpa, io);
    try std.testing.expectError(error.WrongPassword, tampered_result);
}

test "password length bounds" {
    var out: [hash_len_max]u8 = undefined;
    const short = hash("1234567", params_test, std.testing.allocator, std.testing.io, &out);
    try std.testing.expectError(error.WeakPassword, short);

    const long = "x" ** (len_max + 1);
    const too_long = hash(long, params_test, std.testing.allocator, std.testing.io, &out);
    try std.testing.expectError(error.WeakPassword, too_long);

    const encoded = try hash("correct horse", params_test, std.testing.allocator, std.testing.io, &out);
    try std.testing.expectError(
        error.WeakPassword,
        verify(encoded, long, std.testing.allocator, std.testing.io),
    );
}

test "hashes are salted: same password, different encodings, both verify" {
    var first_out: [hash_len_max]u8 = undefined;
    var second_out: [hash_len_max]u8 = undefined;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const first = try hash("same password", params_test, gpa, io, &first_out);
    const second = try hash("same password", params_test, gpa, io, &second_out);

    try std.testing.expect(!std.mem.eql(u8, first, second));
    try verify(second, "same password", gpa, io);
}

test "scratch bytes cover the default parameters with a fixed buffer" {
    const bytes = scratch_bytes(params_default);
    const buffer = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(buffer);

    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    var out: [hash_len_max]u8 = undefined;
    const io = std.testing.io;
    const encoded = try hash("fixed buffer ok", params_default, fixed.allocator(), io, &out);

    fixed.reset();
    try verify(encoded, "fixed buffer ok", fixed.allocator(), io);
}
