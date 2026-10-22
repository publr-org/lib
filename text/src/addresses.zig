//! Whether text is a well-formed email address or web address. Checks the form only: an
//! address may be well formed and still not exist.

const std = @import("std");

const local_marks = ".!#$%&'*+/=?^_`{|}~-";
const domain_len_max = 253;
const label_len_max = 63;

/// An email address as the HTML standard's `<input type=email>` accepts it: a local part of
/// letters, digits and `.!#$%&'*+/=?^_`{|}~-`, `@`, then domain labels of letters, digits
/// and inner hyphens, at most 63 characters each.
pub fn is_email(text: []const u8) bool {
    const sign_at = std.mem.indexOfScalar(u8, text, '@') orelse return false;
    const local = text[0..sign_at];

    if (local.len == 0) {
        return false;
    }

    for (local) |byte| {
        const mark = std.mem.indexOfScalar(u8, local_marks, byte) != null;

        if (!std.ascii.isAlphanumeric(byte) and !mark) {
            return false;
        }
    }

    std.debug.assert(sign_at < text.len);

    return is_domain(text[sign_at + 1 ..], false);
}

/// Labels of letters, digits and inner hyphens, joined by dots. With `allow_unicode`, bytes
/// past ASCII count as letters, for internationalized names.
fn is_domain(text: []const u8, allow_unicode: bool) bool {
    if (text.len == 0 or text.len > domain_len_max) {
        return false;
    }

    var labels = std.mem.splitScalar(u8, text, '.');

    while (labels.next()) |label| {
        if (label.len == 0 or label.len > label_len_max) {
            return false;
        }

        if (label[0] == '-' or label[label.len - 1] == '-') {
            return false;
        }

        for (label) |byte| {
            const unicode = allow_unicode and byte >= 0x80;
            const letter = std.ascii.isAlphanumeric(byte) or byte == '-' or unicode;

            if (!letter) {
                return false;
            }
        }
    }

    return true;
}

/// A web address: `http://` or `https://` (any case), a host (a domain name, which may be
/// internationalized, an IPv4 address or a bracketed IPv6 one), an optional port up to
/// 65535, then a path, query or fragment without spaces or control characters. Other
/// schemes, `javascript:` among them, are not web addresses.
pub fn is_url(text: []const u8) bool {
    const after_scheme = scheme_end(text) orelse return false;
    const rest = text[after_scheme..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..host_end];

    for (rest) |byte| {
        if (byte <= ' ' or byte == 0x7F or std.mem.indexOfScalar(u8, "\"<>\\", byte) != null) {
            return false;
        }
    }

    if (std.mem.indexOfScalar(u8, authority, '@') != null) {
        return false;
    }

    std.debug.assert(host_end <= rest.len);

    return is_authority(authority);
}

fn scheme_end(text: []const u8) ?u32 {
    const schemes = [_][]const u8{ "http://", "https://" };

    for (schemes) |scheme| {
        if (text.len >= scheme.len and std.ascii.eqlIgnoreCase(text[0..scheme.len], scheme)) {
            return @intCast(scheme.len);
        }
    }

    return null;
}

fn is_authority(authority: []const u8) bool {
    var host = authority;

    if (host.len > 0 and host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return false;
        const port = host[close + 1 ..];

        const port_ok = port.len == 0 or (port[0] == ':' and is_port(port[1..]));

        return is_ipv6(host[1..close]) and port_ok;
    }

    if (std.mem.lastIndexOfScalar(u8, host, ':')) |colon| {
        if (!is_port(host[colon + 1 ..])) {
            return false;
        }

        host = host[0..colon];
    }

    std.debug.assert(host.len <= authority.len);

    return is_ipv4(host) or (is_domain(host, true) and !all_numeric(host));
}

fn is_port(text: []const u8) bool {
    const port = std.fmt.parseInt(u16, text, 10) catch return false;

    _ = port;

    return text.len > 0 and std.ascii.isDigit(text[0]);
}

fn is_ipv4(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '.');
    var count: u32 = 0;

    while (parts.next()) |part| {
        if (part.len == 0 or part.len > 3 or (part.len > 1 and part[0] == '0')) {
            return false;
        }

        _ = std.fmt.parseInt(u8, part, 10) catch return false;
        count += 1;
    }

    return count == 4;
}

/// A host of digits and dots that is no IPv4 address is refused, as browsers refuse it.
fn all_numeric(text: []const u8) bool {
    const last_dot = std.mem.lastIndexOfScalar(u8, text, '.');
    const last = if (last_dot) |dot| text[dot + 1 ..] else text;

    for (last) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return false;
        }
    }

    return true;
}

/// Up to eight groups of 1 to 4 hex digits, one `::` standing for the missing ones, and an
/// IPv4 address as the last two.
fn is_ipv6(text: []const u8) bool {
    const gap = std.mem.indexOf(u8, text, "::");

    if (gap) |gap_at| {
        if (std.mem.indexOf(u8, text[gap_at + 1 ..], "::") != null) {
            return false;
        }
    }

    var groups: u32 = 0;
    var parts = std.mem.splitScalar(u8, text, ':');

    while (parts.next()) |part| {
        if (part.len == 0) {
            continue;
        }

        if (parts.peek() == null and std.mem.indexOfScalar(u8, part, '.') != null) {
            if (!is_ipv4(part)) {
                return false;
            }

            groups += 2;
            continue;
        }

        if (part.len > 4) {
            return false;
        }

        _ = std.fmt.parseInt(u16, part, 16) catch return false;
        groups += 1;
    }

    const single_colons = gap == null and text.len > 0 and
        text[0] != ':' and text[text.len - 1] != ':';

    return if (gap != null) groups < 8 else (groups == 8 and single_colons);
}

test "is_email" {
    try std.testing.expect(is_email("ada@example.com"));
    try std.testing.expect(is_email("a.b+tag@sub.example.pl"));
    try std.testing.expect(is_email("x@localhost"));
    try std.testing.expect(!is_email("ada@"));
    try std.testing.expect(!is_email("@example.com"));
    try std.testing.expect(!is_email("ada example@x.pl"));
    try std.testing.expect(!is_email("ada@-x.pl"));
    try std.testing.expect(!is_email("ada@x..pl"));
    try std.testing.expect(!is_email("ada@x@y.pl"));
    try std.testing.expect(!is_email("ąda@x.pl"));
}

test "is_url" {
    try std.testing.expect(is_url("https://example.com"));
    try std.testing.expect(is_url("HTTP://example.com:8080/a/b?c=d#e"));
    try std.testing.expect(is_url("https://łódź.pl/"));
    try std.testing.expect(is_url("http://127.0.0.1/"));
    try std.testing.expect(is_url("http://[::1]:80/"));
    try std.testing.expect(!is_url("javascript:alert(1)"));
    try std.testing.expect(!is_url("ftp://example.com"));
    try std.testing.expect(!is_url("https://"));
    try std.testing.expect(!is_url("https://exa mple.com"));
    try std.testing.expect(!is_url("https://example.com:99999"));
    try std.testing.expect(!is_url("https://user@example.com"));
    try std.testing.expect(!is_url("https://999.1.1.1"));
    try std.testing.expect(!is_url("https://[nope]"));
    try std.testing.expect(!is_url("https://example.com/<script>"));
}
