//! Cross-site request forgery, two defences: a token bound to the session (an HMAC
//! of the session id under a process secret, so nothing is stored per token) and a
//! check of where the request came from (`Origin`, falling back to `Referer`,
//! against `Host`). A write handler refuses a foreign origin outright, and a signed
//! in session must also present its token — in a form field or a header.
const std = @import("std");

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

/// Length of a token as `token` writes it: the HMAC as lowercase hex.
pub const token_len: u32 = Hmac.mac_length * 2;
/// Length of the process secret `token` and `verify` take; `State` draws one.
pub const secret_len: u32 = 32;
/// Longest host (`Host` header or the origin's host part) `origin_of` compares.
pub const host_len_max: u32 = 253 + 6;
/// Longest header value `origin_of` accepts, asserted.
pub const header_len_max: u32 = 8 << 10;

/// The token for a session, written into `out` and returned as a slice of it.
/// Deterministic: the same session and secret always give the same token, so
/// a page can embed it and a later request can present it, with nothing stored.
///
/// ```zig
/// var buffer: [auth.csrf.token_len]u8 = undefined;
/// const csrf_token = auth.csrf.token(state.secret, session.id, &buffer);
/// ```
pub fn token(secret: [secret_len]u8, session_id: []const u8, out: *[token_len]u8) []const u8 {
    std.debug.assert(session_id.len > 0);
    std.debug.assert(session_id.len <= 256);

    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, session_id, &secret);
    out.* = std.fmt.bytesToHex(mac, .lower);

    return out;
}

/// Whether `provided` is the session's token, compared in constant time.
///
/// ```zig
/// if (!auth.csrf.verify(state.secret, session.id, form.get("csrf") orelse "")) {
///     return res.text(.forbidden, "cross-site request refused");
/// }
/// ```
pub fn verify(secret: [secret_len]u8, session_id: []const u8, provided: []const u8) bool {
    std.debug.assert(session_id.len > 0);
    std.debug.assert(secret.len == secret_len);

    if (provided.len != token_len) {
        return false;
    }

    var expected: [token_len]u8 = undefined;
    _ = token(secret, session_id, &expected);

    return std.crypto.timing_safe.eql([token_len]u8, expected, provided[0..token_len].*);
}

/// Where a request came from, by its headers.
pub const Origin = enum {
    /// The origin's host is this server's `Host`: our own page.
    same,
    /// Another host, or no `Host` at all.
    foreign,
    /// Neither `Origin` nor `Referer` was sent — a non-browser client, or a
    /// browser that withheld them.
    absent,
};

/// Classifies a request by its `Host`, `Origin` and `Referer` headers, each null
/// when not sent. A write from a browser page should be `.same`; what `.absent`
/// means is the caller's policy (an API client without a session may pass, a
/// session must still present its token).
///
/// ```zig
/// switch (auth.csrf.origin_of(req.header("host"), req.header("origin"), req.header("referer"))) {
///     .foreign => return res.text(.forbidden, "cross-site request refused"),
///     .same, .absent => {},
/// }
/// ```
pub fn origin_of(host: ?[]const u8, origin: ?[]const u8, referer: ?[]const u8) Origin {
    const served = host orelse return .foreign;
    const source = origin orelse referer orelse return .absent;

    std.debug.assert(served.len <= header_len_max);
    std.debug.assert(source.len <= header_len_max);

    const source_host = host_of(source) orelse return .foreign;

    return if (std.ascii.eqlIgnoreCase(source_host, served)) .same else .foreign;
}

/// Classifies a request against the origins the site is actually served at,
/// each `scheme://host[:port]`, e.g. `"https://app.example.com"`. Stricter than
/// `origin_of`, for production: the scheme counts, so an `http://` page cannot
/// write to an `https://` site, and a proxy or client that rewrites `Host`
/// moves nothing, because `Host` is not consulted. `.absent` means what it
/// does in `origin_of`.
///
/// ```zig
/// const allowed = [_][]const u8{site.public_origin};
/// switch (auth.csrf.origin_in(&allowed, req.header("origin"), req.header("referer"))) {
///     .foreign => return res.text(.forbidden, "cross-site request refused"),
///     .same, .absent => {},
/// }
/// ```
pub fn origin_in(allowed: []const []const u8, origin: ?[]const u8, referer: ?[]const u8) Origin {
    std.debug.assert(allowed.len > 0);

    const source = origin orelse referer orelse return .absent;

    std.debug.assert(source.len <= header_len_max);

    const source_origin = origin_prefix_of(source) orelse return .foreign;

    for (allowed) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, source_origin)) {
            return .same;
        }
    }

    return .foreign;
}

/// The `scheme://host[:port]` of a URL, or null when it has no scheme or host.
fn origin_prefix_of(url: []const u8) ?[]const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const host = host_of(url) orelse return null;
    const end = scheme_end + 3 + host.len;

    std.debug.assert(end <= url.len);

    return url[0..end];
}

fn host_of(url: []const u8) ?[]const u8 {
    std.debug.assert(host_len_max > 0);

    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme_end + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..end];

    std.debug.assert(end <= rest.len);

    if (host.len == 0 or host.len > host_len_max) {
        return null;
    }

    return host;
}

test "token is deterministic per session and secret; verify is exact" {
    const secret: [secret_len]u8 = @splat(7);
    const other: [secret_len]u8 = @splat(8);
    var first: [token_len]u8 = undefined;
    var second: [token_len]u8 = undefined;

    _ = token(secret, "session-a", &first);
    _ = token(secret, "session-a", &second);
    try std.testing.expectEqualStrings(&first, &second);
    try std.testing.expect(verify(secret, "session-a", &first));
    try std.testing.expect(!verify(secret, "session-b", &first));
    try std.testing.expect(!verify(other, "session-a", &first));
    try std.testing.expect(!verify(secret, "session-a", "short"));
}

test "origin: same host passes, foreign host fails, no origin is absent" {
    const with_path = host_of("http://localhost:8080/admin?x=1").?;
    try std.testing.expectEqualStrings("localhost:8080", with_path);
    try std.testing.expectEqualStrings("example.com", host_of("https://example.com").?);
    try std.testing.expect(host_of("nonsense") == null);
    try std.testing.expect(host_of("http:///path") == null);

    const host = "localhost:8080";
    try std.testing.expectEqual(Origin.same, origin_of(host, "http://localhost:8080", null));
    try std.testing.expectEqual(Origin.same, origin_of(host, null, "http://LOCALHOST:8080/x"));
    try std.testing.expectEqual(Origin.foreign, origin_of(host, null, "https://evil.test/x"));
    try std.testing.expectEqual(Origin.foreign, origin_of(host, "http://evil.test", "http://localhost:8080"));
    try std.testing.expectEqual(Origin.foreign, origin_of(null, "http://localhost:8080", null));
    try std.testing.expectEqual(Origin.absent, origin_of(host, null, null));
}

test "origin_in: only the listed scheme and host pass, whatever Host says" {
    try std.testing.expectEqualStrings("https://example.com", origin_prefix_of("https://example.com/a?b").?);
    try std.testing.expectEqualStrings("http://localhost:8080", origin_prefix_of("http://localhost:8080").?);
    try std.testing.expect(origin_prefix_of("null") == null);
    try std.testing.expect(origin_prefix_of("https://") == null);

    const allowed = [_][]const u8{ "https://app.example.com", "https://example.com" };
    try std.testing.expectEqual(Origin.same, origin_in(&allowed, "https://app.example.com", null));
    try std.testing.expectEqual(Origin.same, origin_in(&allowed, null, "https://EXAMPLE.com/admin/x"));
    try std.testing.expectEqual(Origin.foreign, origin_in(&allowed, "http://app.example.com", null));
    try std.testing.expectEqual(Origin.foreign, origin_in(&allowed, "https://evil.example.com", null));
    try std.testing.expectEqual(Origin.foreign, origin_in(&allowed, "null", null));
    try std.testing.expectEqual(Origin.absent, origin_in(&allowed, null, null));
}
